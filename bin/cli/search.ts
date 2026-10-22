import { relativeTime } from "./helpers.ts";
import { withDaemon, type DaemonClient } from "./daemon.ts";
import { normalizePlacement } from "./window.ts";

export interface SearchResult {
  score: number;
  window: any;
  tabs: { tab: number; cwd: string; title: string; hasClaude: boolean; tmuxSession: string; attribution?: string }[];
  reasons: string[];
}

export interface SearchOptions {
  sources?: string[];
  after?: string;
  before?: string;
  recency?: boolean;
  mode?: string;
}

export async function searchWithClient(client: DaemonClient, query: string, opts: SearchOptions = {}): Promise<SearchResult[]> {
  const { daemonCall } = client;
  const params: Record<string, any> = { query };
  if (opts.sources) params.sources = opts.sources;
  if (opts.after) params.after = opts.after;
  if (opts.before) params.before = opts.before;
  if (opts.recency !== undefined) params.recency = opts.recency;
  if (opts.mode) params.mode = opts.mode;
  let hits: any[];
  try { hits = await daemonCall("search.query", params, 10000) as any[]; }
  catch (error) {
    // Linux provides windows.search, while Mac provides unified search.query.
    // Only an absent method permits fallback; authorization and transport errors do not.
    if (!/^Unknown method: (search\.query|lattices\.search)$/.test((error as Error).message)) throw error;
    let host: { platform?: string; methods?: string[] };
    try { host = await daemonCall("host.describe") as typeof host; }
    catch { throw error; }
    if (host.platform !== "linux" || !host.methods?.includes("windows.search")) throw error;
    if (opts.after || opts.before || opts.recency === true) throw new Error("Linux window search does not support date or recency filters.");
    if (opts.sources?.some(source => !["titles", "apps", "sessions"].includes(source)) || opts.mode === "terminal" || opts.mode === "complete") {
      console.error("Linux search covers window titles, apps and session tags; terminal-content and OCR sources are unavailable.");
    }
    hits = await daemonCall("windows.search", { query }, 10000) as any[];
  }
  return hits.map((w: any) => ({
    score: w.score || 0,
    window: w,
    tabs: (w.terminalTabs || []).map((t: any) => ({
      tab: t.tabIndex, cwd: t.cwd, title: t.tabTitle, hasClaude: t.hasClaude, tmuxSession: t.tmuxSession,
      attribution: t.attribution,
    })),
    reasons: w.matchSources || (w.matchSource ? [w.matchSource] : []),
  }));
}

export async function search(query: string, opts: SearchOptions = {}): Promise<SearchResult[]> {
  return withDaemon(client => searchWithClient(client, query, opts));
}

export async function deepSearch(query: string): Promise<SearchResult[]> {
  return search(query, { sources: ["all"] });
}

export function printResults(ranked: SearchResult[]): void {
  if (!ranked.length) return;
  for (const r of ranked) {
    const w = r.window;
    const age = w.lastInteraction ? ` \x1b[2m${relativeTime(w.lastInteraction)}\x1b[0m` : "";
    console.log(`  \x1b[1m${w.app}\x1b[0m  "${w.title}"  wid:${w.wid}  score:${r.score}  (${r.reasons.join(", ")})${age}`);
    for (const t of r.tabs) {
      const claude = t.hasClaude ? " \x1b[32m●\x1b[0m" : "";
      const tmux = t.tmuxSession ? ` \x1b[36m[${t.tmuxSession}]\x1b[0m` : "";
      // An app-level match knows the terminal app, not which of its windows holds the tab.
      const label = t.attribution === "app" ? "somewhere in this app" : `tab ${t.tab ?? "?"}`;
      console.log(`    ${label}: ${t.cwd || t.title}${claude}${tmux}`);
    }
    if (w.ocrSnippet) console.log(`    ocr: "${w.ocrSnippet}"`);
  }
  console.log();
}

export async function searchCommand(
  query: string | undefined,
  flags: Set<string>,
  rawArgs: string[] = []
): Promise<void> {
  if (!query) {
    console.log("Usage: lats search <query> [--quick | --terminal | --all | --deep | --sources=... | --after=... | --before=... | --json | --wid]");
    return;
  }

  const opts: SearchOptions = {};

  const sourcesFlag = rawArgs.find(a => a.startsWith("--sources="));
  if (sourcesFlag) {
    opts.sources = sourcesFlag.slice("--sources=".length).split(",");
  } else if (flags.has("--all") || flags.has("--deep")) {
    opts.sources = ["all"];
  } else if (flags.has("--quick")) {
    opts.sources = ["titles", "apps", "sessions"];
  } else if (flags.has("--terminal")) {
    opts.sources = ["terminals"];
  }

  const afterFlag = rawArgs.find(a => a.startsWith("--after="));
  if (afterFlag) opts.after = afterFlag.slice("--after=".length);
  const beforeFlag = rawArgs.find(a => a.startsWith("--before="));
  if (beforeFlag) opts.before = beforeFlag.slice("--before=".length);

  if (flags.has("--no-recency")) opts.recency = false;

  const ranked = await search(query, opts);
  const jsonOut = flags.has("--json");
  const widOnly = flags.has("--wid");

  if (jsonOut) {
    console.log(JSON.stringify(ranked.map(r => ({
      wid: r.window.wid, app: r.window.app, title: r.window.title,
      score: r.score, reasons: r.reasons, tabs: r.tabs, ocrSnippet: r.window.ocrSnippet,
    })), null, 2));
    return;
  }

  if (widOnly) {
    for (const r of ranked) console.log(r.window.wid);
    return;
  }

  if (!ranked.length) {
    console.log(`No results for "${query}"`);
    return;
  }

  printResults(ranked);
}

export async function placeWithClient(client: DaemonClient, query: string, placement: string, dryRun: boolean) {
  const ranked = await searchWithClient(client, query, { sources: ["all"] });
  // A result found only because its app owns a matching TTY names no window; don't move it.
  const top = ranked.find(r => r.reasons.some(reason => reason !== "terminal-app"));
  if (!top) return null;
  const window = top.window;
  if (!dryRun) await client.daemonCall("windows.focus", { wid: window.wid });
  const receipt = await client.daemonCall("windows.place", { wid: window.wid, placement, dryRun }, 3000);
  return { status: dryRun ? "planned" : "ok", window: { wid: window.wid, app: window.app, title: window.title }, placement, receipt };
}

export async function placeCommand(query?: string, tilePosition?: string, flags = new Set<string>()): Promise<void> {
  if (!query) {
    console.log("Usage: lats place <query> [position] [--dry-run] [--json]");
    return;
  }
  if ([...flags].some(flag => !["--dry-run", "--json"].includes(flag))) throw new Error("Usage: lats place <query> [position] [--dry-run] [--json]");
  const pos = normalizePlacement(tilePosition || "bottom-right");
  if (!pos) throw new Error(`Unknown placement: ${tilePosition}`);

  await withDaemon(async (client) => {
    const result = await placeWithClient(client, query, pos, flags.has("--dry-run"));
    if (!result) {
      if (flags.has("--json")) { console.log(JSON.stringify({ status: "not-found", query })); return; }
      console.log(`No window matching "${query}"`);
      return;
    }
    if (flags.has("--json")) console.log(JSON.stringify(result, null, 2));
    else console.log(`${flags.has("--dry-run") ? "Planned: " : ""}${result.window.app} "${result.window.title}" (wid:${result.window.wid}) → ${pos}`);
  });
}
