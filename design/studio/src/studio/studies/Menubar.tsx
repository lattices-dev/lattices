"use client";

import { useState, type ReactNode } from "react";
import { Icon, type IconName } from "./shell/_shell";
import { BI, type BIconName } from "./shell-b/_b";
import type { LatticesPage } from "@/studio/studioRegistry";

/* ============================================================
   Menubar popover — three passes at the MainView dropdown.

   The current popover runs two nav systems over the same destinations
   (a 7-icon header row + a labelled Quick Actions list) and gives every
   row a subtitle and hotkey tokens forever. Each pass below picks a
   different answer to "what is the popover for":

     A  Filter-first   — the popover is a small command bar
     B  Status-first   — where am I before what can I do
     C  Mini-Home      — the popover is a small Home window

   All three are drawn at true popover scale (~372pt) next to a muted
   rendering of today's layout. Chrome lives in `.mb-*` in
   app/studies/menubar.css; icons are shared with the shell passes.
   ============================================================ */

/* ── Icons this study needs that neither pass has ─────────── */

type ExtraIcon = "quit" | "move" | "arrowRight";
type MIconName = IconName | BIconName | ExtraIcon;

const EXTRA: Record<ExtraIcon, ReactNode> = {
  quit: (
    <>
      <path d="M12 3v8" />
      <path d="M6.3 6.3a8 8 0 1 0 11.4 0" />
    </>
  ),
  move: (
    <>
      <path d="M12 3v18M3 12h18" />
      <path d="m8 6 4-3 4 3M8 18l4 3 4-3M6 8l-3 4 3 4M18 8l3 4-3 4" />
    </>
  ),
  arrowRight: <path d="M4 12h14M13 6l6 6-6 6" />,
};

function MI({ name, className = "mb-icon" }: { name: MIconName; className?: string }) {
  if (name in EXTRA) {
    return (
      <svg
        className={className}
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        {EXTRA[name as ExtraIcon]}
      </svg>
    );
  }
  if (name === "mic" || name === "list" || name === "display" || name === "enter" || name === "more" || name === "layers" || name === "maximize" || name === "close") {
    return <BI name={name as BIconName} className={className} />;
  }
  return <Icon name={name as IconName} className={className} />;
}

/* ── Shared data ───────────────────────────────────────────── */

const SESSION = { name: "lattices-dev", path: "~/dev/lattices", panes: 4, windows: 7 };
const FRONT = { app: "Ghostty", title: "lattices — bun bin/lattices.ts search vox --deep" };

interface Action {
  id: string;
  label: string;
  sub: string;
  icon: MIconName;
  keys: string;
}

const ACTIONS: Action[] = [
  { id: "assistant", label: "Assistant", sub: "AI chat for settings, planning, and workspace help", icon: "assistant", keys: "⌃⌥A" },
  { id: "home", label: "Home", sub: "Workspace overview and project launcher", icon: "home", keys: "Hyp 1" },
  { id: "studio", label: "Studio", sub: "Arrange windows and layers", icon: "studio", keys: "Hyp L" },
  { id: "command", label: "Command Bar", sub: "Browse, search, and run slash commands", icon: "command", keys: "⌃⌥␣" },
];

const HEADER_ICONS: MIconName[] = ["home", "layers", "studio", "search", "windows", "command", "activity"];

/* ── Shared pieces ─────────────────────────────────────────── */

function Keys({ children }: { children: ReactNode }) {
  return <span className="mb-keys">{children}</span>;
}

/** The 3×3 placement surface, drawn as zones rather than a glyph. */
function PlaceGrid({ lit = 7 }: { lit?: number }) {
  return (
    <div className="mb-place" role="group" aria-label="Placement">
      {Array.from({ length: 9 }, (_, i) => (
        <span key={i} className={`mb-place__cell${i === lit ? " mb-place__cell--lit" : ""}`} />
      ))}
    </div>
  );
}

function ActionRow({
  action,
  lit = false,
  sub = true,
}: {
  action: Action;
  lit?: boolean;
  sub?: boolean;
}) {
  return (
    <button type="button" className={`mb-row${lit ? " mb-row--lit" : ""}`}>
      <MI name={action.icon} className="mb-row__icon" />
      <span className="mb-row__text">
        <span className="mb-row__label">{action.label}</span>
        {sub ? <span className="mb-row__sub">{action.sub}</span> : null}
      </span>
      <Keys>{action.keys}</Keys>
    </button>
  );
}

function DaemonDot({ label }: { label: string }) {
  return (
    <span className="mb-dot">
      <i /> {label}
    </span>
  );
}

/* ── TODAY — the shipped layout, muted, for comparison ─────── */

function PopoverToday() {
  return (
    <div className="mb-pop mb-pop--today">
      <div className="mb-head">
        <span className="mb-mark"><i /><i /><i /><i /></span>
        <span className="mb-word">Lattices</span>
        <span className="mb-devbadge">DEV</span>
        <span className="mb-head__icons">
          {HEADER_ICONS.map((n, i) => (
            <button key={i} type="button" className="mb-ico"><MI name={n} /></button>
          ))}
        </span>
      </div>
      <div className="mb-secrow">
        <span className="mb-seclabel">Quick Actions</span>
        <span className="mb-seclink">Help &amp; shortcuts</span>
      </div>
      <div className="mb-list">
        <button type="button" className="mb-row">
          <MI name="move" className="mb-row__icon mb-row__icon--green" />
          <span className="mb-row__text">
            <span className="mb-row__label">Move</span>
            <span className="mb-row__sub">Ghostty — Lattices Dev</span>
          </span>
          <MI name="chevron" className="mb-row__chev" />
        </button>
        {ACTIONS.map((a) => <ActionRow key={a.id} action={a} />)}
        <button type="button" className="mb-row">
          <MI name="gear" className="mb-row__icon" />
          <span className="mb-row__text">
            <span className="mb-row__label">Settings</span>
            <span className="mb-row__sub">Preferences and permissions</span>
          </span>
          <Keys>⌘,</Keys>
        </button>
        <button type="button" className="mb-row mb-row--quit">
          <MI name="quit" className="mb-row__icon" />
          <span className="mb-row__text"><span className="mb-row__label">Quit</span></span>
        </button>
      </div>
    </div>
  );
}

/* ── A — FILTER-FIRST ──────────────────────────────────────── */

function PopoverFilter() {
  return (
    <div className="mb-pop">
      <div className="mb-search">
        <MI name="search" />
        <span className="mb-search__q">la<span className="mb-caret" /></span>
        <span className="mb-search__esc">esc</span>
      </div>

      <div className="mb-list mb-list--tight">
        <p className="mb-group">Sessions</p>
        <button type="button" className="mb-row">
          <MI name="play" className="mb-row__icon mb-row__icon--green" />
          <span className="mb-row__text">
            <span className="mb-row__label">lattices-dev <b className="mb-hit">· running</b></span>
          </span>
          <Keys>attach</Keys>
        </button>

        <p className="mb-group">Windows</p>
        <button type="button" className="mb-row">
          <span className="mb-appdot" style={{ background: "#2d3036" }}>G</span>
          <span className="mb-row__text">
            <span className="mb-row__label">lattices — swift build -c release</span>
            <span className="mb-row__sub">tmux lattices:build · Studio 1</span>
          </span>
        </button>
        <button type="button" className="mb-row">
          <span className="mb-appdot" style={{ background: "#2d3036" }}>G</span>
          <span className="mb-row__text">
            <span className="mb-row__label">lattices — bun … search vox --deep</span>
            <span className="mb-row__sub">tmux lattices:cli · Studio 1</span>
          </span>
        </button>

        <p className="mb-group">Actions</p>
        <button type="button" className="mb-row mb-row--lit">
          <MI name="move" className="mb-row__icon" />
          <span className="mb-row__text">
            <span className="mb-row__label">Place front window</span>
            <span className="mb-row__sub">Ghostty — lattices:cli</span>
          </span>
          <Keys>↵</Keys>
        </button>
      </div>

      <div className="mb-foot">
        <span>↵ run · ↑↓ choose</span>
        <span className="mb-foot__r">empty query = quick actions</span>
      </div>
    </div>
  );
}

/* ── B — STATUS UP, CHROME DOWN ────────────────────────────── */

function PopoverStatus() {
  return (
    <div className="mb-pop">
      <div className="mb-status">
        <div className="mb-status__top">
          <span className="mb-status__name">{SESSION.name}</span>
          <DaemonDot label="daemon" />
          <DaemonDot label="voice" />
        </div>
        <div className="mb-status__front">
          <span className="mb-appdot" style={{ background: "#2d3036" }}>G</span>
          <span className="mb-status__fronttitle">{FRONT.title}</span>
        </div>
        <div className="mb-status__grid">
          <PlaceGrid lit={8} />
          <div className="mb-status__gridnote">
            <span>Move front window</span>
            <Keys>bottom right</Keys>
          </div>
        </div>
      </div>

      <div className="mb-hair" />

      <div className="mb-list">
        {ACTIONS.map((a) => <ActionRow key={a.id} action={a} />)}
      </div>

      <div className="mb-hair" />

      <div className="mb-toolbar">
        {(["search", "layers", "activity"] as MIconName[]).map((n) => (
          <button key={n} type="button" className="mb-ico"><MI name={n} /></button>
        ))}
        <span className="mb-spacer" />
        <button type="button" className="mb-ico"><MI name="gear" /></button>
        <button type="button" className="mb-ico mb-ico--quit"><MI name="quit" /></button>
      </div>
    </div>
  );
}

/* ── C — MINI-HOME ─────────────────────────────────────────── */

const RAIL: { id: string; label: string; icon: MIconName; active?: boolean }[] = [
  { id: "move", label: "Move", icon: "move", active: true },
  { id: "assistant", label: "Assistant", icon: "assistant" },
  { id: "home", label: "Home", icon: "home" },
  { id: "studio", label: "Studio", icon: "studio" },
  { id: "command", label: "Bar", icon: "command" },
];

/** The display drawn to scale: 2560×1440 → the panes placed on it. */
function DesktopMap() {
  const wins = [
    { x: 0, y: 0, w: 67, h: 100, lit: false },          // Xcode left two-thirds
    { x: 67, y: 0, w: 33, h: 50, lit: false },          // build term
    { x: 67, y: 50, w: 33, h: 50, lit: true },          // front ghostty
  ];
  return (
    <div className="mb-desk">
      {wins.map((w, i) => (
        <span
          key={i}
          className={`mb-desk__win${w.lit ? " mb-desk__win--lit" : ""}`}
          style={{ left: `${w.x}%`, top: `${w.y}%`, width: `${w.w}%`, height: `${w.h}%` }}
        />
      ))}
      <span className="mb-desk__zones" aria-hidden="true">
        {Array.from({ length: 9 }, (_, i) => <i key={i} className={i === 8 ? "mb-desk__zone--lit" : undefined} />)}
      </span>
    </div>
  );
}

function PopoverMiniHome() {
  return (
    <div className="mb-pop mb-pop--wide">
      <div className="mb-split">
        <aside className="mb-rail">
          <span className="mb-mark mb-mark--rail"><i /><i /><i /><i /></span>
          {RAIL.map((r) => (
            <button key={r.id} type="button" className={`mb-rail__item${r.active ? " mb-rail__item--on" : ""}`}>
              <MI name={r.icon} />
              <span>{r.label}</span>
            </button>
          ))}
          <span className="mb-spacer" />
          <button type="button" className="mb-rail__item"><MI name="gear" /><span>Settings</span></button>
          <button type="button" className="mb-rail__item mb-rail__item--quit"><MI name="quit" /><span>Quit</span></button>
        </aside>

        <div className="mb-pane">
          <div className="mb-pane__head">
            <span className="mb-pane__title">Move</span>
            <span className="mb-pane__sub">{FRONT.app} — {FRONT.title}</span>
          </div>
          <DesktopMap />
          <div className="mb-pane__foot">
            <span>Space 1 · Build · Studio Display</span>
            <Keys>Hyp L → Studio</Keys>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ── C, developed — the rail actually switches panes ───────── */

type RailId = "move" | "assistant" | "home" | "studio" | "command";

const RAIL_FULL: { id: RailId; label: string; icon: MIconName }[] = [
  { id: "move", label: "Move", icon: "move" },
  { id: "assistant", label: "Assistant", icon: "assistant" },
  { id: "home", label: "Home", icon: "home" },
  { id: "studio", label: "Studio", icon: "studio" },
  { id: "command", label: "Bar", icon: "command" },
];

const ZONE_NAMES = [
  "top left", "top", "top right",
  "left", "center", "right",
  "bottom left", "bottom", "bottom right",
];

/** Where the front window lands per zone — halves, quarters, center. */
const ZONE_RECTS = [
  { x: 0, y: 0, w: 50, h: 50 },
  { x: 25, y: 0, w: 50, h: 50 },
  { x: 50, y: 0, w: 50, h: 50 },
  { x: 0, y: 0, w: 50, h: 100 },
  { x: 25, y: 25, w: 50, h: 50 },
  { x: 50, y: 0, w: 50, h: 100 },
  { x: 0, y: 50, w: 50, h: 50 },
  { x: 25, y: 50, w: 50, h: 50 },
  { x: 50, y: 50, w: 50, h: 50 },
];

const CONTEXT_WINS = [
  { x: 0, y: 0, w: 67, h: 100 },   // Xcode, left two-thirds
  { x: 67, y: 0, w: 33, h: 50 },   // build term, top right
];

function MovePane() {
  const [zone, setZone] = useState(8);
  const r = ZONE_RECTS[zone];
  return (
    <>
      <div className="mb-desk">
        {CONTEXT_WINS.map((w, i) => (
          <span
            key={i}
            className="mb-desk__win"
            style={{ left: `${w.x}%`, top: `${w.y}%`, width: `${w.w}%`, height: `${w.h}%` }}
          />
        ))}
        <span
          className="mb-desk__win mb-desk__win--lit mb-desk__win--front"
          style={{ left: `${r.x}%`, top: `${r.y}%`, width: `${r.w}%`, height: `${r.h}%` }}
        />
        <span className="mb-desk__zones">
          {Array.from({ length: 9 }, (_, i) => (
            <button
              key={i}
              type="button"
              className={`mb-desk__zone${i === zone ? " mb-desk__zone--on" : ""}`}
              onClick={() => setZone(i)}
              aria-label={ZONE_NAMES[i]}
            />
          ))}
        </span>
      </div>
      <div className="mb-pane__foot">
        <span>Space 1 · Build · Studio Display</span>
        <Keys>{ZONE_NAMES[zone]}</Keys>
      </div>
    </>
  );
}

function AssistantPane() {
  return (
    <>
      <div className="mb-chat">
        <div className="mb-bub mb-bub--me">tile the two ghostty windows side by side</div>
        <div className="mb-bub mb-bub--ai">
          Done — <b>lattices:cli</b> and <b>lattices:build</b> split left/right on Studio 1.
          <span className="mb-bub__undo"><MI name="arrowRight" /> undo</span>
        </div>
        <div className="mb-bub mb-bub--me">now move xcode to space 2</div>
        <div className="mb-bub mb-bub--ai mb-bub--typing"><i /><i /><i /></div>
      </div>
      <div className="mb-input">
        <span className="mb-input__hint">Ask, or / for commands…</span>
        <MI name="send" className="mb-input__send" />
      </div>
    </>
  );
}

const PROJECTS = [
  { name: "lattices-dev", path: "~/dev/lattices", meta: "4 panes · 7 windows", running: true },
  { name: "action-dev", path: "~/dev/lattices/products/action", meta: "2 panes · 3 windows", running: true },
  { name: "blink", path: "~/dev/lattices/products/blink", meta: "last run 2d ago", running: false },
];

function HomePane() {
  return (
    <>
      <div className="mb-projs">
        {PROJECTS.map((p) => (
          <button key={p.name} type="button" className={`mb-proj${p.running ? "" : " mb-proj--off"}`}>
            <span className={`mb-proj__dot${p.running ? " mb-proj__dot--on" : ""}`} />
            <span className="mb-proj__text">
              <span className="mb-proj__name">{p.name}</span>
              <span className="mb-proj__meta">{p.path} · {p.meta}</span>
            </span>
            <MI name={p.running ? "focus" : "play"} className="mb-proj__act" />
          </button>
        ))}
      </div>
      <div className="mb-pane__foot">
        <span>2 running · 1 stopped</span>
        <Keys>Hyp 1</Keys>
      </div>
    </>
  );
}

const LAYERS = [
  { label: "Dev", running: 3, total: 3, active: true },
  { label: "Review", running: 1, total: 2, active: false },
  { label: "Writing", running: 0, total: 2, active: false },
];

function StudioPane() {
  return (
    <>
      <div className="mb-layers">
        {LAYERS.map((l) => (
          <button key={l.label} type="button" className={`mb-layer${l.active ? " mb-layer--on" : ""}`}>
            <MI name="layers" className="mb-layer__icon" />
            <span className="mb-layer__label">{l.label}</span>
            <span className="mb-layer__bar">
              {Array.from({ length: l.total }, (_, i) => (
                <i key={i} className={i < l.running ? "mb-layer__pip--on" : undefined} />
              ))}
            </span>
            <span className="mb-layer__n">{l.running}/{l.total}</span>
          </button>
        ))}
      </div>
      <div className="mb-pane__foot">
        <span>Space 1 · Build</span>
        <Keys>optimize ␣</Keys>
      </div>
    </>
  );
}

const SLASH = [
  { cmd: "/tile left", sub: "front window → left half", icon: "tileLeft" as MIconName },
  { cmd: "/space optimize", sub: "rebalance this space", icon: "layers" as MIconName },
  { cmd: "/attach lattices", sub: "tmux attach ~/dev/lattices", icon: "play" as MIconName },
];

function BarPane() {
  return (
    <>
      <div className="mb-input mb-input--bar">
        <MI name="command" className="mb-input__lead" />
        <span className="mb-input__hint">/ or search…</span>
      </div>
      <div className="mb-list mb-list--tight mb-list--pad">
        {SLASH.map((s, i) => (
          <button key={s.cmd} type="button" className={`mb-row${i === 0 ? " mb-row--lit" : ""}`}>
            <MI name={s.icon} className="mb-row__icon" />
            <span className="mb-row__text">
              <span className="mb-row__label mb-mono">{s.cmd}</span>
              <span className="mb-row__sub">{s.sub}</span>
            </span>
            <Keys>↵</Keys>
          </button>
        ))}
      </div>
    </>
  );
}

const PANE_META: Record<RailId, { title: string; sub: string }> = {
  move: { title: "Move", sub: `${FRONT.app} — ${FRONT.title}` },
  assistant: { title: "Assistant", sub: "⌃⌥A anywhere" },
  home: { title: "Home", sub: "projects & sessions" },
  studio: { title: "Studio", sub: "layers on this space" },
  command: { title: "Command Bar", sub: "browse · search · run" },
};

function MiniHomeFull() {
  const [tab, setTab] = useState<RailId>("move");
  const meta = PANE_META[tab];
  return (
    <div className="mb-pop mb-pop--wide">
      <div className="mb-split mb-split--full">
        <aside className="mb-rail">
          <span className="mb-mark mb-mark--rail"><i /><i /><i /><i /></span>
          {RAIL_FULL.map((r) => (
            <button
              key={r.id}
              type="button"
              onClick={() => setTab(r.id)}
              className={`mb-rail__item${r.id === tab ? " mb-rail__item--on" : ""}`}
            >
              <MI name={r.icon} />
              <span>{r.label}</span>
            </button>
          ))}
          <span className="mb-spacer" />
          <button type="button" className="mb-rail__item"><MI name="gear" /><span>Settings</span></button>
          <button type="button" className="mb-rail__item mb-rail__item--quit"><MI name="quit" /><span>Quit</span></button>
        </aside>

        <div className="mb-pane">
          <div className="mb-pane__head">
            <span className="mb-pane__title">{meta.title}</span>
            <span className="mb-pane__sub">{meta.sub}</span>
          </div>
          {tab === "move" && <MovePane />}
          {tab === "assistant" && <AssistantPane />}
          {tab === "home" && <HomePane />}
          {tab === "studio" && <StudioPane />}
          {tab === "command" && <BarPane />}
        </div>
      </div>
    </div>
  );
}

/* ── The study page ────────────────────────────────────────── */

function Cell({ tag, name, note, children }: { tag: string; name: string; note: string; children: ReactNode }) {
  return (
    <figure className="mb-cell">
      <figcaption className="mb-cell__cap">
        <span className="mb-cell__tag">{tag}</span>
        <span className="mb-cell__name">{name}</span>
        <span className="mb-cell__note">{note}</span>
      </figcaption>
      {children}
    </figure>
  );
}

export function MenubarStudy({ page }: { page: LatticesPage }) {
  return (
    <main className="w-full px-6 py-10 lg:px-7">
      <header className="max-w-[980px] border-b border-studio-rule pb-7">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">
          {page.bucket} / {page.surface}
        </div>
        <h1 className="mt-4 text-[36px] font-medium leading-tight text-studio-ink-strong">
          {page.label}
        </h1>
        <p className="mt-4 max-w-[66ch] text-[15px] leading-[1.7] text-studio-ink">
          The popover currently runs two nav systems over the same destinations —
          a 7-icon header row and a labelled Quick Actions list — and pays a
          subtitle and hotkey chips on every row forever. Three passes, drawn at
          true popover scale next to today&apos;s layout.
        </p>
      </header>

      <section className="py-10">
        <div className="mb-board">
          <Cell tag="A" name="Filter-first" note="the popover is a small command bar">
            <PopoverFilter />
          </Cell>
          <Cell tag="B" name="Status up, chrome down" note="where am I before what can I do">
            <PopoverStatus />
          </Cell>
          <Cell tag="C" name="Mini-Home" note="the popover is a small Home window">
            <PopoverMiniHome />
          </Cell>
          <Cell tag="·" name="Today" note="MainView.swift, as shipped">
            <PopoverToday />
          </Cell>
        </div>
      </section>

      <section className="py-4">
        <div className="mb-cell__cap mb-cell__cap--solo">
          <span className="mb-cell__tag">C+</span>
          <span className="mb-cell__name">Mini-Home, developed</span>
          <span className="mb-cell__note">the rail switches panes — click through Move / Assistant / Home / Studio / Bar, and click the desktop to place the front window</span>
        </div>
        <MiniHomeFull />
      </section>

      <section className="max-w-[980px] pt-10">
        <div className="grid gap-x-12 sm:grid-cols-3">
          <div className="border-t border-studio-edge py-6">
            <h3 className="font-sans text-[17px] font-medium leading-snug tracking-tight text-studio-ink">
              A — Filter-first
            </h3>
            <p className="mt-2 text-[14px] leading-relaxed text-studio-ink-faint">
              The icon row is gone; its destinations are simply the empty query.
              Subtitles appear only on the highlighted row. The popover stops
              duplicating Command Bar and starts converging with it — same
              muscle, shorter reach.
            </p>
            <p className="mt-3 flex gap-2 font-mono text-[11px] leading-relaxed text-studio-ink-faint">
              <span className="opacity-60">kills</span>
              <span className="opacity-80">7-icon row · permanent subtitles</span>
            </p>
          </div>
          <div className="border-t border-studio-edge py-6">
            <h3 className="font-sans text-[17px] font-medium leading-snug tracking-tight text-studio-ink">
              B — Status up, chrome down
            </h3>
            <p className="mt-2 text-[14px] leading-relaxed text-studio-ink-faint">
              Same content, honest hierarchy. The session, daemon/voice dots,
              and the front window Move acts on all live up top with the
              placement grid; the icon row demotes to footer chrome next to
              Settings and Quit.
            </p>
            <p className="mt-3 flex gap-2 font-mono text-[11px] leading-relaxed text-studio-ink-faint">
              <span className="opacity-60">moves</span>
              <span className="opacity-80">icons → footer · Move → status zone</span>
            </p>
          </div>
          <div className="border-t border-studio-edge py-6">
            <h3 className="font-sans text-[17px] font-medium leading-snug tracking-tight text-studio-ink">
              C — Mini-Home
            </h3>
            <p className="mt-2 text-[14px] leading-relaxed text-studio-ink-faint">
              The rail is the current list compressed; the pane swaps per
              destination. Move finally gets a to-scale desktop instead of an
              inline unfold. Heaviest popover, but one mental model shared with
              the Home window at two scales.
            </p>
            <p className="mt-3 flex gap-2 font-mono text-[11px] leading-relaxed text-studio-ink-faint">
              <span className="opacity-60">risks</span>
              <span className="opacity-80">popover weight · rail crowding</span>
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}
