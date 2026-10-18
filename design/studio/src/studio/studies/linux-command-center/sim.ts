/**
 * Linux Command Center — local simulation.
 *
 * Everything here is invented study data for an Omarchy/Hyprland host named
 * archie. Nothing talks to a daemon and nothing moves a real window. The
 * project in the fixtures is "tideline", an invented codebase.
 *
 * Model:
 *   space  — a Hyprland workspace (OS-level desktop). Cycling spaces changes
 *            which desktop is on screen.
 *   layer  — a Lattices named window group. On Linux a layer operates inside
 *            the current space: its members are raised and tiled, the rest of
 *            that space's windows are parked behind. A layer never changes the
 *            workspace.
 */

export type Availability = "archie" | "concept";

export type Win = {
  wid: string;
  app: string;
  title: string;
  space: number;
  layer?: string;
  session?: string;
};

export type Session = { name: string; windows: number; attached: boolean; cwd: string };

export const HOST = {
  name: "archie",
  compositor: "Hyprland",
  shell: "Omarchy",
  port: 9399,
  pairedWith: "mini",
};

export const SPACES = [1, 2, 3, 4, 5] as const;

export const WINDOWS: readonly Win[] = [
  { wid: "0x4a10", app: "kitty", title: "nvim · src/tide/forecast.rs", space: 1, layer: "build", session: "tideline-4c1e9a" },
  { wid: "0x4a24", app: "kitty", title: "cargo watch -x test", space: 1, layer: "build", session: "tideline-4c1e9a" },
  { wid: "0x4b02", app: "chromium", title: "localhost:5173 — Tideline", space: 1, layer: "build" },
  { wid: "0x4b31", app: "chromium", title: "docs.rs — chrono::Duration", space: 1, layer: "docs" },
  { wid: "0x4c08", app: "obsidian", title: "tideline — tide tables notes", space: 1, layer: "docs" },
  { wid: "0x5110", app: "chromium", title: "tideline #212 — Review", space: 2, layer: "review" },
  { wid: "0x5122", app: "kitty", title: "git log --oneline — tideline", space: 2, layer: "review", session: "tideline-4c1e9a" },
  { wid: "0x5140", app: "kitty", title: "harbor — bun dev", space: 2, session: "harbor-7d20f3" },
  { wid: "0x6201", app: "kitty", title: "btop", space: 3 },
  { wid: "0x6215", app: "kitty", title: "ssh mini", space: 3, session: "dotfiles-e15a88" },
  { wid: "0x7302", app: "signal", title: "Signal", space: 4, layer: "comms" },
  { wid: "0x7318", app: "thunderbird", title: "Inbox — Thunderbird", space: 4, layer: "comms" },
];

export const SESSIONS: readonly Session[] = [
  { name: "tideline-4c1e9a", windows: 3, attached: true, cwd: "~/dev/tideline" },
  { name: "harbor-7d20f3", windows: 1, attached: false, cwd: "~/dev/harbor" },
  { name: "dotfiles-e15a88", windows: 1, attached: false, cwd: "~/.config" },
];

export function layersOn(space: number): string[] {
  const seen: string[] = [];
  for (const w of WINDOWS) if (w.space === space && w.layer && !seen.includes(w.layer)) seen.push(w.layer);
  return seen;
}

export const ALL_LAYERS = Array.from(new Set(WINDOWS.filter((w) => w.layer).map((w) => w.layer as string)));

export function winById(wid: string): Win | undefined {
  return WINDOWS.find((w) => w.wid === wid);
}

// ── hints pack: one source for the CLI (`lats hints`) and the app's Hints page ──

export type Hint = { keys: string; does: string; owner: "lats" | "omarchy" | "personal"; sim?: string };

export const HINTS: readonly Hint[] = [
  { keys: "F1 · Ctrl+5", does: "Hints", owner: "lats", sim: "? in the study" },
  { keys: "Ctrl+K", does: "Search windows", owner: "lats", sim: "/ also works" },
  { keys: "Ctrl+1–4", does: "App pages", owner: "lats" },
  { keys: "Ctrl+← →", does: "Cycle spaces", owner: "personal", sim: "[ ] in the study" },
  { keys: "Super+arrows", does: "Focus window", owner: "omarchy", sim: "arrows in the study" },
  { keys: "Super+Shift+arrows", does: "Swap window", owner: "omarchy", sim: "Shift+arrows" },
];

// ── command surface ──

export type CommandSpec = { usage: string; status: Availability; note: string };

export const COMMANDS: readonly CommandSpec[] = [
  { usage: "lats search <query>", status: "archie", note: "Title, app, session. Deep terminal/OCR search is macOS-only." },
  { usage: "lats focus <query>", status: "archie", note: "Top search match, focused." },
  { usage: "lats place <query> [position]", status: "archie", note: "Search, focus, tile." },
  { usage: "lats sessions", status: "archie", note: "tmux sessions on this host." },
  { usage: "lats layers · lats layer <name>", status: "archie", note: "Named window groups inside the current space." },
  { usage: "lats hints [--json|--open]", status: "archie", note: "Shared hints pack." },
  { usage: "lats spaces", status: "concept", note: "Workspace inventory." },
  { usage: "lats space next|prev|previous|<id>", status: "concept", note: "Change workspace." },
  { usage: "lats window focus <wid>", status: "concept", note: "Exact focus by window id." },
  { usage: "lats app status|quit|restart", status: "concept", note: "Quickshell app lifecycle." },
  { usage: "lats doctor [--json]", status: "concept", note: "Host checks." },
];

// ── state ──

export type LogTone = "archie" | "concept" | "error" | "sim";
export type LogEntry = { seq: number; text: string; tone: LogTone };

export type SimState = {
  space: number;
  previous: number;
  layer: Record<number, string | null>;
  focus: Record<number, string | null>;
  order: Record<number, string[]>;
  log: LogEntry[];
  seq: number;
};

export function initialState(): SimState {
  const order: Record<number, string[]> = {};
  const focus: Record<number, string | null> = {};
  for (const s of SPACES) {
    order[s] = WINDOWS.filter((w) => w.space === s).map((w) => w.wid);
    focus[s] = order[s][0] ?? null;
  }
  return {
    space: 1,
    previous: 2,
    layer: { 1: "build", 2: null, 3: null, 4: null, 5: null },
    focus,
    order,
    log: [{ seq: 1, text: "snapshot loaded · 5 spaces · 12 windows", tone: "sim" }],
    seq: 1,
  };
}

export function withLog(s: SimState, text: string, tone: LogTone): SimState {
  const seq = s.seq + 1;
  return { ...s, seq, log: [{ seq, text, tone }, ...s.log].slice(0, 40) };
}

/** Windows drawn on a space: the active layer's members, else everything. */
export function visibleOn(s: SimState, space: number): Win[] {
  const layer = s.layer[space];
  return s.order[space]
    .map((id) => winById(id) as Win)
    .filter((w) => !layer || w.layer === layer);
}

export function parkedOn(s: SimState, space: number): Win[] {
  const layer = s.layer[space];
  if (!layer) return [];
  return s.order[space].map((id) => winById(id) as Win).filter((w) => w.layer !== layer);
}

export function gotoSpace(s: SimState, target: number, via: string, tone: LogTone): SimState {
  if (target === s.space) return withLog(s, `${via} · already on space ${target}`, tone);
  return withLog({ ...s, previous: s.space, space: target }, `${via} · space ${s.space} → ${target}`, tone);
}

export function cycle(s: SimState, dir: 1 | -1, via: string, tone: LogTone): SimState {
  const i = SPACES.indexOf(s.space as (typeof SPACES)[number]);
  const next = SPACES[(i + dir + SPACES.length) % SPACES.length];
  return gotoSpace(s, next, via, tone);
}

export function focusWid(s: SimState, wid: string, via: string, tone: LogTone): SimState {
  const w = winById(wid);
  if (!w) return withLog(s, `${via} · no window ${wid}`, "error");
  let next: SimState = { ...s, focus: { ...s.focus, [w.space]: wid } };
  if (w.space !== s.space) next = { ...next, previous: s.space, space: w.space };
  // Focusing a parked window brings its layer forward; the workspace is unchanged.
  const layer = next.layer[w.space];
  if (layer && w.layer !== layer) next = { ...next, layer: { ...next.layer, [w.space]: w.layer ?? null } };
  return withLog(next, `${via} · focus ${wid} ${w.app} (space ${w.space})`, tone);
}

export function setLayer(s: SimState, layer: string | null, via: string, tone: LogTone): SimState {
  const space = s.space;
  const members = layer ? WINDOWS.filter((w) => w.space === space && w.layer === layer) : [];
  if (layer && members.length === 0) {
    return withLog(s, `${via} · layer "${layer}" has no windows on space ${space}`, "error");
  }
  const focus = layer ? { ...s.focus, [space]: members[0].wid } : s.focus;
  return withLog(
    { ...s, focus, layer: { ...s.layer, [space]: layer } },
    layer ? `${via} · layer ${layer} raised on space ${space} · ${members.length} windows` : `${via} · all windows on space ${space}`,
    tone,
  );
}

// ── geometry: dwindle tiling in a 16:9 frame (fractions of the space) ──

export type Rect = { x: number; y: number; w: number; h: number };

export function dwindle(n: number): Rect[] {
  const out: Rect[] = [];
  let r: Rect = { x: 0, y: 0, w: 1, h: 1 };
  for (let i = 0; i < n; i++) {
    if (i === n - 1) {
      out.push(r);
      break;
    }
    if (r.w * 16 >= r.h * 9) {
      out.push({ ...r, w: r.w / 2 });
      r = { ...r, x: r.x + r.w / 2, w: r.w / 2 };
    } else {
      out.push({ ...r, h: r.h / 2 });
      r = { ...r, y: r.y + r.h / 2, h: r.h / 2 };
    }
  }
  return out;
}

export type Dir = "left" | "right" | "up" | "down";

function neighbour(s: SimState, dir: Dir): string | null {
  const wins = visibleOn(s, s.space);
  const rects = dwindle(wins.length);
  const i = wins.findIndex((w) => w.wid === s.focus[s.space]);
  if (i < 0) return wins[0]?.wid ?? null;
  const c = (r: Rect) => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
  const from = c(rects[i]);
  let best: { wid: string; d: number } | null = null;
  wins.forEach((w, j) => {
    if (j === i) return;
    const to = c(rects[j]);
    const dx = (to.x - from.x) * 16;
    const dy = (to.y - from.y) * 9;
    const ok = dir === "left" ? dx < -0.01 : dir === "right" ? dx > 0.01 : dir === "up" ? dy < -0.01 : dy > 0.01;
    if (!ok) return;
    const along = dir === "left" || dir === "right" ? Math.abs(dx) : Math.abs(dy);
    const across = dir === "left" || dir === "right" ? Math.abs(dy) : Math.abs(dx);
    const d = along + across * 2;
    if (!best || d < best.d) best = { wid: w.wid, d };
  });
  return (best as { wid: string; d: number } | null)?.wid ?? null;
}

export function moveFocus(s: SimState, dir: Dir): SimState {
  const target = neighbour(s, dir);
  if (!target) return withLog(s, `Super+${dir} · edge, nothing ${dir}`, "sim");
  return withLog({ ...s, focus: { ...s.focus, [s.space]: target } }, `Super+${dir} · focus ${target}`, "sim");
}

export function swap(s: SimState, dir: Dir): SimState {
  const a = s.focus[s.space];
  const b = neighbour(s, dir);
  if (!a || !b) return withLog(s, `Super+Shift+${dir} · edge, no swap`, "sim");
  const order = [...s.order[s.space]];
  const ia = order.indexOf(a);
  const ib = order.indexOf(b);
  [order[ia], order[ib]] = [order[ib], order[ia]];
  return withLog({ ...s, order: { ...s.order, [s.space]: order } }, `Super+Shift+${dir} · swap ${a} ↔ ${b}`, "sim");
}

// ── search: title / app / session (no deep sources on Linux) ──

export type Hit = { win: Win; score: number; field: "title" | "app" | "session" };

export function search(q: string): Hit[] {
  const needle = q.trim().toLowerCase();
  if (!needle) return [];
  const hits: Hit[] = [];
  for (const w of WINDOWS) {
    if (w.title.toLowerCase().includes(needle)) hits.push({ win: w, score: 3, field: "title" });
    else if (w.session?.toLowerCase().includes(needle)) hits.push({ win: w, score: 3, field: "session" });
    else if (w.app.toLowerCase().includes(needle)) hits.push({ win: w, score: 2, field: "app" });
  }
  return hits.sort((a, b) => b.score - a.score);
}

// ── command runner: pure, returns transcript lines and the next state ──

export type Tone = "dim" | "strong" | "cyan" | "green" | "amber" | "red";
export type Line = { text: string; tone?: Tone };

export type RunResult = {
  input: string;
  status: Availability | "error" | "local";
  lines: Line[];
  next: SimState;
};

const pad = (v: string, n: number) => (v.length > n ? `${v.slice(0, n - 1)}…` : v.padEnd(n));

function conceptLine(): Line {
  return { text: "concept · command not confirmed on archie yet — output is a study mock", tone: "amber" };
}

export function run(raw: string, s: SimState): RunResult {
  const input = raw.trim();
  const argv = input.replace(/^lats\s+/, "").replace(/^lattices\s+/, "").split(/\s+/).filter(Boolean);
  const [cmd, ...rest] = argv;
  const arg = rest.join(" ");
  const res = (status: RunResult["status"], lines: Line[], next = s): RunResult => ({ input, status, lines, next });

  switch (cmd) {
    case undefined:
      return res("local", []);
    case "help": {
      return res(
        "local",
        COMMANDS.map((c) => ({
          text: `${pad(c.usage, 38)} ${c.status === "archie" ? "archie " : "concept"}  ${c.note}`,
          tone: c.status === "archie" ? undefined : "amber",
        })),
      );
    }
    case "spaces": {
      const lines: Line[] = [
        conceptLine(),
        { text: `${pad("SPACE", 7)}${pad("WINDOWS", 9)}${pad("LAYER", 10)}STATE`, tone: "dim" },
      ];
      for (const sp of SPACES) {
        const n = s.order[sp].length;
        const state = sp === s.space ? "current" : sp === s.previous ? "previous" : n ? "" : "empty";
        lines.push({ text: `${pad(String(sp), 7)}${pad(String(n), 9)}${pad(s.layer[sp] ?? "—", 10)}${state}`, tone: sp === s.space ? "cyan" : undefined });
      }
      return res("concept", lines, withLog(s, "lats spaces", "concept"));
    }
    case "space": {
      const via = `lats space ${arg}`;
      let next: SimState;
      if (arg === "next") next = cycle(s, 1, via, "concept");
      else if (arg === "prev") next = cycle(s, -1, via, "concept");
      else if (arg === "previous") next = gotoSpace(s, s.previous, via, "concept");
      else if (SPACES.includes(Number(arg) as (typeof SPACES)[number])) next = gotoSpace(s, Number(arg), via, "concept");
      else return res("error", [{ text: `usage: lats space next|prev|previous|<1-${SPACES.length}>`, tone: "red" }]);
      return res("concept", [conceptLine(), { text: next.log[0].text.split(" · ")[1], tone: "cyan" }], next);
    }
    case "window": {
      if (rest[0] !== "focus" || !rest[1]) return res("error", [{ text: "usage: lats window focus <wid>", tone: "red" }]);
      const next = focusWid(s, rest[1], `lats window focus ${rest[1]}`, "concept");
      const ok = next.log[0].tone !== "error";
      return res(ok ? "concept" : "error", [conceptLine(), { text: next.log[0].text.split(" · ")[1], tone: ok ? "cyan" : "red" }], next);
    }
    case "search":
    case "s": {
      const deep = rest.includes("--deep") || rest.includes("--all");
      const q = rest.filter((r) => !r.startsWith("--")).join(" ");
      const hits = search(q);
      const lines: Line[] = [];
      if (deep) lines.push({ text: "--deep: terminal and OCR sources are unavailable on Linux · index search only", tone: "amber" });
      if (!hits.length) lines.push({ text: `no windows match "${q}"`, tone: "dim" });
      else {
        lines.push({ text: `${pad("WID", 8)}${pad("SPACE", 7)}${pad("APP", 12)}${pad("MATCH", 9)}TITLE`, tone: "dim" });
        hits.forEach((h) => lines.push({ text: `${pad(h.win.wid, 8)}${pad(String(h.win.space), 7)}${pad(h.win.app, 12)}${pad(h.field, 9)}${h.win.title}` }));
      }
      return res("archie", lines, withLog(s, `lats search ${q} · ${hits.length} hits`, "archie"));
    }
    case "focus": {
      const hit = search(arg)[0];
      if (!hit) return res("error", [{ text: `no windows match "${arg}"`, tone: "red" }]);
      const next = focusWid(s, hit.win.wid, `lats focus ${arg}`, "archie");
      return res("archie", [{ text: `focused ${hit.win.wid} ${hit.win.app} — ${hit.win.title}`, tone: "cyan" }], next);
    }
    case "place": {
      const pos = rest.length > 1 ? rest[rest.length - 1] : "bottom-right";
      const q = rest.length > 1 ? rest.slice(0, -1).join(" ") : arg;
      const hit = search(q)[0];
      if (!hit) return res("error", [{ text: `no windows match "${q}"`, tone: "red" }]);
      const next = focusWid(s, hit.win.wid, `lats place ${q} ${pos}`, "archie");
      return res(
        "archie",
        [
          { text: `focused ${hit.win.wid} ${hit.win.app} — ${hit.win.title}`, tone: "cyan" },
          { text: `placement ${pos} recorded · study does not resize windows`, tone: "dim" },
        ],
        next,
      );
    }
    case "sessions": {
      const lines: Line[] = [{ text: `${pad("SESSION", 18)}${pad("WIN", 5)}${pad("STATE", 10)}CWD`, tone: "dim" }];
      SESSIONS.forEach((x) => lines.push({ text: `${pad(x.name, 18)}${pad(String(x.windows), 5)}${pad(x.attached ? "attached" : "detached", 10)}${x.cwd}`, tone: x.attached ? "strong" : undefined }));
      return res("archie", lines, withLog(s, "lats sessions", "archie"));
    }
    case "layers": {
      const lines: Line[] = [
        { text: `space ${s.space} · layers act inside this workspace`, tone: "dim" },
        { text: `${pad("LAYER", 10)}${pad("WINDOWS", 9)}STATE`, tone: "dim" },
      ];
      const here = layersOn(s.space);
      if (!here.length) lines.push({ text: "no layers on this space", tone: "dim" });
      here.forEach((l) => {
        const n = WINDOWS.filter((w) => w.space === s.space && w.layer === l).length;
        lines.push({ text: `${pad(l, 10)}${pad(String(n), 9)}${s.layer[s.space] === l ? "raised" : ""}`, tone: s.layer[s.space] === l ? "cyan" : undefined });
      });
      return res("archie", lines, withLog(s, "lats layers", "archie"));
    }
    case "layer": {
      const name = arg === "off" || arg === "all" ? null : arg;
      if (name === "") return res("error", [{ text: "usage: lats layer <name>|off", tone: "red" }]);
      const next = setLayer(s, name, `lats layer ${arg}`, "archie");
      const ok = next.log[0].tone !== "error";
      return res(ok ? "archie" : "error", [{ text: next.log[0].text.split(" · ").slice(1).join(" · "), tone: ok ? "cyan" : "red" }], next);
    }
    case "hints": {
      if (rest.includes("--json")) {
        return res("archie", [{ text: JSON.stringify(HINTS.map(({ keys, does, owner }) => ({ keys, does, owner }))), tone: "dim" }]);
      }
      if (rest.includes("--open")) {
        return res("archie", [{ text: "would open the app's Hints page · study opens the rail instead", tone: "dim" }], withLog(s, "lats hints --open", "archie"));
      }
      return res("archie", HINTS.map((h) => ({ text: `${pad(h.keys, 20)}${pad(h.does, 16)}${h.owner}` })));
    }
    case "app": {
      const sub = rest[0] ?? "status";
      if (sub === "status") {
        return res("concept", [
          conceptLine(),
          { text: "quickshell app   running", tone: "green" },
          { text: `host             ${HOST.compositor} on :${HOST.port}` },
          { text: "tray             Omarchy" },
        ]);
      }
      if (sub === "quit" || sub === "restart") {
        return res("concept", [conceptLine(), { text: `lats app ${sub} · not executed in the study`, tone: "amber" }], withLog(s, `lats app ${sub} · not executed`, "concept"));
      }
      return res("error", [{ text: "usage: lats app status|quit|restart", tone: "red" }]);
    }
    case "doctor": {
      const checks: Line[] = [
        { text: `ok    hyprland host on :${HOST.port}`, tone: "green" },
        { text: "ok    hyprctl reachable", tone: "green" },
        { text: "ok    tmux on PATH · 3 sessions", tone: "green" },
        { text: `ok    paired with ${HOST.pairedWith}`, tone: "green" },
        { text: "skip  deep search — terminal/OCR sources are macOS-only", tone: "dim" },
      ];
      if (rest.includes("--json")) {
        return res("concept", [conceptLine(), { text: '{"ok":true,"checks":5,"skipped":["deep-search"]}', tone: "dim" }]);
      }
      return res("concept", [conceptLine(), ...checks], withLog(s, "lats doctor · 4 ok · 1 skip", "concept"));
    }
    default:
      return res("error", [{ text: `unknown command "${cmd}" · try help`, tone: "red" }]);
  }
}
