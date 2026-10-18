"use client";

import type { CSSProperties, ReactNode } from "react";
import { Icon, type IconName } from "../shell/_shell";

/* ============================================================
   Furniture for the second shell pass.

   The stroke icon set is shared with the first pass; everything that decides
   how the app *looks* — the unified toolbar, the bar, rows, the desktop map —
   lives here and in the `.bs-*` rules in index.css. Palette still mirrors
   apps/mac/Sources/UI/Theme.swift.
   ============================================================ */

/* ── Icons the first pass didn't need ─────────────────────── */

type ExtraIcon = "mic" | "list" | "display" | "enter" | "more" | "layers" | "maximize" | "close";

export type BIconName = IconName | ExtraIcon;

const EXTRA: Record<ExtraIcon, ReactNode> = {
  mic: (
    <>
      <rect x="9" y="3" width="6" height="11" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3M9 21h6" />
    </>
  ),
  list: <path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01" />,
  display: (
    <>
      <rect x="3" y="4" width="18" height="13" rx="2" />
      <path d="M9 21h6M12 17v4" />
    </>
  ),
  enter: <path d="M20 5v6a2 2 0 0 1-2 2H5M9 9l-4 4 4 4" />,
  more: (
    <>
      <circle cx="5" cy="12" r="1" />
      <circle cx="12" cy="12" r="1" />
      <circle cx="19" cy="12" r="1" />
    </>
  ),
  layers: (
    <>
      <path d="m12 4 9 5-9 5-9-5 9-5Z" />
      <path d="m3 14 9 5 9-5" />
    </>
  ),
  maximize: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <rect x="6.5" y="7.5" width="11" height="9" rx="1" />
    </>
  ),
  close: <path d="M6 6l12 12M18 6 6 18" />,
};

function isExtra(name: BIconName): name is ExtraIcon {
  return name in EXTRA;
}

export function BI({ name, className = "bs-icon" }: { name: BIconName; className?: string }) {
  if (isExtra(name)) {
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
        {EXTRA[name]}
      </svg>
    );
  }
  return <Icon name={name} className={className} />;
}

/* ── Data ──────────────────────────────────────────────────── */

export type BAppKey = "ghostty" | "chrome" | "xcode" | "figma" | "slack";

/* Flat fills. The icon is an identifier, not a jewel. */
export const B_APPS: Record<BAppKey, { label: string; letter: string; fill: string }> = {
  ghostty: { label: "Ghostty", letter: "G", fill: "#2d3036" },
  chrome: { label: "Chrome", letter: "C", fill: "#2f6fd6" },
  xcode: { label: "Xcode", letter: "X", fill: "#177a6b" },
  figma: { label: "Figma", letter: "F", fill: "#5b3fd9" },
  slack: { label: "Slack", letter: "S", fill: "#3e434c" },
};

export type BDisplayKey = "studio" | "builtin";

export interface BSpace {
  index: number;
  label: string;
  /** Windows on that space, including ones the mock doesn't draw. */
  count: number;
}

export interface BDisplay {
  key: BDisplayKey;
  name: string;
  /** Logical (points) size — what the AX frames are reported in. */
  w: number;
  h: number;
  main: boolean;
  spaces: BSpace[];
  current: number;
}

export const B_DISPLAYS: BDisplay[] = [
  {
    key: "studio",
    name: "Studio Display",
    w: 2560,
    h: 1440,
    main: true,
    spaces: [
      { index: 1, label: "Build", count: 4 },
      { index: 2, label: "Review", count: 2 },
      { index: 3, label: "Comms", count: 3 },
      { index: 4, label: "Scratch", count: 2 },
    ],
    current: 1,
  },
  {
    key: "builtin",
    name: "Built-in",
    w: 1512,
    h: 982,
    main: false,
    spaces: [
      { index: 1, label: "Build", count: 2 },
      { index: 2, label: "Review", count: 1 },
    ],
    current: 1,
  },
];

export const B_WINDOW_TOTAL = B_DISPLAYS.reduce(
  (n, d) => n + d.spaces.reduce((m, s) => m + s.count, 0),
  0,
);

export interface BWin {
  id: string;
  app: BAppKey;
  title: string;
  display: BDisplayKey;
  space: number;
  x: number;
  y: number;
  w: number;
  h: number;
  /** Stacking order within its space; higher is nearer the user. */
  z: number;
  cwd?: string;
  tmux?: string;
  pid: number;
  ocr?: { before: string; hit: string; after: string };
  /** The window that was frontmost when Lattices was summoned. */
  front?: boolean;
}

export const B_WINDOWS: BWin[] = [
  {
    id: "w1",
    app: "xcode",
    title: "Lattices — AppShellView.swift",
    display: "studio",
    space: 1,
    x: 0,
    y: 0,
    w: 1706,
    h: 1440,
    z: 0,
    cwd: "~/dev/lattices/apps/mac",
    pid: 40155,
  },
  {
    id: "w2",
    app: "ghostty",
    title: "lattices — swift build -c release",
    display: "studio",
    space: 1,
    x: 1706,
    y: 0,
    w: 854,
    h: 720,
    z: 1,
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
    id: "w3",
    app: "ghostty",
    title: "lattices — bun bin/lattices.ts search vox --deep",
    display: "studio",
    space: 1,
    x: 1706,
    y: 720,
    w: 854,
    h: 720,
    z: 1,
    cwd: "~/dev/lattices",
    tmux: "lattices:cli",
    pid: 41209,
  },
  {
    id: "w4",
    app: "chrome",
    title: "lattices.dev — Docs / Overview",
    display: "studio",
    space: 1,
    x: 240,
    y: 160,
    w: 1400,
    h: 1040,
    z: 2,
    pid: 38810,
    front: true,
  },
  {
    id: "w5",
    app: "figma",
    title: "Lattices — shell explorations",
    display: "studio",
    space: 2,
    x: 0,
    y: 0,
    w: 1440,
    h: 1440,
    z: 0,
    pid: 36002,
  },
  {
    id: "w6",
    app: "chrome",
    title: "arach/lattices — Pull request #212",
    display: "studio",
    space: 2,
    x: 1440,
    y: 0,
    w: 1120,
    h: 1440,
    z: 0,
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
    space: 1,
    x: 0,
    y: 0,
    w: 756,
    h: 982,
    z: 0,
    cwd: "~/dev/action",
    tmux: "action:test",
    pid: 41402,
  },
  {
    id: "w8",
    app: "chrome",
    title: "Scout — dashboard",
    display: "builtin",
    space: 1,
    x: 756,
    y: 0,
    w: 756,
    h: 982,
    z: 0,
    pid: 38810,
  },
  {
    id: "w9",
    app: "slack",
    title: "#lattices-dev",
    display: "builtin",
    space: 2,
    x: 0,
    y: 0,
    w: 1512,
    h: 982,
    z: 0,
    pid: 33901,
  },
];

export const FRONT_WINDOW = B_WINDOWS.find((w) => w.front) ?? B_WINDOWS[0];

export function displayOf(win: BWin): BDisplay {
  return B_DISPLAYS.find((d) => d.key === win.display) ?? B_DISPLAYS[0];
}

export function spaceLabel(win: BWin): string {
  const d = displayOf(win);
  const s = d.spaces.find((sp) => sp.index === win.space);
  return `${d.key === "studio" ? "Studio" : "Built-in"} · ${win.space}${s ? ` ${s.label}` : ""}`;
}

/** Does the window match a typed query — by title, cwd, tmux session, or screen text. */
export function matches(win: BWin, q: string): boolean {
  const needle = q.toLowerCase();
  if (!needle) return true;
  const hay = [win.title, win.cwd ?? "", win.tmux ?? "", B_APPS[win.app].label]
    .join(" ")
    .toLowerCase();
  return hay.includes(needle) || win.ocr?.hit.toLowerCase().includes(needle) === true;
}

export interface BSession {
  name: string;
  path: string;
  running: boolean;
  panes?: number;
}

export const B_SESSIONS: BSession[] = [
  { name: "lattices", path: "~/dev/lattices", running: true, panes: 4 },
  { name: "action", path: "~/dev/action", running: true, panes: 2 },
  { name: "blink", path: "~/dev/blink", running: false },
  { name: "scout", path: "~/dev/scout", running: false },
];

export interface BLayer {
  label: string;
  running: number;
  total: number;
  active: boolean;
}

export const B_LAYERS: BLayer[] = [
  { label: "Dev", running: 3, total: 3, active: true },
  { label: "Review", running: 1, total: 2, active: false },
  { label: "Writing", running: 0, total: 2, active: false },
];

/** The last things the bar did — the one browse section BrowseMenu doesn't build yet. */
export const B_RECENT: { what: string; when: string; icon: BIconName }[] = [
  { what: "Tiled Chrome left", when: "2m", icon: "tileLeft" },
  { what: "Attached lattices", when: "14m", icon: "play" },
  { what: "Scanned screen", when: "40s", icon: "scan" },
];

/* ── Placement ─────────────────────────────────────────────── */

/** Cells of the 3×3 glyph a placement lights, row-major from top-left. */
export type BPlace = "left" | "right" | "top" | "bottom" | "max" | "tl" | "tr" | "bl" | "br" | "center";

export const PLACE_CELLS: Record<BPlace, number[]> = {
  left: [0, 3, 6],
  right: [2, 5, 8],
  top: [0, 1, 2],
  bottom: [6, 7, 8],
  max: [0, 1, 2, 3, 4, 5, 6, 7, 8],
  tl: [0],
  tr: [2],
  bl: [6],
  br: [8],
  center: [4],
};

export const NINE: { place: BPlace; label: string }[] = [
  { place: "tl", label: "Top left" },
  { place: "top", label: "Top" },
  { place: "tr", label: "Top right" },
  { place: "left", label: "Left" },
  { place: "center", label: "Center" },
  { place: "right", label: "Right" },
  { place: "bl", label: "Bottom left" },
  { place: "bottom", label: "Bottom" },
  { place: "br", label: "Bottom right" },
];

/** The 3×3 mini glyph: which cells a placement would fill. */
export function PlaceGlyph({ place, className = "" }: { place?: BPlace; className?: string }) {
  const hot = place ? PLACE_CELLS[place] : [];
  return (
    <span className={`bs-glyph ${className}`} aria-hidden="true">
      {Array.from({ length: 9 }, (_, i) => (
        <i key={i} className={hot.includes(i) ? "bs-hot" : undefined} />
      ))}
    </span>
  );
}

/* ── Chrome ────────────────────────────────────────────────── */

export type BTab = "home" | "desktop" | "assistant" | "runs" | "log";

export const B_TABS: { id: BTab; label: string; icon: IconName; badge?: number }[] = [
  { id: "home", label: "Home", icon: "home" },
  { id: "desktop", label: "Desktop", icon: "windows" },
  { id: "assistant", label: "Assistant", icon: "assistant" },
  { id: "runs", label: "Runs", icon: "runs" },
  { id: "log", label: "Log", icon: "activity", badge: 1 },
];

/**
 * The unified toolbar: traffic lights, the five tabs, this page's actions,
 * and the two ambient controls. There is no sidebar and no status bar.
 */
export function BToolbar({
  tab,
  actions,
  compact = false,
  folded = false,
}: {
  tab: BTab;
  actions?: ReactNode;
  /** Glyph tabs — the narrow-window fallback. */
  compact?: boolean;
  /** Page actions collapsed into one overflow control. */
  folded?: boolean;
}) {
  return (
    <div className={`bs-toolbar${compact ? " bs-toolbar--compact" : ""}`}>
      <span className="bs-lights">
        <i />
        <i />
        <i />
      </span>

      <nav className="bs-tabs" aria-label="Pages">
        {B_TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            className="bs-tab"
            aria-current={t.id === tab ? "page" : undefined}
            title={compact ? t.label : undefined}
          >
            <BI name={t.icon} />
            <span className="bs-tab__label">{t.label}</span>
            {t.badge ? <span className="bs-tab__badge">{t.badge}</span> : null}
          </button>
        ))}
      </nav>

      <span className="bs-spacer" />

      {folded ? (
        <BIconBtn name="more" label="More" />
      ) : (
        actions
      )}

      <span className="bs-ambient" title="Daemon · :9399" />
      <BIconBtn name="gear" label="Settings" />
    </div>
  );
}

export function BWindow({
  tab,
  actions,
  children,
  className = "",
  style,
}: {
  tab: BTab;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <div className={`bs ${className}`} style={style}>
      <BToolbar tab={tab} actions={actions} />
      <div className="bs-page">{children}</div>
    </div>
  );
}

export function BBtn({
  icon,
  children,
  primary = false,
  trailing,
}: {
  icon?: BIconName;
  children: ReactNode;
  primary?: boolean;
  trailing?: ReactNode;
}) {
  return (
    <button type="button" className={`bs-btn${primary ? " bs-btn--primary" : ""}`}>
      {icon ? <BI name={icon} /> : null}
      {children}
      {trailing}
    </button>
  );
}

export function BIconBtn({ name, label }: { name: BIconName; label: string }) {
  return (
    <button type="button" className="bs-icobtn" title={label} aria-label={label}>
      <BI name={name} />
    </button>
  );
}

export function BKbd({ children }: { children: ReactNode }) {
  return <span className="bs-kbd">{children}</span>;
}

/** Two-way switch, like Finder's view control. */
export function BSeg({ options, value }: { options: { id: string; icon: BIconName; label: string }[]; value: string }) {
  return (
    <span className="bs-seg" role="group">
      {options.map((o) => (
        <button
          key={o.id}
          type="button"
          aria-pressed={o.id === value}
          title={o.label}
          aria-label={o.label}
        >
          <BI name={o.icon} />
        </button>
      ))}
    </span>
  );
}

export function BAppIcon({ app, size = 18 }: { app: BAppKey; size?: number }) {
  return (
    <span
      className="bs-appicon"
      style={{ background: B_APPS[app].fill, width: size, height: size, fontSize: size / 2 }}
    >
      {B_APPS[app].letter}
    </span>
  );
}

/** Section head: a word and, when there is one, its count. Nothing else. */
export function BSec({ title, count }: { title: string; count?: number | string }) {
  return (
    <div className="bs-sec">
      <h3 className="bs-sec__title">{title}</h3>
      {count !== undefined ? <span className="bs-sec__n">{count}</span> : null}
    </div>
  );
}
