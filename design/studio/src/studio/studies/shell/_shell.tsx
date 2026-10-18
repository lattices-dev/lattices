"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

/* ============================================================
   Shared furniture for the shell studio.

   The mock is a dark Mac app in both studio themes, so its chrome lives in
   plain CSS (`.as-*` in index.css) with the palette mirrored from
   apps/mac/Sources/UI/Theme.swift. Tailwind stays on the studio page around it.
   ============================================================ */

/* ── Icons ─────────────────────────────────────────────────── */

export type IconName =
  | "home"
  | "studio"
  | "windows"
  | "assistant"
  | "runs"
  | "activity"
  | "gear"
  | "search"
  | "scan"
  | "play"
  | "focus"
  | "tileLeft"
  | "tileRight"
  | "copy"
  | "chevron"
  | "filter"
  | "text"
  | "command"
  | "send";

const PATHS: Record<IconName, ReactNode> = {
  home: <path d="M3 9.6 12 3l9 6.6V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1V9.6Z" />,
  studio: (
    <>
      <rect x="3" y="3" width="8" height="18" rx="1.6" />
      <rect x="13" y="3" width="8" height="8" rx="1.6" />
      <rect x="13" y="13" width="8" height="8" rx="1.6" />
    </>
  ),
  windows: (
    <>
      <rect x="3" y="4" width="13" height="10" rx="1.6" />
      <path d="M8 18h11a2 2 0 0 0 2-2V8" />
    </>
  ),
  assistant: <path d="M20 14a2 2 0 0 1-2 2H8l-4 3.5V6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v8Z" />,
  runs: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="3.2" />
    </>
  ),
  activity: <path d="M3 12h4l2.5-6 4 13 3-7H21" />,
  gear: (
    <>
      <circle cx="12" cy="12" r="3.2" />
      <path d="M19.4 14.4a1.6 1.6 0 0 0 .32 1.77l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.6 1.6 0 0 0-1.77-.32 1.6 1.6 0 0 0-1 1.47V21a2 2 0 0 1-4 0v-.1a1.6 1.6 0 0 0-1-1.47 1.6 1.6 0 0 0-1.77.32l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.6 1.6 0 0 0 .32-1.77 1.6 1.6 0 0 0-1.47-1H3a2 2 0 0 1 0-4h.1a1.6 1.6 0 0 0 1.47-1 1.6 1.6 0 0 0-.32-1.77l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.6 1.6 0 0 0 1.77.32H9a1.6 1.6 0 0 0 1-1.47V3a2 2 0 0 1 4 0v.1a1.6 1.6 0 0 0 1 1.47 1.6 1.6 0 0 0 1.77-.32l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.6 1.6 0 0 0-.32 1.77V9a1.6 1.6 0 0 0 1.47 1H21a2 2 0 0 1 0 4h-.1a1.6 1.6 0 0 0-1.47 1Z" />
    </>
  ),
  search: (
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.9-3.9" />
    </>
  ),
  scan: (
    <>
      <path d="M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3" />
      <path d="M7 12h10" />
    </>
  ),
  play: <path d="M8 5.5 18.5 12 8 18.5v-13Z" />,
  focus: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3v3M12 18v3M3 12h3M18 12h3" />
    </>
  ),
  tileLeft: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M11 4v16" />
      <path d="M4.5 8h5M4.5 12h5" opacity=".55" />
    </>
  ),
  tileRight: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M13 4v16" />
      <path d="M14.5 8h5M14.5 12h5" opacity=".55" />
    </>
  ),
  copy: (
    <>
      <rect x="8" y="8" width="13" height="13" rx="2" />
      <path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3" />
    </>
  ),
  chevron: <path d="m6 9 6 6 6-6" />,
  filter: <path d="M3 5h18l-7 8v6l-4 2v-8L3 5Z" />,
  text: <path d="M4 7V5h16v2M12 5v14M9 19h6" />,
  command: <path d="M9 6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6Z" />,
  send: <path d="M4 12h14M13 6l6 6-6 6" />,
};

export function Icon({ name, className = "as-icon" }: { name: IconName; className?: string }) {
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
      {PATHS[name]}
    </svg>
  );
}

/* ── Data ──────────────────────────────────────────────────── */

export type AppKey = "ghostty" | "chrome" | "xcode" | "figma" | "slack";

export const APPS: Record<AppKey, { label: string; letter: string; fill: string }> = {
  ghostty: { label: "Ghostty", letter: "G", fill: "linear-gradient(#34373d,#25282d)" },
  chrome: { label: "Chrome", letter: "C", fill: "linear-gradient(#3b8ef5,#1a63d4)" },
  xcode: { label: "Xcode", letter: "X", fill: "linear-gradient(#1e9c8a,#0c6055)" },
  figma: { label: "Figma", letter: "F", fill: "linear-gradient(#7a5cf7,#4c2bd6)" },
  slack: { label: "Slack", letter: "S", fill: "linear-gradient(#4a505a,#31363e)" },
};

export type DisplayKey = "studio" | "builtin";

export const DISPLAYS: Record<
  DisplayKey,
  { label: string; short: string; swatch: string; windows: number }
> = {
  studio: { label: "Studio Display", short: "Studio", swatch: "#4c7fe0", windows: 24 },
  builtin: { label: "Built-in", short: "Built-in", swatch: "#8a6bd1", windows: 14 },
};

export interface Win {
  id: string;
  app: AppKey;
  title: string;
  display: DisplayKey;
  space: string;
  size: string;
  /** Frame origin in the global desktop space, as the inspector reports it. */
  origin: string;
  when: string;
  cwd: string;
  tmux?: string;
  pid: number;
  ocr?: { before: string; hit: string; after: string };
}

export const WINDOWS: Win[] = [
  {
    id: "w1",
    app: "ghostty",
    title: "lattices — swift build -c release",
    display: "studio",
    space: "1 · Build",
    size: "1280×1040",
    origin: "0,0",
    when: "now",
    cwd: "~/dev/lattices",
    tmux: "lattices:build",
    pid: 41207,
    ocr: {
      before: "Compiling ",
      hit: "Lattices",
      after: " (204 sources) · AppShellView.swift:118 warning: unused result",
    },
  },
  {
    id: "w2",
    app: "chrome",
    title: "lattices.dev — Docs / Overview",
    display: "studio",
    space: "1 · Build",
    size: "1600×1200",
    origin: "1280,0",
    when: "2m",
    cwd: "—",
    pid: 38810,
  },
  {
    id: "w3",
    app: "xcode",
    title: "Lattices — AppShellView.swift",
    display: "studio",
    space: "1 · Build",
    size: "2048×1330",
    origin: "0,0",
    when: "6m",
    cwd: "~/dev/lattices/apps/mac",
    pid: 40155,
  },
  {
    id: "w4",
    app: "ghostty",
    title: "lattices — bun bin/lattices.ts search vox --deep",
    display: "studio",
    space: "1 · Build",
    size: "980×720",
    origin: "1280,1200",
    when: "9m",
    cwd: "~/dev/lattices",
    tmux: "lattices:cli",
    pid: 41209,
  },
  {
    id: "w5",
    app: "figma",
    title: "Lattices — shell explorations",
    display: "studio",
    space: "2 · Review",
    size: "1440×900",
    origin: "0,0",
    when: "18m",
    cwd: "—",
    pid: 36002,
  },
  {
    id: "w6",
    app: "chrome",
    title: "arach/lattices — Pull request #212",
    display: "studio",
    space: "2 · Review",
    size: "1512×980",
    origin: "1440,0",
    when: "21m",
    cwd: "—",
    pid: 38810,
    ocr: {
      before: "18 files changed · ",
      hit: "lattices",
      after: "/apps/mac/Sources/AppShell/HomeDashboardView.swift",
    },
  },
  {
    id: "w7",
    app: "ghostty",
    title: "action — bun test --watch",
    display: "builtin",
    space: "1 · Build",
    size: "980×720",
    origin: "0,25",
    when: "24m",
    cwd: "~/dev/action",
    tmux: "action:test",
    pid: 41402,
  },
  {
    id: "w8",
    app: "slack",
    title: "#lattices-dev",
    display: "builtin",
    space: "2 · Review",
    size: "1100×860",
    origin: "980,25",
    when: "1h",
    cwd: "—",
    pid: 33901,
  },
];

export interface Session {
  name: string;
  path: string;
  running: boolean;
  facts: string[];
}

export const SESSIONS: Session[] = [
  { name: "lattices", path: "~/dev/lattices", running: true, facts: ["tmux · 4 panes", "7 windows"] },
  { name: "action", path: "~/dev/action", running: true, facts: ["tmux · 2 panes", "3 windows"] },
  { name: "blink", path: "~/dev/blink", running: false, facts: ["last run 2d ago"] },
];

export const LAYOUTS = [
  { name: "Dev three-up", key: "⌥1", cells: 3 },
  { name: "Review", key: "⌥2", cells: 2 },
  { name: "Focus", key: "⌥3", cells: 1 },
];

export const NAV_GROUPS: {
  label: string;
  items: { id: string; label: string; icon: IconName; count?: number }[];
}[] = [
  {
    label: "Workspace",
    items: [
      { id: "home", label: "Home", icon: "home" },
      { id: "studio", label: "Studio", icon: "studio" },
      { id: "windows", label: "Windows", icon: "windows", count: 38 },
    ],
  },
  {
    label: "Agents",
    items: [
      { id: "assistant", label: "Assistant", icon: "assistant" },
      { id: "runs", label: "Runs", icon: "runs", count: 4 },
    ],
  },
  { label: "System", items: [{ id: "activity", label: "Activity", icon: "activity" }] },
];

/* ── Chrome ────────────────────────────────────────────────── */

export function AppWindow({
  title = "Lattices",
  children,
  className = "",
}: {
  title?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`as ${className}`}>
      <div className="as-titlebar">
        <span className="as-dot as-dot--r" />
        <span className="as-dot as-dot--y" />
        <span className="as-dot as-dot--g" />
        <span className="as-titlebar__name">{title}</span>
        <span className="as-titlebar__pad" />
      </div>
      {children}
    </div>
  );
}

export function Mark() {
  return (
    <span className="as-mark">
      <i />
      <i />
      <i />
      <i />
    </span>
  );
}

export function Rail({ active }: { active: string }) {
  return (
    <aside className="as-rail">
      <div className="as-rail__head">
        <Mark />
        <span className="as-rail__wordmark">Lattices</span>
      </div>

      {NAV_GROUPS.map((group) => (
        <div className="as-group" key={group.label}>
          <p className="as-group__label">{group.label}</p>
          {group.items.map((item) => (
            <button
              key={item.id}
              type="button"
              className="as-nav"
              aria-current={active === item.id ? "page" : undefined}
            >
              <Icon name={item.icon} />
              {item.label}
              {item.count !== undefined ? (
                <span className="as-nav__count">{item.count}</span>
              ) : null}
            </button>
          ))}
        </div>
      ))}

      <div className="as-rail__foot">
        <div className="as-host">
          <span className="as-host__pulse" />
          <span className="as-host__name">Daemon</span>
          <span className="as-host__port">:9399</span>
        </div>
        <button type="button" className="as-nav">
          <Icon name="gear" />
          Settings
        </button>
      </div>
    </aside>
  );
}

export function Btn({
  icon,
  children,
  primary = false,
  trailing,
}: {
  icon?: IconName;
  children: ReactNode;
  primary?: boolean;
  trailing?: ReactNode;
}) {
  return (
    <button type="button" className={`as-btn${primary ? " as-btn--primary" : ""}`}>
      {icon ? <Icon name={icon} /> : null}
      {children}
      {trailing}
    </button>
  );
}

export function Kbd({ children }: { children: ReactNode }) {
  return <span className="as-kbd">{children}</span>;
}

export function Toolbar({ title, sub, children }: { title: string; sub?: string; children?: ReactNode }) {
  return (
    <div className="as-toolbar">
      <h2 className="as-toolbar__title">{title}</h2>
      {sub ? <span className="as-toolbar__sub">{sub}</span> : null}
      <span className="as-spacer" />
      {children}
    </div>
  );
}

export function StatusBar({ items, right }: { items: ReactNode[]; right?: ReactNode }) {
  return (
    <div className="as-statusbar">
      {items.map((item, i) => (
        <span key={i}>{item}</span>
      ))}
      {right ? <span className="as-statusbar__right">{right}</span> : null}
    </div>
  );
}

export function Sec({ title, count, action }: { title: string; count?: number; action?: string }) {
  return (
    <div className="as-sec">
      <h3 className="as-sec__title">{title}</h3>
      {count !== undefined ? <span className="as-sec__count">{count}</span> : null}
      {action ? (
        <button type="button" className="as-sec__action">
          {action}
        </button>
      ) : null}
    </div>
  );
}

export function AppIcon({ app }: { app: AppKey }) {
  return (
    <span className="as-appicon" style={{ background: APPS[app].fill }}>
      {APPS[app].letter}
    </span>
  );
}

export function ColHead({ compact = false }: { compact?: boolean }) {
  return (
    <div className="as-colhead">
      <span />
      <span>App</span>
      <span>Window</span>
      <span>Space</span>
      {compact ? null : <span className="as-r">Size</span>}
      <span className="as-r">Active</span>
    </div>
  );
}

/** One window row. `trailing: "actions"` swaps the Active cell for hover controls. */
export function WindowRow({
  win,
  selected = false,
  spaceLabel,
  trailing = "when",
  compact = false,
  onSelect,
}: {
  win: Win;
  selected?: boolean;
  spaceLabel?: string;
  trailing?: "when" | "actions";
  /** Inventory shape: no Size column — the inspector carries the frame. */
  compact?: boolean;
  onSelect?: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={`as-row${selected ? " as-row--sel" : ""}`}
      aria-pressed={selected}
    >
      <AppIcon app={win.app} />
      <span className="as-row__app">{APPS[win.app].label}</span>
      <span className="as-row__title">{win.title}</span>
      <span className="as-meta">{spaceLabel ?? `${DISPLAYS[win.display].short} · ${win.space[0]}`}</span>
      {compact ? null : <span className="as-meta as-r">{win.size}</span>}
      {trailing === "actions" ? (
        <span className="as-row__acts">
          <span className="as-icobtn" title="Focus">
            <Icon name="focus" />
          </span>
          <span className="as-icobtn" title="Tile left">
            <Icon name="tileLeft" />
          </span>
          <span className="as-icobtn" title="Tile right">
            <Icon name="tileRight" />
          </span>
        </span>
      ) : (
        <span className="as-meta as-r">{win.when}</span>
      )}
    </button>
  );
}

export function OcrLine({ win }: { win: Win }) {
  if (!win.ocr) return null;
  return (
    <div className="as-ocr">
      <Icon name="text" />
      <span>
        {win.ocr.before}
        <b>{win.ocr.hit}</b>
        {win.ocr.after}
      </span>
    </div>
  );
}

/* ── Studio-side presentation ──────────────────────────────── */

export interface Change {
  title: string;
  body: string;
  was: string;
}

/** The change ledger under each exhibit: hairline rules, no card wall. */
export function ChangeLedger({ changes }: { changes: Change[] }) {
  return (
    <div className="mt-10 grid gap-x-12 sm:grid-cols-2">
      {changes.map((change) => (
        <div key={change.title} className="border-t border-studio-edge py-6">
          <h3 className="font-sans text-[17px] font-medium leading-snug tracking-tight text-studio-ink">
            {change.title}
          </h3>
          <p className="mt-2 text-[14px] leading-relaxed text-studio-ink-faint">{change.body}</p>
          <p className="mt-3 flex gap-2 font-mono text-[11px] leading-relaxed text-studio-ink-faint">
            <span className="opacity-60">was</span>
            <span className="opacity-80">{change.was}</span>
          </p>
        </div>
      ))}
    </div>
  );
}

/** Caption strip under a mock: what you're looking at, and where it lives in Swift. */
export function MockCaption({ note }: { note: string }) {
  return (
    <p className="mt-3 border-t border-studio-edge pt-3 text-[13px] text-studio-ink-faint">
      {note}
    </p>
  );
}

/** The mock's natural size, so a thumbnail can be an exact miniature of it. */
export const MOCK_W = 1100;
export const MOCK_H = 640;

/**
 * Renders a full-size mock scaled to fit its frame. The frame is fluid (two-up
 * on the exhibit index, one-up when narrow), so the scale is measured rather
 * than guessed — otherwise the miniature leaves dead space at one edge.
 */
export function Thumb({ children }: { children: ReactNode }) {
  const frame = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(0.4);

  useEffect(() => {
    const el = frame.current;
    if (!el) return;
    const measure = () => setScale(el.clientWidth / MOCK_W);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return (
    <div className="as-thumbframe" ref={frame}>
      <div
        className="as-thumbscale"
        style={{ "--as-thumb-w": `${MOCK_W}px`, "--as-thumb-s": scale } as React.CSSProperties}
      >
        {children}
      </div>
    </div>
  );
}
