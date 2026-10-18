"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { daemonCall } from "@/studio/lib/daemon";
import type { LatticesPage } from "@/studio/studioRegistry";
import { DaemonConnection } from "@/studio/lib/DaemonConnection";
import {
  scenarios,
  scenarioById,
  toWorkerSnapshot,
  type Scenario,
} from "@/studio/lib/handsoffScenarios";
import {
  buckets,
  prompts as promptLibrary,
  isHighlighted,
  type PromptEntry,
} from "@/studio/lib/handsoffPrompts";
import {
  applyActions,
  cloneScenario,
  formatRect,
  humanPosition,
  liveRowsToScenario,
  type Action,
  type ExecLogEntry,
  type ExecResult,
  type ResolvedTarget,
} from "@/studio/lib/handsoffMockExecutor";

interface HandsoffStudyProps {
  entry: LatticesPage;
}

interface WindowRow {
  wid: number;
  app: string;
  title?: string;
  isOnScreen?: boolean;
}

interface TerminalRow {
  app?: string;
  tabTitle?: string;
  cwd?: string;
  hasClaude?: boolean;
}

interface DisplayRow {
  displayIndex: number;
  displayId: string;
  currentSpaceId: number;
  spaces: { id: number; index: number; isCurrent: boolean }[];
  name?: string;
}

interface WorkerMeta {
  provider?: string;
  model?: string;
  tokens?: number;
  durationMs?: number;
  [key: string]: unknown;
}

interface WorkerData {
  spoken?: string;
  actions?: Action[];
  _meta?: WorkerMeta;
  [key: string]: unknown;
}

interface WorkerResponse {
  data?: WorkerData;
  [key: string]: unknown;
}

type Source = { kind: "live" } | { kind: "scenario"; id: string };

interface Turn {
  prompt: string;
  startedAt: number;
  totalMs?: number;
  windows?: WindowRow[];
  terminals?: TerminalRow[];
  displays?: DisplayRow[];
  response?: WorkerResponse;
  error?: string;
  source: Source;
}

function scenarioToRows(s: Scenario): {
  windows: WindowRow[];
  terminals: TerminalRow[];
  displays: DisplayRow[];
} {
  return {
    windows: s.windows.map((w) => ({
      wid: w.wid,
      app: w.app,
      title: w.title,
      isOnScreen: w.onScreen,
    })),
    terminals: s.terminals.map((t) => ({
      app: t.app,
      tabTitle: t.tabTitle,
      cwd: t.cwd,
      hasClaude: t.hasClaude,
    })),
    displays: s.displays.map((d) => ({
      displayIndex: d.displayIndex,
      displayId: d.displayId,
      currentSpaceId: d.currentSpaceId,
      spaces: d.spaces,
      name: d.name,
    })),
  };
}

export function HandsoffStudy({ entry }: HandsoffStudyProps) {
  const [prompt, setPrompt] = useState("");
  const [running, setRunning] = useState(false);
  const [turn, setTurn] = useState<Turn | null>(null);
  const [source, setSource] = useState<Source>({ kind: "live" });
  const [world, setWorld] = useState<Scenario | null>(null);
  const [simResult, setSimResult] = useState<ExecResult | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Reset world + turn when scenario changes
  useEffect(() => {
    if (source.kind === "scenario") {
      const base = scenarioById[source.id];
      if (base) setWorld(cloneScenario(base));
    } else {
      setWorld(null);
    }
    setTurn(null);
    setSimResult(null);
  }, [source]);

  async function runTurn(text: string) {
    const trimmed = text.trim();
    if (!trimmed || running) return;
    const startedAt = Date.now();
    setRunning(true);
    setSimResult(null);
    setTurn({ prompt: trimmed, startedAt, source });

    let windows: WindowRow[] | undefined;
    let terminals: TerminalRow[] | undefined;
    let displays: DisplayRow[] | undefined;
    let response: (WorkerResponse & { __error?: string }) | undefined;

    if (source.kind === "scenario" && world) {
      const rows = scenarioToRows(world);
      windows = rows.windows;
      terminals = rows.terminals;
      displays = rows.displays;
      response = await daemonCall<WorkerResponse>(
        "assistant.preview",
        { text: trimmed, snapshot: toWorkerSnapshot(world), trace: true },
        60_000,
      ).catch((err: Error) => ({ __error: err.message }) as WorkerResponse & { __error?: string });
    } else {
      const winP = daemonCall<WindowRow[]>("windows.list").catch(() => undefined);
      const termP = daemonCall<TerminalRow[]>("terminals.list").catch(() => undefined);
      const spacesP = daemonCall<DisplayRow[]>("spaces.list").catch(() => undefined);
      const responseP = daemonCall<WorkerResponse>("assistant.preview", { text: trimmed, trace: true }, 60_000).catch(
        (err: Error) => ({ __error: err.message }) as WorkerResponse & { __error?: string },
      );
      [windows, terminals, displays, response] = await Promise.all([winP, termP, spacesP, responseP]);
    }

    const totalMs = Date.now() - startedAt;
    const next: Turn = {
      prompt: trimmed,
      startedAt,
      totalMs,
      windows,
      terminals,
      displays,
      source,
    };
    const errorMsg = (response as { __error?: string } | undefined)?.__error;
    if (errorMsg) next.error = errorMsg;
    else next.response = response as WorkerResponse;

    setTurn(next);
    setRunning(false);
  }

  function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    runTurn(prompt);
  }

  // Compute the resolved plan eagerly so the Actions pane can show what
  // *would* happen without the user clicking commit. In scenario mode the
  // plan runs against the live `world`; in live mode we synthesize a Scenario
  // from windows.list / terminals.list / spaces.list — geometry will be
  // unknown but target resolution by wid/app still works.
  const planSource = useMemo<Scenario | null>(() => {
    if (source.kind === "scenario") return world;
    if (turn) return liveRowsToScenario(turn.windows, turn.terminals, turn.displays);
    return null;
  }, [source, world, turn]);

  const plannedLog = useMemo<ExecLogEntry[] | null>(() => {
    const actions = turn?.response?.data?.actions ?? [];
    if (!planSource || !actions.length) return null;
    return applyActions(planSource, actions).log;
  }, [planSource, turn]);

  function commitPlan() {
    if (!world) return;
    const actions = turn?.response?.data?.actions ?? [];
    if (!actions.length) return;
    const result = applyActions(world, actions);
    setSimResult(result);
    setWorld(result.scenario);
  }

  function resetWorld() {
    if (source.kind === "scenario") {
      const base = scenarioById[source.id];
      if (base) setWorld(cloneScenario(base));
      setSimResult(null);
    }
  }

  const scenarioId = source.kind === "scenario" ? source.id : null;

  return (
    <main className="max-w-6xl px-6 py-8">
      <header>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          studio · handsoff
        </p>
        <h1 className="mt-2 font-sans text-4xl font-medium tracking-tight text-studio-ink sm:text-5xl">
          {entry.label}
        </h1>
        <p className="mt-4 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
          The open-ended path. Pick a scenario (or your live desktop), say
          something messy, and watch the hands-off worker reason against the
          snapshot. The daemon returns a dry-run plan:{" "}
          <span style={{ color: "var(--scout-accent)" }}>no real windows move</span>.
        </p>
      </header>

      <section className="mt-8">
        <DaemonConnection />
      </section>

      <ScenarioPicker source={source} onChange={setSource} world={world} onReset={resetWorld} />

      <PromptPane
        ref={inputRef}
        prompt={prompt}
        onPrompt={setPrompt}
        onSubmit={onSubmit}
        onSuggestion={(s) => {
          setPrompt(s);
          runTurn(s);
        }}
        running={running}
        scenarioId={scenarioId}
      />

      {turn ? (
        <>
          <SnapshotPane turn={turn} world={world} />
          <ReasoningPane turn={turn} />
          <ActionsPane turn={turn} plannedLog={plannedLog} planSource={planSource} sourceKind={source.kind} />
          <SpokenPane turn={turn} />
          <ExecutePane
            turn={turn}
            world={world}
            simResult={simResult}
            onCommit={commitPlan}
            onReset={resetWorld}
          />
        </>
      ) : (
        <p className="mt-12 font-mono text-[11.5px] text-studio-ink-faint">
          Pick a suggestion above or type your own. Every turn calls{" "}
          <code className="text-studio-ink">assistant.preview</code> against the
          local daemon with trace enabled, so the daemon also writes a rich trace to{" "}
          <code className="text-studio-ink">~/.lattices/assistant-preview-debug.jsonl</code>.
        </p>
      )}

      <footer className="mt-20 border-t border-studio-edge pt-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          source · AssistantPreviewPlanner.swift · LatticesApi.swift (assistant.preview) · handsoff-infer.ts · assistant-intelligence.ts · handsoffScenarios.ts · handsoffMockExecutor.ts
        </p>
      </footer>
    </main>
  );
}

// ── Scenario picker ──────────────────────────────────────────────────────

function ScenarioPicker({
  source,
  onChange,
  world,
  onReset,
}: {
  source: Source;
  onChange: (s: Source) => void;
  world: Scenario | null;
  onReset: () => void;
}) {
  const active = source.kind === "scenario" ? scenarioById[source.id] : null;
  return (
    <section className="mt-8">
      <div className="flex items-baseline justify-between border-b border-studio-edge pb-2">
        <div className="flex items-baseline gap-3">
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            00 · stage
          </span>
          <h3 className="font-mono text-[13px] text-studio-ink">Where does the agent live?</h3>
        </div>
        {source.kind === "scenario" && world ? (
          <button
            type="button"
            onClick={onReset}
            className="font-mono text-[10px] uppercase tracking-[0.18em] text-studio-ink-faint hover:text-studio-ink"
          >
            reset scenario ↺
          </button>
        ) : null}
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        <ScenarioChip
          label="live desktop"
          blurb="Real windows, real snapshot. Mock execution still applies."
          selected={source.kind === "live"}
          onSelect={() => onChange({ kind: "live" })}
        />
        {scenarios.map((s) => (
          <ScenarioChip
            key={s.id}
            label={s.name}
            blurb={s.blurb}
            selected={source.kind === "scenario" && source.id === s.id}
            onSelect={() => onChange({ kind: "scenario", id: s.id })}
          />
        ))}
      </div>
      {active ? (
        <p className="mt-3 max-w-2xl font-mono text-[10.5px] text-studio-ink-faint">
          {active.windows.filter((w) => w.onScreen).length} on-screen window
          {active.windows.filter((w) => w.onScreen).length === 1 ? "" : "s"} ·{" "}
          {active.terminals.length} terminal tab{active.terminals.length === 1 ? "" : "s"} ·{" "}
          {active.displays.length} display{active.displays.length === 1 ? "" : "s"} · layer{" "}
          <span className="text-studio-ink">{active.currentLayer ?? "—"}</span>
        </p>
      ) : null}
    </section>
  );
}

function ScenarioChip({
  label,
  blurb,
  selected,
  onSelect,
}: {
  label: string;
  blurb: string;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      title={blurb}
      className={[
        "rounded-sm border px-3 py-2 text-left transition-colors",
        selected
          ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-canvas)]"
          : "border-studio-edge hover:border-studio-ink-faint",
      ].join(" ")}
    >
      <span
        className="block font-mono text-[11.5px]"
        style={selected ? { color: "var(--scout-accent)" } : undefined}
      >
        {label}
      </span>
      <span className="mt-0.5 block max-w-[260px] font-sans text-[11px] leading-snug text-studio-ink-faint">
        {blurb}
      </span>
    </button>
  );
}

// ── Prompt pane ──────────────────────────────────────────────────────────

function PromptPane({
  ref,
  prompt,
  onPrompt,
  onSubmit,
  onSuggestion,
  running,
  scenarioId,
}: {
  ref?: React.Ref<HTMLInputElement>;
  prompt: string;
  onPrompt: (v: string) => void;
  onSubmit: (e: React.FormEvent) => void;
  onSuggestion: (s: string) => void;
  running: boolean;
  scenarioId: string | null;
}) {
  const canRun = prompt.trim().length > 0 && !running;
  const [filter, setFilter] = useState<"all" | "highlighted">("all");

  const visible = useMemo(() => {
    if (filter === "all" || !scenarioId) return promptLibrary;
    return promptLibrary.filter((p) => isHighlighted(p, scenarioId));
  }, [filter, scenarioId]);

  const byBucket = useMemo(() => {
    const map = new Map<string, PromptEntry[]>();
    for (const b of buckets) map.set(b.id, []);
    for (const p of visible) map.get(p.bucket)?.push(p);
    return map;
  }, [visible]);

  return (
    <section className="mt-10">
      <PaneHeading step="01 · prompt" title="Transcript" />
      <form onSubmit={onSubmit} className="mt-4 flex flex-col gap-3">
        <div className="flex items-stretch gap-2">
          <input
            ref={ref}
            value={prompt}
            onChange={(e) => onPrompt(e.target.value)}
            placeholder="say something the agent would hear…"
            disabled={running}
            spellCheck={false}
            className="flex-1 rounded-sm border border-studio-edge bg-transparent px-3 py-2.5 font-mono text-[13px] text-studio-ink outline-none focus:border-[color:var(--scout-accent)] disabled:opacity-50"
          />
          <button
            type="submit"
            disabled={!canRun}
            className={[
              "shrink-0 rounded-sm border px-4 py-2 font-mono text-[11px] uppercase tracking-[0.18em] transition-colors",
              canRun
                ? "border-[color:var(--scout-accent)] text-[color:var(--scout-accent)] hover:bg-[color:var(--studio-edge)]"
                : "border-studio-edge text-studio-ink-faint",
            ].join(" ")}
          >
            {running ? "thinking…" : "run turn"}
          </button>
        </div>

        <div className="flex items-baseline justify-between border-b border-studio-edge pb-1">
          <span className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
            prompt library
          </span>
          {scenarioId ? (
            <div className="flex gap-3 font-mono text-[10px] uppercase tracking-[0.18em]">
              <button
                type="button"
                onClick={() => setFilter("all")}
                className={filter === "all" ? "text-studio-ink" : "text-studio-ink-faint hover:text-studio-ink"}
              >
                all
              </button>
              <button
                type="button"
                onClick={() => setFilter("highlighted")}
                className={filter === "highlighted" ? "text-studio-ink" : "text-studio-ink-faint hover:text-studio-ink"}
              >
                best on this scenario
              </button>
            </div>
          ) : null}
        </div>

        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {buckets.map((b) => {
            const items = byBucket.get(b.id) ?? [];
            if (!items.length) return null;
            return (
              <div key={b.id}>
                <div className="flex items-baseline justify-between">
                  <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-studio-ink">
                    {b.label}
                  </p>
                  <p className="font-mono text-[9px] text-studio-ink-faint">{items.length}</p>
                </div>
                <p className="mt-0.5 font-sans text-[10.5px] leading-snug text-studio-ink-faint">
                  {b.blurb}
                </p>
                <ul className="mt-2 flex flex-col gap-1">
                  {items.map((p) => {
                    const hot = isHighlighted(p, scenarioId);
                    return (
                      <li key={p.text}>
                        <button
                          type="button"
                          onClick={() => onSuggestion(p.text)}
                          disabled={running}
                          className={[
                            "w-full rounded-sm border px-2 py-1 text-left font-mono text-[11px] transition-colors disabled:opacity-50",
                            hot
                              ? "border-[color:var(--scout-accent)] text-studio-ink hover:bg-[color:var(--studio-edge)]"
                              : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                          ].join(" ")}
                        >
                          {p.text}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              </div>
            );
          })}
        </div>
      </form>
    </section>
  );
}

// ── Snapshot pane ────────────────────────────────────────────────────────

function SnapshotPane({ turn, world }: { turn: Turn; world: Scenario | null }) {
  const winCount = turn.windows?.length;
  const termCount = turn.terminals?.length;
  const displayCount = turn.displays?.length;
  const onScreen = turn.windows?.filter((w) => w.isOnScreen !== false).length;
  const isScenario = turn.source.kind === "scenario";

  return (
    <section className="mt-10">
      <PaneHeading
        step="02 · snapshot"
        title="What the model sees"
        meta={isScenario ? `mock · ${world?.name ?? ""}` : "live · daemon-built"}
      />
      {turn.displays && turn.displays.length ? (
        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {turn.displays.map((d) => {
            const current = d.spaces.find((s) => s.isCurrent);
            return (
              <div
                key={d.displayId}
                className="rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-4"
              >
                <div className="flex items-baseline justify-between">
                  <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                    display · {d.displayIndex}
                    {d.name ? ` · ${d.name}` : ""}
                  </p>
                  <span className="ml-2 truncate font-mono text-[9.5px] text-studio-ink-faint">
                    {d.displayId.slice(0, 16)}
                  </span>
                </div>
                <p className="mt-2 font-mono text-[12px] text-studio-ink">
                  {d.spaces.length} space{d.spaces.length === 1 ? "" : "s"}
                  {current ? (
                    <>
                      <span className="text-studio-ink-faint"> · current </span>
                      <span style={{ color: "var(--scout-accent)" }}>
                        #{current.index}
                      </span>
                    </>
                  ) : null}
                </p>
              </div>
            );
          })}
        </div>
      ) : null}

      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <Block label={`windows · ${winCount ?? "—"}${onScreen != null ? ` · ${onScreen} on screen` : ""}`}>
          {turn.windows ? (
            <ScrollList>
              {turn.windows.slice(0, 20).map((w) => (
                <li
                  key={w.wid}
                  className="flex items-baseline justify-between gap-2 border-b border-studio-edge py-1 last:border-b-0"
                >
                  <span className="truncate font-sans text-[12.5px] text-studio-ink">
                    <span className="text-studio-ink-faint">{w.app}</span>
                    {w.title ? ` · ${w.title}` : ""}
                  </span>
                  <span className="shrink-0 font-mono text-[10px] text-studio-ink-faint tabular-nums">
                    #{w.wid}
                  </span>
                </li>
              ))}
              {turn.windows.length > 20 ? (
                <li className="pt-1 font-mono text-[10px] text-studio-ink-faint">
                  + {turn.windows.length - 20} more
                </li>
              ) : null}
            </ScrollList>
          ) : (
            <p className="font-mono text-[10.5px] text-studio-ink-faint">—</p>
          )}
        </Block>
        <Block label={`terminals · ${termCount ?? "—"}${displayCount ? ` · ${displayCount} display${displayCount === 1 ? "" : "s"}` : ""}`}>
          {turn.terminals && turn.terminals.length ? (
            <ScrollList>
              {turn.terminals.slice(0, 16).map((t, i) => (
                <li
                  key={i}
                  className="flex items-baseline justify-between gap-2 border-b border-studio-edge py-1 last:border-b-0"
                >
                  <span className="truncate font-sans text-[12.5px] text-studio-ink">
                    <span className="text-studio-ink-faint">{t.app ?? "term"}</span>
                    {t.tabTitle ? ` · ${t.tabTitle}` : ""}
                    {t.cwd ? <span className="text-studio-ink-faint"> · {t.cwd.replace(/^\/Users\/[^/]+\//, "~/")}</span> : null}
                  </span>
                  {t.hasClaude ? (
                    <span
                      className="shrink-0 font-mono text-[9px] uppercase tracking-[0.18em]"
                      style={{ color: "var(--scout-accent)" }}
                    >
                      claude
                    </span>
                  ) : null}
                </li>
              ))}
              {turn.terminals.length > 16 ? (
                <li className="pt-1 font-mono text-[10px] text-studio-ink-faint">
                  + {turn.terminals.length - 16} more
                </li>
              ) : null}
            </ScrollList>
          ) : (
            <p className="font-mono text-[10.5px] text-studio-ink-faint">—</p>
          )}
        </Block>
      </div>

      <p className="mt-3 font-mono text-[10px] text-studio-ink-faint">
        {isScenario
          ? "rendered from the scenario · passed to assistant.preview as a snapshot override"
          : "rendered from windows.list / terminals.list / spaces.list · daemon builds its own snapshot inside assistant.preview"}
      </p>
    </section>
  );
}

// ── Reasoning pane ───────────────────────────────────────────────────────

function ReasoningPane({ turn }: { turn: Turn }) {
  const meta = turn.response?.data?._meta;
  const headerMeta = turn.totalMs ? `${turn.totalMs}ms · assistant.preview` : undefined;
  return (
    <section className="mt-12">
      <PaneHeading step="03 · reasoning" title="Model in the loop" meta={headerMeta} />
      <MethodInspector turn={turn} meta={meta} />
      {turn.error ? (
        <p className="mt-4 font-mono text-[11.5px] text-[color:var(--status-error-fg)]">
          {turn.error}
        </p>
      ) : !turn.response ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">thinking…</p>
      ) : (
        <Block label="raw worker response">
          <pre className="overflow-x-auto font-mono text-[11.5px] leading-[1.55] text-studio-ink">
            {JSON.stringify(turn.response, null, 2)}
          </pre>
        </Block>
      )}
    </section>
  );
}

function MethodInspector({ turn, meta }: { turn: Turn; meta?: WorkerMeta }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="mt-4 rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)]">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="flex w-full items-center justify-between gap-3 px-4 py-2.5 text-left transition-colors hover:bg-[color:var(--studio-edge)]"
        aria-expanded={expanded}
      >
        <div className="flex items-baseline gap-3">
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            method
          </span>
          <span className="font-mono text-[12px] text-studio-ink">assistant.preview</span>
          <ImplBadge label={meta?.model ?? "llm"} />
          <span className="font-mono text-[10px] text-studio-ink-faint">
            {meta?.provider ?? "—"}
          </span>
        </div>
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-studio-ink-faint">
          {expanded ? "− collapse" : "+ unpack"}
        </span>
      </button>
      {expanded ? (
        <div className="border-t border-studio-edge p-4">
          <div className="grid gap-4 sm:grid-cols-[1fr_1fr]">
            <div className="flex flex-col gap-1.5">
              <Row label="endpoint">assistant.preview</Row>
              <Row label="impl">AssistantPreviewPlanner → handsoff-infer</Row>
              <Row label="snapshot">{turn.source.kind === "scenario" ? "override · scenario" : "live · daemon-built"}</Row>
              <Row label="dry-run">true (mock executor only)</Row>
              <Row label="provider">{meta?.provider ?? "—"}</Row>
              <Row label="model">{meta?.model ?? "—"}</Row>
              <Row label="tokens">{meta?.tokens ?? "—"}</Row>
              <Row label="worker ms">{meta?.durationMs ?? "—"}</Row>
              <Row label="round-trip">{turn.totalMs ? `${turn.totalMs}ms` : "—"}</Row>
            </div>
            <div className="flex flex-col gap-3">
              <div>
                <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                  request · sent to daemon
                </p>
                <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11px] leading-[1.55] text-studio-ink">
                  {JSON.stringify(
                    {
                      method: "assistant.preview",
                      params:
                        turn.source.kind === "scenario"
                          ? { text: turn.prompt, snapshot: `{ scenario:${turn.source.id} }`, trace: true }
                          : { text: turn.prompt, trace: true },
                    },
                    null,
                    2,
                  )}
                </pre>
              </div>
              <div>
                <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                  what the daemon does
                </p>
                <ul className="mt-2 space-y-0.5 font-mono text-[10.5px] text-studio-ink-faint">
                  <li>· {turn.source.kind === "scenario" ? "uses the snapshot override" : "builds live snapshot (windows · terminals · screens)"}</li>
                  <li>· assembles system prompt via handsoff-infer.ts</li>
                  <li>· sends to {meta?.provider ?? "provider"} · {meta?.model ?? "model"}</li>
                  <li>· returns actions + spoken to caller</li>
                  <li>· writes ~/.lattices/assistant-preview-debug.jsonl when trace is true</li>
                </ul>
              </div>
            </div>
          </div>
          <p className="mt-4 max-w-2xl text-[11.5px] leading-relaxed text-studio-ink-faint">
            The full system prompt is assembled inside the preview planner
            process and isn't currently exposed via RPC. The trace artifact on
            disk captures the snapshot, request, and raw planner response.
          </p>
        </div>
      ) : null}
    </div>
  );
}

// ── Actions pane ─────────────────────────────────────────────────────────

function ActionsPane({
  turn,
  plannedLog,
  planSource,
  sourceKind,
}: {
  turn: Turn;
  plannedLog: ExecLogEntry[] | null;
  planSource: Scenario | null;
  sourceKind: "live" | "scenario";
}) {
  const actions = turn.response?.data?.actions ?? [];
  return (
    <section className="mt-12">
      <PaneHeading
        step="04 · actions"
        title="Intents the model emitted"
        meta={`${actions.length} action${actions.length === 1 ? "" : "s"}${plannedLog ? " · plan resolved" : ""}`}
      />
      {turn.error ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">—</p>
      ) : !turn.response ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">thinking…</p>
      ) : actions.length === 0 ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">
          no actions · model treated this as informational (answer in spoken)
        </p>
      ) : (
        <ul className="mt-4 flex flex-col gap-3">
          {actions.map((a, i) => (
            <ActionCard
              key={i}
              index={i}
              action={a}
              plan={plannedLog?.[i] ?? null}
              planSource={planSource}
              sourceKind={sourceKind}
            />
          ))}
        </ul>
      )}
    </section>
  );
}

function ActionCard({
  index,
  action,
  plan,
  planSource,
  sourceKind,
}: {
  index: number;
  action: Action;
  plan: ExecLogEntry | null;
  planSource: Scenario | null;
  sourceKind: "live" | "scenario";
}) {
  const slots = (action.slots ?? {}) as Record<string, unknown>;
  const hasSlots = Object.keys(slots).length > 0;
  const status = plan ? (plan.ok ? "ready" : "skip") : "—";
  const statusColor =
    status === "ready" ? "var(--scout-accent)" :
    status === "skip" ? "var(--status-error-fg)" :
    "var(--studio-ink-faint)";

  return (
    <li className="rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-4">
      <div className="flex items-baseline justify-between gap-3 border-b border-studio-edge pb-2">
        <div className="flex items-baseline gap-3">
          <p className="font-mono text-[13px]" style={{ color: "var(--scout-accent)" }}>
            {action.intent}
          </p>
          <span
            className="font-mono text-[9.5px] uppercase tracking-[0.18em]"
            style={{ color: statusColor }}
          >
            {status}
          </span>
        </div>
        <p className="font-mono text-[10px] text-studio-ink-faint">#{index + 1}</p>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-[260px_1fr]">
        <div>
          <p className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
            slots
          </p>
          {hasSlots ? (
            <div className="mt-1.5 flex flex-col gap-1">
              {Object.entries(slots).map(([k, v]) => (
                <Row key={k} label={k}>
                  <span className="font-mono text-[12px] text-studio-ink">
                    {typeof v === "string" ? v : JSON.stringify(v)}
                  </span>
                </Row>
              ))}
            </div>
          ) : (
            <p className="mt-1.5 font-mono text-[10.5px] text-studio-ink-faint">— no slots —</p>
          )}
        </div>

        <div>
          <p className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
            what it would do
          </p>
          {!plan ? (
            <p className="mt-1.5 font-mono text-[10.5px] text-studio-ink-faint">
              {planSource
                ? "no plan computed"
                : sourceKind === "live"
                  ? "switch to a scenario or wait for the live snapshot to load to resolve targets"
                  : "no scenario selected"}
            </p>
          ) : (
            <ResolvedPlanView plan={plan} sourceKind={sourceKind} />
          )}
        </div>
      </div>
    </li>
  );
}

function ResolvedPlanView({
  plan,
  sourceKind,
}: {
  plan: ExecLogEntry;
  sourceKind: "live" | "scenario";
}) {
  const { plan: p } = plan;
  const showGeometry = sourceKind === "scenario" && p.geometryAvailable;
  return (
    <div className="mt-1.5 flex flex-col gap-2">
      <p className="font-sans text-[12.5px] leading-snug text-studio-ink">{p.summary}</p>

      {p.display ? (
        <p className="font-mono text-[10.5px] text-studio-ink-faint">
          display · <span className="text-studio-ink">{p.display.name}</span>
          {p.display.width ? ` (${p.display.width}×${p.display.height})` : ""}
          {p.position ? <> · position · <span className="text-studio-ink">{humanPosition(p.position)}</span></> : null}
        </p>
      ) : p.position ? (
        <p className="font-mono text-[10.5px] text-studio-ink-faint">
          position · <span className="text-studio-ink">{humanPosition(p.position)}</span>
        </p>
      ) : null}

      {p.targets.length ? (
        <div className="rounded-sm border border-studio-edge">
          <div className="grid grid-cols-[1fr_auto_auto] gap-2 border-b border-studio-edge px-2.5 py-1 font-mono text-[9.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
            <span>target</span>
            <span>before</span>
            <span>after</span>
          </div>
          <ul>
            {p.targets.map((t) => (
              <TargetRow key={t.wid} target={t} showGeometry={showGeometry} />
            ))}
          </ul>
        </div>
      ) : null}

      {p.warnings.length ? (
        <ul className="flex flex-col gap-0.5">
          {p.warnings.map((w, i) => (
            <li
              key={i}
              className="font-mono text-[10.5px]"
              style={{ color: "var(--status-error-fg)" }}
            >
              ⚠ {w}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function TargetRow({ target, showGeometry }: { target: ResolvedTarget; showGeometry: boolean }) {
  const moved = target.changed && target.after && (target.after.displayIndex !== target.before.displayIndex);
  return (
    <li className="grid grid-cols-[1fr_auto_auto] items-baseline gap-2 border-b border-studio-edge px-2.5 py-1.5 last:border-b-0">
      <span className="min-w-0 truncate font-sans text-[12px] text-studio-ink">
        <span className="text-studio-ink-faint">{target.app}</span>
        {target.title ? ` · ${target.title}` : ""}
        <span className="ml-1.5 font-mono text-[10px] text-studio-ink-faint">#{target.wid}</span>
      </span>
      <span className="font-mono text-[10.5px] tabular-nums text-studio-ink-faint">
        {showGeometry ? formatRect(target.before.frame) : (target.before.onScreen ? "on" : "off")}
        {moved ? <span className="ml-1">@d{target.before.displayIndex}</span> : null}
      </span>
      <span className="font-mono text-[10.5px] tabular-nums text-studio-ink">
        {target.after
          ? (showGeometry ? formatRect(target.after.frame) : (target.after.onScreen ? "on" : "off"))
          : "—"}
        {moved && target.after ? <span className="ml-1">@d{target.after.displayIndex}</span> : null}
      </span>
    </li>
  );
}

// ── Spoken pane ──────────────────────────────────────────────────────────

function SpokenPane({ turn }: { turn: Turn }) {
  const spoken = turn.response?.data?.spoken;
  return (
    <section className="mt-12">
      <PaneHeading step="05 · spoken" title="What the agent says back" />
      {turn.error ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">—</p>
      ) : !turn.response ? (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">thinking…</p>
      ) : spoken ? (
        <blockquote
          className="mt-4 border-l-2 pl-4 font-sans text-[16px] leading-relaxed text-studio-ink"
          style={{ borderColor: "var(--scout-accent)" }}
        >
          {spoken}
        </blockquote>
      ) : (
        <p className="mt-4 font-mono text-[11.5px] text-studio-ink-faint">
          — no spoken response
        </p>
      )}
    </section>
  );
}

// ── Execute pane (mock commit) ───────────────────────────────────────────

function ExecutePane({
  turn,
  world,
  simResult,
  onCommit,
  onReset,
}: {
  turn: Turn;
  world: Scenario | null;
  simResult: ExecResult | null;
  onCommit: () => void;
  onReset: () => void;
}) {
  const actions = turn.response?.data?.actions ?? [];
  const canCommit = !!world && actions.length > 0 && turn.source.kind === "scenario";
  const liveBlocked = turn.source.kind === "live";

  return (
    <section className="mt-12">
      <PaneHeading
        step="06 · execute"
        title="Commit the plan"
        meta="mock · no real windows move"
      />
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <button
          type="button"
          onClick={onCommit}
          disabled={!canCommit}
          className={[
            "rounded-sm border px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.18em] transition-colors",
            canCommit
              ? "border-[color:var(--scout-accent)] text-[color:var(--scout-accent)] hover:bg-[color:var(--studio-edge)]"
              : "border-studio-edge text-studio-ink-faint",
          ].join(" ")}
        >
          commit plan to world
        </button>
        {world ? (
          <button
            type="button"
            onClick={onReset}
            className="rounded-sm border border-studio-edge px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.18em] text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink"
          >
            reset scenario ↺
          </button>
        ) : null}
        <p className="font-mono text-[10.5px] text-studio-ink-faint">
          {liveBlocked
            ? "pick a scenario to commit (live mode never executes)"
            : actions.length === 0
              ? "no actions · informational turn"
              : `committing applies the plan above to this scenario's state — next turn reasons about the updated world`}
        </p>
      </div>

      {simResult ? (
        <p className="mt-3 font-mono text-[10.5px] text-studio-ink-faint">
          committed · {simResult.log.filter((e) => e.ok).length}/{simResult.log.length} action
          {simResult.log.length === 1 ? "" : "s"} applied. Snapshot above reflects the post-commit world.
          Hit <span className="text-studio-ink">reset scenario</span> to start over.
        </p>
      ) : null}
    </section>
  );
}

// ── Layout primitives ────────────────────────────────────────────────────

function PaneHeading({
  step,
  title,
  meta,
}: {
  step: string;
  title: string;
  meta?: string;
}) {
  return (
    <div className="flex items-baseline justify-between border-b border-studio-edge pb-2">
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          {step}
        </span>
        <h3 className="font-mono text-[13px] text-studio-ink">{title}</h3>
      </div>
      {meta ? (
        <span className="font-mono text-[10px] text-studio-ink-faint tabular-nums">
          {meta}
        </span>
      ) : null}
    </div>
  );
}

function Block({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-4">
      <p className="mb-2 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {label}
      </p>
      {children}
    </div>
  );
}

function ScrollList({ children }: { children: React.ReactNode }) {
  return <ul className="max-h-[300px] overflow-y-auto pr-1">{children}</ul>;
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-studio-edge py-1 last:border-b-0">
      <span className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {label}
      </span>
      <span className="min-w-0 text-right font-mono text-[11.5px] text-studio-ink">
        {children}
      </span>
    </div>
  );
}

function ImplBadge({ label }: { label: string }) {
  return (
    <span
      className="rounded-[3px] border px-1.5 py-0.5 font-mono text-[9px] font-semibold uppercase tracking-[0.18em]"
      style={{ color: "var(--scout-accent)", borderColor: "var(--scout-accent)" }}
    >
      {label}
    </span>
  );
}
