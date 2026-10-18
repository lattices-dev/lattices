"use client";

/**
 * Linux Command Center — three directions for Lattices on Omarchy/Hyprland.
 *
 * A  Mission Control   — the whole host at once: every space, every window,
 *                        sessions and layers, readable as an inventory.
 * B  Flight Deck       — one space, drawn to scale. Keyboard first: a command
 *                        line on top, a spatial map, a space horizon below.
 * C  Operator Console  — the CLI is the product. A transcript for sessions and
 *                        layers, a status line, and a small hints rail.
 *
 * All three share one local simulation (./linux-command-center/sim.ts). No
 * daemon is contacted and no real window moves.
 */

import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode, type RefObject } from "react";
import type { LatticesPage } from "@/studio/studioRegistry";
import {
  COMMANDS,
  HINTS,
  HOST,
  SESSIONS,
  SPACES,
  WINDOWS,
  cycle,
  dwindle,
  focusWid,
  gotoSpace,
  initialState,
  layersOn,
  moveFocus,
  parkedOn,
  run,
  search,
  setLayer,
  swap,
  visibleOn,
  winById,
  type Dir,
  type Line,
  type LogEntry,
  type SimState,
} from "@/studio/studies/linux-command-center/sim";

type DirectionKey = "mission" | "flight" | "operator";

const DIRECTIONS: { key: DirectionKey; letter: string; name: string; gist: string }[] = [
  { key: "mission", letter: "A", name: "Mission Control", gist: "Inventory of every space, window, session and layer" },
  { key: "flight", letter: "B", name: "Flight Deck", gist: "One space to scale, driven from the keyboard" },
  { key: "operator", letter: "C", name: "Operator Console", gist: "CLI transcript for sessions and layers, hints at hand" },
];

type Ctx = {
  s: SimState;
  set: (fn: (s: SimState) => SimState) => void;
  inputRef: RefObject<HTMLInputElement | null>;
  hints: boolean;
  setHints: (v: boolean) => void;
};

// ── shared atoms ──────────────────────────────────────────────────────────

/** The Lattices mark: 3×3, left column + bottom row lit. */
function Mark({ size = 14 }: { size?: number }) {
  const lit = [0, 3, 6, 7, 8];
  const cell = size / 3.4;
  const gap = (size - cell * 3) / 2;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden className="lcc-mark">
      {Array.from({ length: 9 }, (_, i) => (
        <rect
          key={i}
          x={(i % 3) * (cell + gap)}
          y={Math.floor(i / 3) * (cell + gap)}
          width={cell}
          height={cell}
          rx={cell * 0.12}
          fill={lit.includes(i) ? "var(--lcc-ink)" : "var(--lcc-mark-dim)"}
        />
      ))}
    </svg>
  );
}

function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="lcc-kbd">{children}</kbd>;
}

function Avail({ status }: { status: "archie" | "concept" }) {
  return <span className={`lcc-avail lcc-avail--${status}`}>{status === "archie" ? "on archie" : "concept"}</span>;
}

function SpaceMap({
  s,
  space,
  size = "lg",
  onPick,
}: {
  s: SimState;
  space: number;
  size?: "sm" | "lg";
  onPick?: (wid: string) => void;
}) {
  const wins = visibleOn(s, space);
  const rects = dwindle(wins.length);
  const focused = s.focus[space];
  return (
    <div className={`lcc-map lcc-map--${size}`}>
      {wins.length === 0 ? <div className="lcc-map__empty">empty</div> : null}
      {wins.map((w, i) => {
        const r = rects[i];
        const isFocus = w.wid === focused && space === s.space;
        return (
          <button
            type="button"
            key={w.wid}
            tabIndex={size === "sm" ? -1 : 0}
            className={`lcc-tile ${isFocus ? "is-focus" : ""}`}
            style={{ left: `${r.x * 100}%`, top: `${r.y * 100}%`, width: `${r.w * 100}%`, height: `${r.h * 100}%` }}
            onClick={onPick ? () => onPick(w.wid) : undefined}
            aria-label={`${w.app} ${w.title}`}
          >
            <span className="lcc-tile__inner">
              {size === "lg" ? (
                <>
                  <span className="lcc-tile__head">
                    <span className="lcc-tile__app">{w.app}</span>
                    <span className="lcc-tile__wid">{w.wid}</span>
                  </span>
                  <span className="lcc-tile__title">{w.title}</span>
                  {w.session ? <span className="lcc-tile__meta">tmux {w.session}</span> : null}
                </>
              ) : null}
            </span>
          </button>
        );
      })}
    </div>
  );
}

function HintsSheet({ onClose }: { onClose: () => void }) {
  return (
    <div className="lcc-sheet" role="dialog" aria-label="Hints">
      <div className="lcc-sheet__head">
        <span className="lcc-label">Hints</span>
        <span className="lcc-dim">lats hints · same pack as the app</span>
        <button type="button" className="lcc-btn lcc-btn--ghost" onClick={onClose}>
          Close <Kbd>Esc</Kbd>
        </button>
      </div>
      <HintList />
    </div>
  );
}

function HintList({ compact = false }: { compact?: boolean }) {
  return (
    <ul className={`lcc-hints ${compact ? "lcc-hints--compact" : ""}`}>
      {HINTS.map((h) => (
        <li key={h.keys}>
          <span className="lcc-hints__keys">{h.keys}</span>
          <span className="lcc-hints__does">{h.does}</span>
          <span className="lcc-hints__owner">{h.owner}</span>
          {h.sim && !compact ? <span className="lcc-hints__sim">{h.sim}</span> : null}
        </li>
      ))}
    </ul>
  );
}

function toneClass(tone?: string) {
  return tone ? `lcc-t--${tone}` : "";
}

// ── A · Mission Control ──────────────────────────────────────────────────

function MissionControl({ s, set, inputRef, hints, setHints }: Ctx) {
  const [filter, setFilter] = useState("");
  const rows = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return WINDOWS;
    return WINDOWS.filter((w) =>
      [w.wid, w.app, w.title, w.session ?? "", w.layer ?? "", `space ${w.space}`].some((v) => v.toLowerCase().includes(q)),
    );
  }, [filter]);
  const attached = SESSIONS.filter((x) => x.attached).length;
  const layers = layersOn(s.space);

  return (
    <div className="lcc-mc">
      <dl className="lcc-telemetry">
        {[
          ["Host", HOST.name],
          ["Compositor", HOST.compositor],
          ["Host API", `:${HOST.port}`],
          ["Spaces", String(SPACES.length)],
          ["Windows", String(WINDOWS.length)],
          ["Sessions", `${SESSIONS.length} · ${attached} attached`],
          ["Layers", String(new Set(WINDOWS.map((w) => w.layer).filter(Boolean)).size)],
          ["Paired", HOST.pairedWith],
        ].map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>

      <section className="lcc-mc__spaces" aria-label="Spaces">
        {SPACES.map((sp) => {
          const n = s.order[sp].length;
          const current = sp === s.space;
          return (
            <button
              type="button"
              key={sp}
              className={`lcc-space ${current ? "is-current" : ""}`}
              onClick={() => set((x) => focusSpace(x, sp))}
            >
              <span className="lcc-space__head">
                <span className="lcc-space__num">{String(sp).padStart(2, "0")}</span>
                <span className="lcc-space__state">
                  {current ? "current" : sp === s.previous ? "previous" : n === 0 ? "empty" : ""}
                </span>
              </span>
              <SpaceMap s={s} space={sp} size="sm" />
              <span className="lcc-space__foot">
                <span>
                  {n} win{n === 1 ? "" : "s"}
                </span>
                <span>{s.layer[sp] ? `layer ${s.layer[sp]}` : layersOn(sp).length ? "all" : "—"}</span>
              </span>
            </button>
          );
        })}
      </section>

      <div className="lcc-mc__body">
        <section className="lcc-panel lcc-mc__table">
          <header className="lcc-panel__head">
            <span className="lcc-label">Windows</span>
            <label className="lcc-filter">
              <span className="lcc-dim">Filter</span>
              <input
                ref={inputRef}
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="app, title, session, layer"
                spellCheck={false}
              />
              <Kbd>Ctrl K</Kbd>
            </label>
            <span className="lcc-dim lcc-num">
              {rows.length}/{WINDOWS.length}
            </span>
          </header>
          <div className="lcc-table" role="table">
            <div className="lcc-table__row lcc-table__row--head" role="row">
              <span>WID</span>
              <span>SP</span>
              <span>APP</span>
              <span>TITLE</span>
              <span>LAYER</span>
              <span>TMUX</span>
            </div>
            {rows.map((w) => {
              const focused = s.focus[w.space] === w.wid && w.space === s.space;
              const parked = parkedOn(s, w.space).some((p) => p.wid === w.wid);
              return (
                <button
                  type="button"
                  role="row"
                  key={w.wid}
                  className={`lcc-table__row ${focused ? "is-focus" : ""} ${parked ? "is-parked" : ""}`}
                  onClick={() => set((x) => focusWid(x, w.wid, "click", "sim"))}
                >
                  <span className="lcc-num">{w.wid}</span>
                  <span className="lcc-num">{w.space}</span>
                  <span>{w.app}</span>
                  <span className="lcc-ellipsis">{w.title}</span>
                  <span>{w.layer ?? "—"}</span>
                  <span className="lcc-ellipsis">{w.session ?? "—"}</span>
                </button>
              );
            })}
            {rows.length === 0 ? <div className="lcc-empty">No windows match. Search covers title, app and session.</div> : null}
          </div>
        </section>

        <aside className="lcc-mc__side">
          <section className="lcc-panel">
            <header className="lcc-panel__head">
              <span className="lcc-label">Layers · space {s.space}</span>
            </header>
            <div className="lcc-layerlist">
              {layers.length === 0 ? <div className="lcc-empty">No layers on this space.</div> : null}
              {layers.map((l) => (
                <button
                  type="button"
                  key={l}
                  className={`lcc-layerrow ${s.layer[s.space] === l ? "is-on" : ""}`}
                  onClick={() => set((x) => setLayer(x, x.layer[x.space] === l ? null : l, "click", "sim"))}
                >
                  <span>{l}</span>
                  <span className="lcc-num lcc-dim">{WINDOWS.filter((w) => w.space === s.space && w.layer === l).length} win</span>
                  <span className="lcc-layerrow__state">{s.layer[s.space] === l ? "raised" : "parked"}</span>
                </button>
              ))}
            </div>
          </section>
          <section className="lcc-panel">
            <header className="lcc-panel__head">
              <span className="lcc-label">tmux</span>
            </header>
            {SESSIONS.map((x) => (
              <div key={x.name} className="lcc-kv">
                <span className={x.attached ? "lcc-t--strong" : ""}>{x.name}</span>
                <span className="lcc-dim">{x.attached ? "attached" : "detached"}</span>
              </div>
            ))}
          </section>
          <section className="lcc-panel lcc-panel--grow">
            <header className="lcc-panel__head">
              <span className="lcc-label">Event log</span>
              <span className="lcc-dim">simulated</span>
            </header>
            <EventLog log={s.log} limit={6} />
          </section>
        </aside>
      </div>
      {hints ? <HintsSheet onClose={() => setHints(false)} /> : null}
    </div>
  );
}

function EventLog({ log, limit }: { log: LogEntry[]; limit: number }) {
  return (
    <ol className="lcc-log">
      {log.slice(0, limit).map((e) => (
        <li key={e.seq}>
          <span className="lcc-num lcc-dim">{String(e.seq).padStart(3, "0")}</span>
          <span className={`lcc-log__tone lcc-log__tone--${e.tone}`}>{e.tone}</span>
          <span className="lcc-ellipsis">{e.text}</span>
        </li>
      ))}
    </ol>
  );
}

// ── B · Flight Deck ──────────────────────────────────────────────────────

function FlightDeck({ s, set, inputRef, hints, setHints }: Ctx) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const [result, setResult] = useState<{ status: string; lines: Line[]; input: string } | null>(null);
  const focused = winById(s.focus[s.space] ?? "");
  const parked = parkedOn(s, s.space);
  const layers = layersOn(s.space);

  const suggestions = useMemo(() => {
    const t = q.trim();
    if (!t) return [] as { label: string; detail: string; run: string; status: "archie" | "concept" }[];
    const hits = search(t.replace(/^lats\s+/, "")).slice(0, 4).map((h) => ({
      label: `${h.win.app} — ${h.win.title}`,
      detail: `${h.win.wid} · space ${h.win.space}`,
      run: `lats focus ${h.win.title.split(" ")[0]}`,
      status: "archie" as const,
    }));
    const cmds = COMMANDS.filter((c) => c.usage.includes(t.replace(/^lats\s*/, "").split(" ")[0]))
      .slice(0, 3)
      .map((c) => ({ label: c.usage, detail: c.note, run: c.usage.split(" <")[0].split("|")[0].split(" [")[0].split(" · ")[0], status: c.status }));
    return [...hits, ...cmds];
  }, [q]);

  const exec = (text: string) => {
    const o = run(text, s);
    set(() => o.next);
    setResult({ status: o.status, lines: o.lines, input: o.input });
    setQ("");
    setSel(0);
  };

  return (
    <div className="lcc-fd">
      <div className="lcc-fd__cmd">
        <span className="lcc-fd__prompt">›</span>
        <input
          ref={inputRef}
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setSel(0);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setSel((i) => Math.min(i + 1, Math.max(suggestions.length - 1, 0)));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setSel((i) => Math.max(i - 1, 0));
            } else if (e.key === "Enter") {
              e.preventDefault();
              const pick = suggestions[sel];
              const direct = /^(lats\s+)?(space|spaces|window|layer|layers|search|focus|place|sessions|hints|app|doctor|help)\b/.test(q.trim());
              exec(direct || !pick ? q : pick.run);
            } else if (e.key === "Escape") {
              setQ("");
              (e.target as HTMLInputElement).blur();
            }
          }}
          placeholder="Search windows or type a command — space next, layer docs, focus btop"
          spellCheck={false}
          aria-label="Command"
        />
        <Kbd>Ctrl K</Kbd>
        {suggestions.length ? (
          <ul className="lcc-suggest">
            {suggestions.map((x, i) => (
              <li key={x.label + i}>
                <button
                  type="button"
                  className={i === sel ? "is-sel" : ""}
                  onMouseEnter={() => setSel(i)}
                  onClick={() => exec(x.run)}
                >
                  <span className="lcc-ellipsis">{x.label}</span>
                  <span className="lcc-dim lcc-ellipsis">{x.detail}</span>
                  <Avail status={x.status} />
                </button>
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      <div className="lcc-fd__main">
        <section className="lcc-fd__stage">
          <header className="lcc-fd__stagehead">
            <span className="lcc-fd__spacenum">Space {String(s.space).padStart(2, "0")}</span>
            <span className="lcc-dim">Hyprland workspace</span>
            <span className="lcc-fd__layers">
              <span className="lcc-dim">Layer</span>
              {layers.length === 0 ? <span className="lcc-dim">none</span> : null}
              {layers.map((l) => (
                <button
                  type="button"
                  key={l}
                  className={`lcc-seg ${s.layer[s.space] === l ? "is-on" : ""}`}
                  onClick={() => set((x) => setLayer(x, l, "click", "sim"))}
                >
                  {l}
                </button>
              ))}
              {layers.length ? (
                <button
                  type="button"
                  className={`lcc-seg ${!s.layer[s.space] ? "is-on" : ""}`}
                  onClick={() => set((x) => setLayer(x, null, "click", "sim"))}
                >
                  all
                </button>
              ) : null}
            </span>
          </header>
          <SpaceMap s={s} space={s.space} onPick={(wid) => set((x) => focusWid(x, wid, "click", "sim"))} />
          <footer className="lcc-fd__parked">
            {parked.length ? (
              <>
                <span className="lcc-dim">Parked behind layer</span>
                {parked.map((w) => (
                  <button type="button" key={w.wid} className="lcc-chip" onClick={() => set((x) => focusWid(x, w.wid, "click", "sim"))}>
                    {w.app} · {w.layer ?? "no layer"}
                  </button>
                ))}
              </>
            ) : (
              <span className="lcc-dim">Nothing parked on this space</span>
            )}
          </footer>
        </section>

        <aside className="lcc-fd__target">
          <span className="lcc-label">Target</span>
          {focused ? (
            <>
              <div className="lcc-fd__targetapp">{focused.app}</div>
              <div className="lcc-fd__targettitle">{focused.title}</div>
              <dl className="lcc-readout">
                <div>
                  <dt>Window</dt>
                  <dd className="lcc-num">{focused.wid}</dd>
                </div>
                <div>
                  <dt>Space</dt>
                  <dd className="lcc-num">{focused.space}</dd>
                </div>
                <div>
                  <dt>Layer</dt>
                  <dd>{focused.layer ?? "—"}</dd>
                </div>
                <div>
                  <dt>tmux</dt>
                  <dd>{focused.session ?? "—"}</dd>
                </div>
              </dl>
              <div className="lcc-fd__equiv">
                <span className="lcc-label">Same move from a shell</span>
                <code>lats window focus {focused.wid}</code>
                <Avail status="concept" />
              </div>
            </>
          ) : (
            <div className="lcc-empty">No window focused on this space.</div>
          )}
          {result ? (
            <div className="lcc-fd__result">
              <span className="lcc-label">
                Last command <Avail status={result.status === "concept" ? "concept" : "archie"} />
              </span>
              <code className="lcc-dim">{result.input}</code>
              {result.lines.slice(0, 4).map((l, i) => (
                <div key={i} className={`lcc-fd__resultline ${toneClass(l.tone)}`}>
                  {l.text}
                </div>
              ))}
            </div>
          ) : null}
          <div className="lcc-fd__keys">
            <span>
              <Kbd>←↑↓→</Kbd> focus
            </span>
            <span>
              <Kbd>⇧</Kbd>+<Kbd>←→</Kbd> swap
            </span>
            <span>
              <Kbd>[</Kbd>
              <Kbd>]</Kbd> space
            </span>
            <span>
              <Kbd>?</Kbd> hints
            </span>
          </div>
        </aside>
      </div>

      <nav className="lcc-horizon" aria-label="Spaces">
        <button type="button" className="lcc-horizon__step" onClick={() => set((x) => cycle(x, -1, "Ctrl+←", "sim"))}>
          ← prev
        </button>
        <div className="lcc-horizon__track">
          {SPACES.map((sp) => (
            <button
              type="button"
              key={sp}
              className={`lcc-horizon__tick ${sp === s.space ? "is-current" : ""} ${sp === s.previous ? "is-prev" : ""}`}
              onClick={() => set((x) => focusSpace(x, sp))}
            >
              <span className="lcc-horizon__num">{sp}</span>
              <span className="lcc-horizon__count">{s.order[sp].length || "—"}</span>
            </button>
          ))}
        </div>
        <button type="button" className="lcc-horizon__step" onClick={() => set((x) => cycle(x, 1, "Ctrl+→", "sim"))}>
          next →
        </button>
      </nav>
      {hints ? <HintsSheet onClose={() => setHints(false)} /> : null}
    </div>
  );
}

function focusSpace(s: SimState, sp: number): SimState {
  return sp === s.space ? s : gotoSpace(s, sp, "click", "sim");
}

// ── C · Operator Console ─────────────────────────────────────────────────

type Entry = { id: number; input: string; status: string; lines: Line[] };

const SCRIPT = ["lats sessions", "lats layers", "lats layer docs", "lats space next", "lats doctor"];

function OperatorConsole({ s, set, inputRef, hints, setHints }: Ctx) {
  const [entries, setEntries] = useState<Entry[]>(() => {
    const first = run("lats sessions", initialState());
    return [{ id: 1, input: first.input, status: first.status, lines: first.lines }];
  });
  const [line, setLine] = useState("");
  const [hist, setHist] = useState(-1);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [entries]);

  const exec = (text: string) => {
    if (text.trim() === "clear") {
      setEntries([]);
      setLine("");
      return;
    }
    const o = run(text, s);
    set(() => o.next);
    setEntries((e) => [...e, { id: (e.at(-1)?.id ?? 0) + 1, input: o.input, status: o.status, lines: o.lines }].slice(-30));
    setLine("");
    setHist(-1);
  };

  const nextScript = SCRIPT.find((c) => !entries.some((e) => e.input === c)) ?? "lats hints";
  const focused = winById(s.focus[s.space] ?? "");
  const attached = SESSIONS.find((x) => x.attached);

  return (
    <div className={`lcc-oc ${hints ? "" : "is-railclosed"}`}>
      <section className="lcc-oc__term">
        <header className="lcc-oc__state">
          <div>
            <dt>Session</dt>
            <dd>{attached?.name}</dd>
          </div>
          <div>
            <dt>Space</dt>
            <dd className="lcc-num">{s.space}</dd>
          </div>
          <div>
            <dt>Layer</dt>
            <dd className={s.layer[s.space] ? "lcc-t--cyan" : ""}>{s.layer[s.space] ?? "all"}</dd>
          </div>
          <div>
            <dt>Focus</dt>
            <dd className="lcc-ellipsis">{focused ? `${focused.wid} ${focused.app}` : "—"}</dd>
          </div>
        </header>
        <div className="lcc-oc__scroll" ref={scrollRef}>
          {entries.map((e) => (
            <div key={e.id} className="lcc-oc__entry">
              <div className="lcc-oc__in">
                <span className="lcc-oc__ps">arach@archie ~/dev/tideline</span>
                <span className="lcc-oc__dollar">$</span>
                <span>{e.input}</span>
                {e.status === "archie" || e.status === "concept" ? <Avail status={e.status} /> : null}
              </div>
              {e.lines.map((l, i) => (
                <pre key={i} className={`lcc-oc__out ${toneClass(l.tone)}`}>
                  {l.text}
                </pre>
              ))}
            </div>
          ))}
          <div className="lcc-oc__in lcc-oc__in--live">
            <span className="lcc-oc__ps">arach@archie ~/dev/tideline</span>
            <span className="lcc-oc__dollar">$</span>
            <input
              ref={inputRef}
              value={line}
              onChange={(e) => setLine(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  exec(line);
                } else if (e.key === "Tab") {
                  e.preventDefault();
                  setLine(line ? (COMMANDS.map((c) => c.usage.split(" <")[0].split(" [")[0].split("|")[0].split(" · ")[0]).find((u) => u.startsWith(line)) ?? line) : nextScript);
                } else if (e.key === "ArrowUp") {
                  e.preventDefault();
                  const inputs = entries.map((x) => x.input);
                  const i = hist < 0 ? inputs.length - 1 : Math.max(hist - 1, 0);
                  if (inputs[i]) {
                    setHist(i);
                    setLine(inputs[i]);
                  }
                }
              }}
              placeholder={`${nextScript}   (Tab fills, Enter runs)`}
              spellCheck={false}
              aria-label="Shell input"
            />
          </div>
        </div>
        <div className="lcc-oc__next">
          <span className="lcc-dim">Next in the walkthrough</span>
          {SCRIPT.map((c) => (
            <button
              type="button"
              key={c}
              className={`lcc-chip ${entries.some((e) => e.input === c) ? "is-done" : ""}`}
              onClick={() => exec(c)}
            >
              {c}
            </button>
          ))}
        </div>
        <footer className="lcc-oc__status">
          <span className="lcc-oc__statusseg lcc-oc__statusseg--lead">
            <Mark size={10} /> {attached?.name}
          </span>
          <span className="lcc-oc__statusseg">space {s.space}</span>
          <span className="lcc-oc__statusseg">layer {s.layer[s.space] ?? "all"}</span>
          <span className="lcc-oc__statusseg lcc-oc__statusseg--end">
            {HOST.name}:{HOST.port}
          </span>
        </footer>
      </section>

      <aside className="lcc-oc__rail" aria-label="Hints rail">
        <header>
          <span className="lcc-label">Hints</span>
          <button type="button" className="lcc-btn lcc-btn--ghost" onClick={() => setHints(!hints)}>
            {hints ? "Hide" : "Show"} <Kbd>F1</Kbd>
          </button>
        </header>
        {hints ? (
          <>
            <HintList compact />
            <div className="lcc-oc__railsec">
              <span className="lcc-label">Commands</span>
              <ul className="lcc-oc__cmds">
                {COMMANDS.map((c) => (
                  <li key={c.usage}>
                    <code>{c.usage}</code>
                    <Avail status={c.status} />
                  </li>
                ))}
              </ul>
            </div>
          </>
        ) : null}
      </aside>
    </div>
  );
}

// ── page ─────────────────────────────────────────────────────────────────

const NOTES: { key: DirectionKey; composition: string; workflow: string; strength: string; risk: string }[] = [
  {
    key: "mission",
    composition: "Telemetry strip, five space cards, a window table with layers, tmux and an event log beside it.",
    workflow: "Look first. Click a row to focus it; filter with Ctrl+K.",
    strength: "Answers \"what is on this machine\" in one screen. It also makes a good lats doctor page.",
    risk: "It is dense. Every focus move costs a pointer trip, and the space cards are too small to aim at.",
  },
  {
    key: "flight",
    composition: "Command line on top, one space drawn to scale, a target readout on the right, a space horizon below.",
    workflow: "Keyboard first: arrows walk the tiles, [ ] change space, Ctrl+K searches or runs a command.",
    strength: "Spatial and calm. The map shows what Super+arrows will reach next, and layers read as a state of this space.",
    risk: "It shows one space at a time, so a window you can't place is still hard to find without search.",
  },
  {
    key: "operator",
    composition: "Shell transcript with live state above, a tmux-style status line, and a narrow hints rail.",
    workflow: "Type lats commands. Tab fills the next step; the rail shows the same pack as lats hints.",
    strength: "Every action can be copied into a script. It suits people who live in tmux, and concepts are labelled inline.",
    risk: "There is no picture of the desktop. Layer and space changes only show up as text.",
  },
];

const RUBRIC: { k: string; mission: string; flight: string; operator: string }[] = [
  { k: "Hierarchy", mission: "Fair — five regions compete", flight: "Strong — one map, one target", operator: "Good — transcript leads" },
  { k: "Legibility", mission: "Good at 1440, tight below", flight: "Strong", operator: "Strong — monospace throughout" },
  { k: "Restraint", mission: "Fair", flight: "Strong", operator: "Strong" },
  { k: "Identity", mission: "Good", flight: "Strong — the map reads like the lattice mark", operator: "Fair — could be any shell" },
  { k: "Truthful states", mission: "Strong — parked, empty, sim log", flight: "Good", operator: "Strong — concept tags per line" },
  { k: "Usability", mission: "Pointer-bound", flight: "Strong for keyboard users", operator: "Strong for CLI users" },
];

export function LinuxCommandCenterStudy({ page }: { page: LatticesPage }) {
  const [dir, setDir] = useState<DirectionKey>("flight");
  const [s, setS] = useState<SimState>(initialState);
  const [hints, setHints] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const set = useCallback((fn: (x: SimState) => SimState) => setS(fn), []);

  // Hints rail is open by default in the console, closed elsewhere.
  useEffect(() => setHints(dir === "operator"), [dir]);

  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const inInput = (e.target as HTMLElement).tagName === "INPUT";
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      inputRef.current?.focus();
      return;
    }
    if (e.key === "F1" || (e.ctrlKey && e.key === "5")) {
      e.preventDefault();
      setHints(!hints);
      return;
    }
    if (e.key === "Escape" && hints && dir !== "operator") {
      setHints(false);
      return;
    }
    if (inInput) return;
    if (e.key === "?") return setHints(!hints);
    if (e.key === "/") {
      e.preventDefault();
      inputRef.current?.focus();
      return;
    }
    if (e.key === "[" || (e.ctrlKey && e.key === "ArrowLeft")) {
      e.preventDefault();
      return set((x) => cycle(x, -1, "Ctrl+←", "sim"));
    }
    if (e.key === "]" || (e.ctrlKey && e.key === "ArrowRight")) {
      e.preventDefault();
      return set((x) => cycle(x, 1, "Ctrl+→", "sim"));
    }
    const arrows: Record<string, Dir> = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };
    const d = arrows[e.key];
    if (d) {
      e.preventDefault();
      set((x) => (e.shiftKey ? swap(x, d) : moveFocus(x, d)));
    }
  };

  const ctx: Ctx = { s, set, inputRef, hints, setHints };
  const active = DIRECTIONS.find((d) => d.key === dir)!;

  return (
    <main className="w-full px-6 py-10 lg:px-7">
      <header className="max-w-[980px] border-b border-studio-rule pb-7">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">
          {page.bucket} / linux · omarchy
        </div>
        <h1 className="mt-4 text-[36px] font-medium leading-tight text-studio-ink-strong">{page.label}</h1>
        {page.blurb ? <p className="mt-4 max-w-[66ch] text-[15px] leading-[1.7] text-studio-ink">{page.blurb}</p> : null}
      </header>

      <div className="lcc">
        <div className="lcc-switch" role="tablist" aria-label="Direction">
          {DIRECTIONS.map((d) => (
            <button
              type="button"
              role="tab"
              aria-selected={d.key === dir}
              key={d.key}
              className={`lcc-switch__tab ${d.key === dir ? "is-on" : ""}`}
              onClick={() => setDir(d.key)}
            >
              <span className="lcc-switch__letter">{d.letter}</span>
              <span className="lcc-switch__name">{d.name}</span>
              <span className="lcc-switch__gist">{d.gist}</span>
            </button>
          ))}
        </div>

        <div className="lcc-stage" tabIndex={-1} onKeyDown={onKey} data-direction={dir}>
          <div className="lcc-bar">
            <span className="lcc-bar__brand">
              <Mark size={13} />
              <span>Lattices</span>
              <span className="lcc-dim">/ {active.name}</span>
            </span>
            <span className="lcc-bar__host">
              {HOST.name} · {HOST.compositor} · {HOST.shell}
            </span>
            <span className="lcc-bar__study">
              <span className="lcc-bar__dot" />
              Study · local simulation · your desktop is not touched
            </span>
            <button
              type="button"
              className="lcc-btn lcc-btn--ghost"
              onClick={() => {
                setS(initialState());
              }}
            >
              Reset
            </button>
          </div>
          <div className="lcc-body">
            {dir === "mission" ? <MissionControl {...ctx} /> : null}
            {dir === "flight" ? <FlightDeck {...ctx} /> : null}
            {dir === "operator" ? <OperatorConsole {...ctx} /> : null}
          </div>
        </div>

        <p className="lcc-footnote">
          Spaces are Hyprland workspaces. Layers are named window groups that act inside the current space: members are raised and tiled, the
          rest are parked behind. A layer never changes the workspace. Commands tagged <Avail status="concept" /> are being built on archie and
          are not confirmed yet. Search on Linux covers title, app and session; deep terminal and OCR search are macOS-only.
        </p>

        <section className="lcc-notes" aria-label="Comparison">
          {NOTES.map((n) => {
            const d = DIRECTIONS.find((x) => x.key === n.key)!;
            return (
              <article key={n.key} className={`lcc-note ${n.key === dir ? "is-on" : ""}`}>
                <button type="button" className="lcc-note__head" onClick={() => setDir(n.key)}>
                  <span className="lcc-switch__letter">{d.letter}</span>
                  {d.name}
                </button>
                <dl>
                  <dt>Composition</dt>
                  <dd>{n.composition}</dd>
                  <dt>Workflow</dt>
                  <dd>{n.workflow}</dd>
                  <dt>Holds up</dt>
                  <dd>{n.strength}</dd>
                  <dt>Watch</dt>
                  <dd>{n.risk}</dd>
                </dl>
              </article>
            );
          })}
        </section>

        <section className="lcc-rubric" aria-label="Rubric">
          <div className="lcc-rubric__row lcc-rubric__row--head">
            <span>Rubric</span>
            <span>A Mission Control</span>
            <span>B Flight Deck</span>
            <span>C Operator Console</span>
          </div>
          {RUBRIC.map((r) => (
            <div key={r.k} className="lcc-rubric__row">
              <span>{r.k}</span>
              <span>{r.mission}</span>
              <span>{r.flight}</span>
              <span>{r.operator}</span>
            </div>
          ))}
        </section>

        <section className="lcc-reco">
          <span className="lcc-label">Recommendation</span>
          <p>
            Build <strong>B Flight Deck</strong> as the Quickshell Overview page. Keep C's transcript vocabulary as the contract: every move on the
            deck should map to a lats command, and the hints rail and lats hints should share one pack. Use A's inventory as the body of{" "}
            <code>lats doctor</code> and the Activity page, not as the main view.
          </p>
        </section>
      </div>
    </main>
  );
}
