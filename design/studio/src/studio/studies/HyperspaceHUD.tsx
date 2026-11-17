"use client";

/**
 * Hyperspace HUD — the self-review fixes, drawn before the Swift moves.
 *
 * Every size here is the AppKit size in points (1 CSS px = 1 pt), taken from
 * HyperspaceDesktopHUD.swift / HyperspaceLens.swift. "Today" is the build that
 * ships now; "Proposed" turns each fix on or off on its own so one can be
 * judged against the others.
 */

import { createContext, useContext, useState, type CSSProperties, type ReactNode } from "react";
import { AppWindow, Ellipsis, EyeOff, Globe, Grid2x2, Layers, LayoutGrid, Map as MapIcon, Sparkles, SquareTerminal, StickyNote } from "lucide-react";
import type { LatticesPage } from "@/studio/studioRegistry";

// ── Lens tokens ─────────────────────────────────────────────────────────
const CORAL = "#ef6a47";
const CORAL_TOP = "#f78a65";
const CORAL_BOT = "#e4552e";
const INK = "#101518";
const MUTED = "#6a7078";
const ICON = "#5b6168";
const rim = (a: number) => `rgba(20,24,44,${a})`;
const ink = (a: number) => `rgba(16,21,24,${a})`;
const coral = (a: number) => `rgba(239,106,71,${a})`;
const white = (a: number) => `rgba(255,255,255,${a})`;
const FONT = '-apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif';
const MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

/**
 * "lens" is the build as shipped; "precise" is the squared, single-ink rework.
 * "ruled" is one hairline-cut strip; "ghost" drops the panel and lets the
 * windows carry the state. Tone "graphite" is the dark app-icon tile.
 */
type Skin = "lens" | "precise" | "ruled" | "ghost";
type Tone = "light" | "graphite";
type Look = { skin: Skin; tone: Tone };
const SkinCtx = createContext<Look>({ skin: "lens", tone: "light" });
const usePrecise = () => useContext(SkinCtx).skin !== "lens";
/** Ruled folds to one line until there is a selection to lay out. */
const FoldCtx = createContext(false);
const useFold = () => useContext(FoldCtx);
const paper = (a: number) => `rgba(242,242,242,${a})`;

/** Tokens for every non-lens skin, light or graphite. */
function useT() {
  const { skin, tone } = useContext(SkinCtx);
  const dark = skin === "ghost" || (skin !== "lens" && tone === "graphite");
  return {
    skin,
    dark,
    ruled: skin === "ruled",
    ghost: skin === "ghost",
    fg: dark ? paper : ink,
    raise: (a: number) => (dark ? `rgba(255,255,255,${(a * 0.16).toFixed(3)})` : white(a)),
    hair: (a: number) => (dark ? `rgba(255,255,255,${(a * 0.55).toFixed(3)})` : rim(a)),
    r: skin === "ruled" ? 3 : skin === "ghost" ? 5 : 6,
    muted: dark ? paper(0.5) : MUTED,
  };
}

const LINE = 36;
const LEADING = 13;

// ── fixture ─────────────────────────────────────────────────────────────
type AppKind = "chrome" | "notes" | "rex";
type Win = { id: number; app: AppKind; appName: string; title: string; frame: [number, number, number, number] };

const WINDOWS: Win[] = [
  { id: 1, app: "chrome", appName: "Chrome", title: "Lattices — Workspace", frame: [0.02, 0.04, 0.5, 0.6] },
  { id: 2, app: "chrome", appName: "Chrome", title: "Material reference", frame: [0.3, 0.12, 0.45, 0.55] },
  { id: 3, app: "rex", appName: "Rex", title: "lattices · swift build", frame: [0.55, 0.45, 0.42, 0.5] },
  { id: 4, app: "rex", appName: "Rex", title: "Design notes", frame: [0.08, 0.55, 0.35, 0.4] },
  { id: 5, app: "notes", appName: "Notes", title: "This week's ideas", frame: [0.7, 0.06, 0.28, 0.35] },
  { id: 6, app: "notes", appName: "Notes", title: "Window arrangements", frame: [0.62, 0.3, 0.3, 0.3] },
];
const GROUPS = [
  { name: "Chrome", app: "chrome" as AppKind, wids: [1, 2] },
  { name: "Notes", app: "notes" as AppKind, wids: [5, 6] },
  { name: "Rex", app: "rex" as AppKind, wids: [3, 4] },
];

type Shape = "columns" | "mainLeft" | "mainRight" | "rows";
const LAYOUTS: { key: Shape; name: string }[] = [
  { key: "columns", name: "Columns" },
  { key: "mainLeft", name: "Main left" },
  { key: "mainRight", name: "Main right" },
  { key: "rows", name: "Rows" },
];
/** Unit rects, slot order: index 0 is the main window. */
const SHAPES: Record<Shape, [number, number, number, number][]> = {
  columns: [[0, 0, 1 / 3, 1], [1 / 3, 0, 1 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
  mainLeft: [[0, 0, 0.6, 1], [0.6, 0, 0.4, 0.5], [0.6, 0.5, 0.4, 0.5]],
  mainRight: [[0.4, 0, 0.6, 1], [0, 0, 0.4, 0.5], [0, 0.5, 0.4, 0.5]],
  rows: [[0, 0, 1, 1 / 3], [0, 1 / 3, 1, 1 / 3], [0, 2 / 3, 1, 1 / 3]],
};

// ── options ─────────────────────────────────────────────────────────────
type Opts = {
  chipSelect: "badge+border" | "badge";
  map: "solid" | "main";
  titleCap: 116 | 168;
  overview: "empty" | "one-line" | "layouts";
  preview: "current" | "slim";
  skin: Skin;
  tone: Tone;
};
const TODAY: Opts = { chipSelect: "badge+border", map: "solid", titleCap: 116, overview: "empty", preview: "current", skin: "lens", tone: "light" };
const PROPOSED: Opts = { chipSelect: "badge", map: "main", titleCap: 168, overview: "one-line", preview: "slim", skin: "ruled", tone: "graphite" };

type Scene = "empty" | "selected" | "overview" | "hover";
const SCENES: { key: Scene; label: string }[] = [
  { key: "empty", label: "Nothing selected" },
  { key: "selected", label: "Three selected" },
  { key: "hover", label: "Hover, no preview" },
  { key: "overview", label: "Overview" },
];

type Model = {
  scene: Scene;
  slots: Record<number, number>;
  layout: Shape | null;
  hovered: number | null;
};

function model(scene: Scene): Model {
  const picked: Record<number, number> = scene === "empty" ? {} : { 1: 1, 2: 2, 3: 3 };
  return {
    scene,
    slots: picked,
    layout: scene === "empty" ? null : "mainLeft",
    hovered: scene === "hover" ? 6 : null,
  };
}

// ── atoms ───────────────────────────────────────────────────────────────
function AppIcon({ app, size = 16 }: { app: AppKind; size?: number }) {
  const t = useT();
  if (usePrecise()) {
    const G = app === "chrome" ? Globe : app === "notes" ? StickyNote : SquareTerminal;
    return <G size={size - 3} strokeWidth={1.3} color={t.fg(0.5)} style={{ flex: "none" }} />;
  }
  if (app === "chrome")
    return (
      <span style={{ width: size, height: size, borderRadius: "50%", flex: "none", position: "relative",
        background: "conic-gradient(from -30deg, #ea4335 0 120deg, #fbbc04 0 240deg, #34a853 0)" }}>
        <span style={{ position: "absolute", inset: size * 0.27, borderRadius: "50%", background: "#4285f4", boxShadow: "0 0 0 1.5px #fff" }} />
      </span>
    );
  if (app === "notes")
    return (
      <span style={{ width: size, height: size, borderRadius: size * 0.24, flex: "none", overflow: "hidden",
        background: `linear-gradient(#f7c948 0 30%, #fffdf6 30%)`, boxShadow: `inset 0 0 0 0.5px ${ink(0.14)}` }} />
    );
  return (
    <span style={{ width: size, height: size, borderRadius: size * 0.24, flex: "none",
      background: "linear-gradient(135deg, #ff8fb1, #b06cff)", boxShadow: `inset 0 0 0 0.5px ${ink(0.12)}` }} />
  );
}

function Badge({ n }: { n: number }) {
  const t = useT();
  if (usePrecise())
    return (
      <span style={{ width: 13, flex: "none", textAlign: "center", color: n === 1 ? CORAL : t.fg(0.5), font: `500 10.5px/13px ${MONO}` }}>
        {n}
      </span>
    );
  return (
    <span style={{ position: "absolute", left: 8 + 16 - 11 + 4, bottom: (28 - 16) / 2 - 3, width: 11, height: 11, borderRadius: "50%",
      background: `linear-gradient(#f6875f, #e5562f)`, color: "#fff", font: `700 7.5px/11px ${FONT}`, textAlign: "center",
      boxShadow: "0 0 0 1px rgba(255,255,255,.9)" }}>
      {n}
    </span>
  );
}

function Mark() {
  const precise = usePrecise();
  const t = useT();
  return (
    <span style={{ display: "grid", gridTemplateColumns: "repeat(3, 3.4px)", gap: 1.4, flex: "none" }}>
      {Array.from({ length: 9 }, (_, i) => (
        <span key={i} style={{ width: 3.4, height: 3.4, borderRadius: precise ? 0.6 : 0.9, background: precise ? t.fg(0.55) : ink(0.82) }} />
      ))}
    </span>
  );
}

function Sep() {
  const t = useT();
  if (t.ruled) return <span style={{ width: 0.5, alignSelf: "stretch", flex: "none", margin: "0 6px", background: t.hair(0.16) }} />;
  if (usePrecise()) return <span style={{ width: 0.5, height: 14, flex: "none", margin: "0 2px", background: t.hair(0.14) }} />;
  return (
    <span style={{ width: 0.5, height: 16, flex: "none", margin: "0 2px",
      background: `linear-gradient(${rim(0)}, ${rim(0.22)}, ${rim(0)})` }} />
  );
}

function Chip({ app, name, detail, slot, selected, cap, opts }: {
  app: AppKind; name: string; detail?: string; slot?: number; selected: boolean; cap: number; opts: Opts;
}) {
  const border = selected && opts.chipSelect === "badge+border" ? `inset 0 0 0 0.5px ${coral(0.7)}` : "none";
  const t = useT();
  if (usePrecise()) {
    // Ruled has one line to share: unselected windows collapse to their icon.
    const fold = useFold();
    const compact = t.ruled && fold && !selected && !detail;
    const raised = selected && t.skin === "precise";
    return (
      <span className="hud-hover" title={name} style={{ height: 24, borderRadius: t.r, display: "flex", alignItems: "center",
        padding: compact ? "0 5px" : "0 8px 0 7px", gap: 6, flex: t.ruled && fold && selected ? "0 1 auto" : "none", minWidth: t.ruled && fold ? 44 : undefined,
        background: raised ? t.raise(0.55) : "transparent" }}>
        {slot ? <Badge n={slot} /> : <AppIcon app={app} />}
        {compact ? null : (
          <span style={{ font: `${selected ? 500 : 400} 12px/15px ${FONT}`, color: t.fg(selected ? 0.9 : 0.66), maxWidth: t.ruled && fold ? 120 : cap, minWidth: 0,
            whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {name}
          </span>
        )}
        {detail ? <span style={{ font: `400 10.5px/14px ${MONO}`, color: t.muted }}>{detail}</span> : null}
      </span>
    );
  }
  return (
    <span className="hud-hover" style={{ position: "relative", height: 28, borderRadius: 14, display: "flex", alignItems: "center",
      padding: "0 10px 0 8px", gap: 6, flex: "none", background: selected ? white(0.86) : "transparent", boxShadow: border }}>
      <AppIcon app={app} />
      <span style={{ font: `500 12px/15px ${FONT}`, color: INK, maxWidth: cap, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
        {name}
      </span>
      {detail ? <span style={{ font: `400 11px/14px ${FONT}`, color: MUTED, marginLeft: -1 }}>{detail}</span> : null}
      {slot ? <Badge n={slot} /> : null}
    </span>
  );
}

function Mini({ shape, live, selected }: { shape: Shape; live: boolean; selected: boolean }) {
  const t = useT();
  if (usePrecise())
    return (
      <span style={{ position: "relative", width: 22, height: 14, flex: "none", borderRadius: t.ruled ? 1.5 : 2.5, boxShadow: `inset 0 0 0 0.5px ${t.fg(selected ? 0.36 : 0.22)}` }}>
        {SHAPES[shape].map(([x, y, w, h], i) => (
          <span key={i} style={{ position: "absolute", left: `calc(${x * 100}% + 1.5px)`, top: `calc(${y * 100}% + 1.5px)`,
            width: `calc(${w * 100}% - 3px)`, height: `calc(${h * 100}% - 3px)`, borderRadius: t.ruled ? 0.5 : 1,
            background: i === 0 && live && selected ? coral(0.85) : t.fg(selected ? 0.3 : 0.15) }} />
        ))}
      </span>
    );
  return (
    <span style={{ position: "relative", width: 24, height: 15, borderRadius: 3, flex: "none", background: ink(0.05),
      boxShadow: `inset 0 0 0 0.5px ${ink(0.16)}` }}>
      {SHAPES[shape].map(([x, y, w, h], i) => (
        <span key={i} style={{ position: "absolute", left: `calc(${x * 100}% + 1px)`, top: `calc(${y * 100}% + 1px)`,
          width: `calc(${w * 100}% - 2px)`, height: `calc(${h * 100}% - 2px)`, borderRadius: 1.2,
          background: i === 0 && live ? coral(selected ? 1 : 0.7) : ink(selected ? 0.42 : 0.26) }} />
      ))}
    </span>
  );
}

function LayoutItem({ shape, name, live, selected }: { shape: Shape; name: string; live: boolean; selected: boolean }) {
  const t = useT();
  if (usePrecise()) {
    // Ruled and ghost mark the chosen layout with a coral rule, not a fill;
    // ruled names only the chosen one.
    const rule = selected && (t.ruled || t.ghost);
    const named = !t.ruled || !useFold() || selected;
    return (
      <span className="hud-hover" title={name} style={{ height: 24, borderRadius: t.r, display: "flex", alignItems: "center", gap: 6,
        padding: named ? "0 8px 0 5px" : "0 5px", flex: "none", opacity: live ? 1 : 0.45,
        background: selected && t.skin === "precise" ? t.raise(0.55) : "transparent",
        boxShadow: rule ? `inset 0 -1.5px 0 ${CORAL}` : "none" }}>
        <Mini shape={shape} live={live} selected={selected} />
        {named ? <span style={{ font: `${selected ? 500 : 400} 11.5px/14px ${FONT}`, color: t.fg(selected ? 0.9 : 0.66), whiteSpace: "nowrap" }}>{name}</span> : null}
      </span>
    );
  }
  return (
    <span className="hud-hover" style={{ height: 26, borderRadius: 13, display: "flex", alignItems: "center", gap: 6,
      padding: "0 9px 0 5px", flex: "none", opacity: live ? 1 : 0.45,
      background: selected ? white(0.86) : "transparent", boxShadow: selected ? `inset 0 0 0 0.5px ${coral(0.7)}` : "none" }}>
      <Mini shape={shape} live={live} selected={selected} />
      <span style={{ font: `500 11px/14px ${FONT}`, color: INK, whiteSpace: "nowrap" }}>{name}</span>
    </span>
  );
}

function MapWell({ m, opts }: { m: Model; opts: Opts }) {
  const precise = usePrecise();
  const t = useT();
  return (
    <span style={{ position: "relative", width: 34, height: 20, borderRadius: precise ? 2.5 : 3, flex: "none", background: precise ? "transparent" : ink(0.05),
      boxShadow: `inset 0 0 0 0.5px ${precise ? t.fg(0.22) : ink(0.16)}`, margin: "0 3px" }}>
      {[...WINDOWS].sort((a, b) => (m.slots[a.id] ?? 0) - (m.slots[b.id] ?? 0)).map((w) => {
        const slot = m.slots[w.id];
        const fill = precise && t.dark
          ? slot == null ? "#2a3035" : slot === 1 ? "#f08c6f" : "#7d838a"
          : precise
          ? slot == null ? "#e4e6e8" : slot === 1 ? "#f08c6f" : "#a9aeb3"
          : slot == null ? ink(0.16) : opts.map === "solid" ? coral(0.9) : slot === 1 ? coral(0.9) : coral(0.32);
        const [x, y, ww, hh] = w.frame;
        return (
          <span key={w.id} style={{ position: "absolute", left: `${x * 100}%`, top: `${y * 100}%`, width: `${ww * 100}%`,
            height: `${hh * 100}%`, borderRadius: precise ? 0.5 : 1, background: fill,
            boxShadow: slot == null ? "none" : `0 0 0 0.5px ${t.dark ? "#101518" : white(precise ? 0.9 : 0.6)}` }} />
        );
      })}
    </span>
  );
}

function Tool({ children, on = false }: { children: ReactNode; on?: boolean }) {
  const t = useT();
  if (usePrecise())
    return (
      <span className="hud-hover" style={{ width: 24, height: 24, borderRadius: t.r, display: "grid", placeItems: "center",
        color: t.fg(on ? 0.92 : 0.52), flex: "none", background: on ? t.fg(0.07) : "transparent" }}>
        {children}
      </span>
    );
  return (
    <span className="hud-hover" style={{ width: 28, height: 28, borderRadius: 14, display: "grid", placeItems: "center",
      color: on ? INK : ICON, flex: "none", background: on ? white(0.86) : "transparent" }}>
      {children}
    </span>
  );
}

function Segment({ overview }: { overview: boolean }) {
  const t = useT();
  if (usePrecise()) {
    const cell = (on: boolean): CSSProperties => ({
      width: 26, height: 20, borderRadius: t.ruled ? 2 : 5, display: "grid", placeItems: "center", color: t.fg(on ? 0.86 : 0.48),
      background: on ? (t.dark ? paper(0.14) : white(0.92)) : "transparent",
      boxShadow: on && !t.dark ? `0 0.5px 1px ${rim(0.12)}, 0 0 0 0.5px ${rim(0.08)}` : "none",
    });
    return (
      <span style={{ display: "flex", padding: 1, borderRadius: t.ruled ? 3 : 6, background: t.fg(0.06), flex: "none" }}>
        <span style={cell(!overview)}><AppWindow size={13} strokeWidth={1.4} /></span>
        <span style={cell(overview)}><LayoutGrid size={13} strokeWidth={1.4} /></span>
      </span>
    );
  }
  const pebble = (on: boolean): CSSProperties => ({
    width: 28, height: 24, borderRadius: 12, display: "grid", placeItems: "center", color: on ? INK : ICON,
    background: on ? white(0.95) : "transparent", boxShadow: on ? `0 1px 2px ${rim(0.14)}, 0 0 0 0.5px ${rim(0.08)}` : "none",
  });
  return (
    <span style={{ display: "flex", padding: 2, borderRadius: 14, background: ink(0.06), flex: "none" }}>
      <span style={pebble(!overview)}><AppWindow size={14} strokeWidth={1.6} /></span>
      <span style={pebble(overview)}><LayoutGrid size={14} strokeWidth={1.6} /></span>
    </span>
  );
}

function Actions({ ready }: { ready: boolean }) {
  const t = useT();
  // The new surfaces commit with flat coral and ink text; Done stays a hairline.
  const fold = useFold();
  if (t.ruled || t.ghost || t.dark)
    return (
      <>
        {ready && !(t.ruled && fold) ? (
          <span className="hud-hover" style={{ height: 24, borderRadius: t.r, padding: "0 8px", display: "grid", placeItems: "center",
            font: `400 12px/15px ${FONT}`, color: t.fg(0.6), flex: "none" }}>Cancel</span>
        ) : null}
        <span style={{ height: 24, minWidth: 54, borderRadius: t.r, padding: "0 12px", display: "grid", placeItems: "center", flex: "none",
          font: `${ready ? 600 : 500} 12px/15px ${FONT}`, color: ready ? INK : t.fg(0.72), background: ready ? CORAL : "transparent",
          boxShadow: ready ? "none" : `inset 0 0 0 0.5px ${t.hair(0.32)}` }}>
          {ready ? "Apply" : "Done"}
        </span>
      </>
    );
  if (usePrecise())
    return (
      <>
        {ready ? (
          <span className="hud-hover" style={{ height: 24, borderRadius: 6, padding: "0 8px", display: "grid", placeItems: "center",
            font: `400 12px/15px ${FONT}`, color: ink(0.55), flex: "none" }}>Cancel</span>
        ) : null}
        <span style={{ height: 24, minWidth: 54, borderRadius: 6, padding: "0 12px", display: "grid", placeItems: "center", flex: "none",
          font: `500 12px/15px ${FONT}`, color: ink(ready ? 0.86 : 0.6), background: white(ready ? 0.92 : 0.4),
          boxShadow: `0 0.5px 1px ${rim(ready ? 0.14 : 0.06)}, 0 0 0 0.5px ${rim(ready ? 0.12 : 0.1)}` }}>
          {ready ? "Apply" : "Done"}
        </span>
      </>
    );
  return (
    <>
      {ready ? (
        <span className="hud-hover" style={{ height: 28, borderRadius: 14, padding: "0 10px", display: "grid", placeItems: "center",
          font: `400 12px/15px ${FONT}`, color: INK, flex: "none" }}>Cancel</span>
      ) : null}
      <span style={{ height: 28, minWidth: 58, borderRadius: 14, padding: "0 14px", display: "grid", placeItems: "center", flex: "none",
        font: `600 12px/15px ${FONT}`, color: "#fff",
        background: ready ? `linear-gradient(${CORAL_TOP}, ${CORAL_BOT})` : `linear-gradient(#2c3238, #0f1317)`,
        boxShadow: `inset 0 0.5px 0 ${white(0.35)}, 0 1px 2px ${rim(0.18)}` }}>
        {ready ? "Apply" : "Done"}
      </span>
    </>
  );
}

function RightCluster({ m, opts, overview }: { m: Model; opts: Opts; overview: boolean }) {
  const precise = opts.skin !== "lens";
  const ic = precise ? 13 : 14;
  const sw = precise ? 1.4 : 1.6;
  return (
    <span style={{ display: "flex", alignItems: "center", gap: 2, flex: "none" }}>
      <MapWell m={m} opts={opts} />
      <Sep />
      <Segment overview={overview} />
      <Tool><Layers size={ic} strokeWidth={sw} /></Tool>
      <Tool><Grid2x2 size={ic} strokeWidth={sw} /></Tool>
      <Tool><MapIcon size={ic} strokeWidth={sw} /></Tool>
      <Tool><Ellipsis size={ic} strokeWidth={sw} /></Tool>
      <span style={{ width: precise ? 4 : 2 }} />
      <Actions ready={m.layout != null || overview} />
    </span>
  );
}

/** `surface` keeps a panel under ghost, for the hover preview. */
function Glass({ children, radius = 16, style, surface = false }: { children: ReactNode; radius?: number; style?: CSSProperties; surface?: boolean }) {
  const t = useT();
  if (t.ghost && !surface)
    return <div style={{ position: "relative", filter: "drop-shadow(0 1px 1.5px rgba(0,0,0,.45))", ...style }}>{children}</div>;
  if (usePrecise()) {
    const light = t.ruled
      ? `0 0 0 0.5px ${rim(0.18)}, 0 6px 18px -12px ${rim(0.32)}`
      : `0 0 0 0.5px ${rim(0.16)}, inset 0 0.5px 0 ${white(0.7)}, 0 12px 32px -18px ${rim(0.35)}`;
    const dark = `0 0 0 0.5px rgba(255,255,255,.08), inset 0 0.5px 0 rgba(255,255,255,.06), 0 12px 32px -16px rgba(0,0,0,.55)`;
    return (
      <div style={{ position: "relative", borderRadius: t.ruled ? 4 : 12, overflow: "hidden",
        backdropFilter: "blur(30px) saturate(1.4)", WebkitBackdropFilter: "blur(30px) saturate(1.4)",
        background: t.dark ? "rgba(16,21,24,0.82)" : white(t.ruled ? 0.76 : 0.62), boxShadow: t.dark ? dark : light, ...style }}>
        {children}
      </div>
    );
  }
  return (
    <div style={{ position: "relative", borderRadius: radius, overflow: "hidden",
      backdropFilter: "blur(26px) saturate(1.7)", WebkitBackdropFilter: "blur(26px) saturate(1.7)",
      background: `linear-gradient(${white(0.66)}, ${white(0.42)})`,
      boxShadow: `0 0 0 0.5px ${rim(0.2)}, 0 18px 40px -14px ${rim(0.28)}, 0 2px 6px ${rim(0.08)}`, ...style }}>
      <div aria-hidden style={{ position: "absolute", inset: 0, pointerEvents: "none",
        background: `linear-gradient(${white(0.36)}, ${white(0)} 48%)` }} />
      <div aria-hidden style={{ position: "absolute", inset: 0, borderRadius: radius, pointerEvents: "none", padding: 1,
        background: `linear-gradient(155deg, #fff, ${white(0.2)} 38%, ${white(0.05)} 62%, ${white(0.75)})`,
        WebkitMask: "linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)", WebkitMaskComposite: "xor",
        maskComposite: "exclude" }} />
      <div style={{ position: "relative" }}>{children}</div>
    </div>
  );
}

// ── the HUD ─────────────────────────────────────────────────────────────
function HUD({ m, opts }: { m: Model; opts: Opts }) {
  const t = useT();
  const precise = opts.skin !== "lens";
  const overview = m.scene === "overview";
  const selCount = Object.keys(m.slots).length;
  const live = selCount >= 2;
  const fold = !(selCount > 0 && !overview);

  const top = overview
    ? GROUPS.map((g) => {
        const n = g.wids.filter((w) => m.slots[w]).length;
        return <Chip key={g.name} app={g.app} name={g.name} detail={n > 0 && n < g.wids.length ? `${n}/${g.wids.length}` : `${g.wids.length}`}
          selected={n === g.wids.length} cap={opts.titleCap} opts={opts} />;
      })
    : WINDOWS.map((w) => (
        <Chip key={w.id} app={w.app} name={w.title} slot={m.slots[w.id]} selected={m.slots[w.id] != null} cap={opts.titleCap} opts={opts} />
      ));

  const layouts = (
    <span style={{ display: "flex", alignItems: "center", gap: 2, marginLeft: -4 }}>
      {LAYOUTS.map((l) => (
        <LayoutItem key={l.key} shape={l.key} name={l.name} live={live} selected={live && m.layout === l.key} />
      ))}
      {live ? (
        <>
          <Sep />
          {t.ruled && fold ? (
            <span className="hud-hover" title="Suggested" style={{ width: 24, height: 24, borderRadius: t.r, display: "grid", placeItems: "center", color: t.fg(0.6) }}>
              <Sparkles size={13} strokeWidth={1.4} />
            </span>
          ) : precise ? (
            <span className="hud-hover" style={{ height: 24, borderRadius: 6, display: "flex", alignItems: "center", padding: "0 8px",
              font: `400 11.5px/14px ${FONT}`, color: t.fg(0.66) }}>
              Suggested
            </span>
          ) : (
            <span className="hud-hover" style={{ height: 26, borderRadius: 13, display: "flex", alignItems: "center", gap: 5, padding: "0 9px 0 7px",
              font: `500 11px/14px ${FONT}`, color: INK }}>
              <Sparkles size={11} strokeWidth={1.8} color={CORAL} /> Suggested
            </span>
          )}
        </>
      ) : null}
    </span>
  );

  if (opts.skin === "ruled" && selCount > 0 && !overview) {
    return (
      <Glass>
        <div style={{ height: 32, display: "flex", alignItems: "center", gap: 2, padding: "0 12px" }}>
          <Mark />
          <Sep />
          <span style={{ display: "flex", gap: 1, minWidth: 0, overflow: "hidden" }}>{top}</span>
        </div>
        <div style={{ height: 0.5, background: t.hair(0.16) }} />
        <div style={{ height: 32, display: "flex", alignItems: "center", gap: 2, padding: "0 4px 0 12px" }}>
          {layouts}
          <span style={{ flex: 1, minWidth: 8 }} />
          <Sep />
          <RightCluster m={m} opts={opts} overview={overview} />
        </div>
      </Glass>
    );
  }

  if (opts.skin === "ruled") {
    return (
      <FoldCtx.Provider value>
      <Glass>
        <div style={{ height: 32, display: "flex", alignItems: "center", gap: 2, padding: "0 4px 0 12px" }}>
          <Mark />
          <Sep />
          <span style={{ display: "flex", gap: 1, minWidth: 0, flex: "0 1 auto" }}>{top}</span>
          {!overview || opts.overview === "layouts" ? (<><Sep />{layouts}</>) : null}
          <span style={{ flex: 1, minWidth: 8 }} />
          <Sep />
          <RightCluster m={m} opts={opts} overview={overview} />
        </div>
      </Glass>
      </FoldCtx.Provider>
    );
  }

  if (overview && opts.overview === "one-line") {
    return (
      <Glass>
        <div style={{ height: LINE, display: "flex", alignItems: "center", gap: 8, padding: `0 4px 0 ${LEADING}px` }}>
          <Mark />
          <Sep />
          <span style={{ display: "flex", gap: precise ? 2 : 4 }}>{top}</span>
          <span style={{ flex: 1, minWidth: 24 }} />
          <RightCluster m={m} opts={opts} overview />
        </div>
      </Glass>
    );
  }

  return (
    <Glass>
      <div style={{ height: LINE, display: "flex", alignItems: "center", gap: 8, padding: `0 ${LEADING}px` }}>
        <Mark />
        <Sep />
        <span style={{ display: "flex", gap: precise ? 2 : 4, minWidth: 0, overflow: "hidden" }}>{top}</span>
      </div>
      <div style={{ height: 0.5, margin: precise ? 0 : `0 ${LEADING}px`, background: precise ? t.hair(0.1) : rim(0.16) }} />
      <div style={{ height: LINE, display: "flex", alignItems: "center", gap: 8, padding: `0 4px 0 ${LEADING}px` }}>
        {!overview || opts.overview === "layouts" ? layouts : null}
        <span style={{ flex: 1 }} />
        <RightCluster m={m} opts={opts} overview={overview} />
      </div>
    </Glass>
  );
}

// ── hover preview ───────────────────────────────────────────────────────
function Preview({ win, opts }: { win: Win; opts: Opts }) {
  const t = useT();
  const lens = opts.skin === "lens";
  if (opts.preview === "current") {
    return (
      <Glass radius={18} style={{ width: 322 }}>
        <div style={{ padding: "12px 12px 14px" }}>
          <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between" }}>
            <div>
              <div style={{ font: `500 13px/17px ${FONT}`, color: INK }}>Unavailable window preview</div>
              <div style={{ font: `400 12px/16px ${FONT}`, color: MUTED, marginTop: 2 }}>{win.appName}</div>
            </div>
            <span style={{ font: `500 12px/15px ${FONT}`, color: CORAL, padding: "5px 10px", borderRadius: 12, background: white(0.3) }}>Select</span>
          </div>
          <div style={{ marginTop: 12, height: 168, borderRadius: 12, background: white(0.18), boxShadow: `inset 0 0 0 0.5px ${rim(0.1)}`,
            display: "grid", placeItems: "center", textAlign: "center" }}>
            <div style={{ color: ink(0.35), font: `400 11px/15px ui-monospace, Menlo, monospace` }}>
              <EyeOff size={16} strokeWidth={1.4} style={{ margin: "0 auto 8px" }} />
              Preview unavailable
              <div style={{ fontSize: 9, marginTop: 4 }}>{win.appName}</div>
            </div>
          </div>
        </div>
      </Glass>
    );
  }
  return (
    <Glass surface style={{ width: 264 }}>
      <div style={{ padding: 6 }}>
        <div style={{ height: 26, display: "flex", alignItems: "center", gap: 6, padding: "0 4px 0 6px" }}>
          <AppIcon app={win.app} size={13} />
          <span style={{ font: `500 12px/15px ${FONT}`, color: lens ? INK : t.fg(0.9), whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{win.title}</span>
          <span style={{ flex: 1 }} />
          <span style={{ font: `500 11px/14px ${FONT}`, color: lens ? CORAL : t.fg(0.9), padding: "0 4px" }}>Select</span>
        </div>
        <div style={{ height: 150, borderRadius: lens ? 10 : t.ruled ? 2 : 6, background: lens ? ink(0.04) : t.fg(0.05), boxShadow: `inset 0 0 0 0.5px ${lens ? ink(0.1) : t.fg(0.1)}`,
          display: "flex", alignItems: "center", justifyContent: "center", gap: 6, color: lens ? ink(0.38) : t.fg(0.42), font: `400 11px/14px ${FONT}` }}>
          <EyeOff size={12} strokeWidth={1.5} /> No preview
        </div>
      </div>
    </Glass>
  );
}

// ── ghost desktop ───────────────────────────────────────────────────────
/** Ghost has no panel, so the windows say what is selected and where it goes. */
function GhostDesk({ m }: { m: Model }) {
  const A = { x: 24, y: 18, w: 952, h: 250 };
  const at = ([x, y, w, h]: [number, number, number, number], inset = 0): CSSProperties => ({
    position: "absolute", left: A.x + x * A.w + inset, top: A.y + y * A.h + inset, width: w * A.w - inset * 2, height: h * A.h - inset * 2,
  });
  const picked = WINDOWS.filter((w) => m.slots[w.id] != null).sort((a, b) => m.slots[a.id] - m.slots[b.id]);
  return (
    <>
      <div aria-hidden style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 150,
        background: "linear-gradient(rgba(10,14,20,0), rgba(10,14,20,.46))" }} />
      {WINDOWS.map((w) => {
        const slot = m.slots[w.id];
        return (
          <div key={w.id} style={{ ...at(w.frame), borderRadius: 6, background: "rgba(255,255,255,.07)",
            boxShadow: slot ? `0 0 0 1px ${CORAL}` : "inset 0 0 0 0.5px rgba(255,255,255,.24)" }}>
            {slot ? (
              <span style={{ position: "absolute", left: 6, top: 5, padding: "0 5px", borderRadius: 3, background: "rgba(16,21,24,.82)",
                color: CORAL, font: `500 10.5px/15px ${MONO}` }}>{slot}</span>
            ) : null}
          </div>
        );
      })}
      {m.layout
        ? picked.map((w, i) => {
            const target = SHAPES[m.layout as Shape][i];
            return target ? (
              <div key={`t${w.id}`} style={{ ...at(target, 3), borderRadius: 6, border: "1px dashed rgba(255,255,255,.72)" }} />
            ) : null;
          })
        : null}
    </>
  );
}

// ── stage ───────────────────────────────────────────────────────────────
function Stage({ label, m, opts }: { label: string; m: Model; opts: Opts }) {
  const hovered = WINDOWS.find((w) => w.id === m.hovered);
  const dark = opts.skin === "ghost" || (opts.skin !== "lens" && opts.tone === "graphite");
  const hover = dark ? "skin-dark" : opts.skin === "ruled" ? "skin-ruled" : "";
  return (
    <SkinCtx.Provider value={{ skin: opts.skin, tone: opts.tone }}>
    <figure style={{ margin: 0 }} className={hover}>
      <figcaption className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint" style={{ marginBottom: 8 }}>{label}</figcaption>
      <div style={{ position: "relative", width: 1000, height: 400, overflow: "hidden", borderRadius: 6,
        background: "url(/hyperspace-hud/wallpaper.jpg) center bottom / 1440px auto, #5d7a95" }}>
        {opts.skin === "ghost" ? <GhostDesk m={m} /> : null}
        <div style={{ position: "absolute", left: 0, right: 0, bottom: 14, display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
          {hovered ? <Preview win={hovered} opts={opts} /> : null}
          <div style={{ maxWidth: 980 }}><HUD m={m} opts={opts} /></div>
        </div>
      </div>
    </figure>
    </SkinCtx.Provider>
  );
}

// ── controls ────────────────────────────────────────────────────────────
const SKIN_NOTES: Record<Skin, string> = {
  lens: "The glass capsule as shipped: pill controls, gradient coral, raised chips.",
  precise: "Soft 6pt controls, 12pt panel, ink glyphs. Coral only marks the main slot.",
  ruled: "One 32pt strip cut by full-height hairlines. Unselected windows fold to icons; the chosen layout gets a coral rule.",
  ghost: "No panel: type over a bottom scrim. The windows carry selection and their target frames; only Apply is solid.",
};

const GALLERY: { label: string; skin: Skin; tone: Tone }[] = [
  { label: "Precise", skin: "precise", tone: "light" },
  { label: "Graphite", skin: "precise", tone: "graphite" },
  { label: "Ruled", skin: "ruled", tone: "light" },
  { label: "Ruled · graphite", skin: "ruled", tone: "graphite" },
  { label: "Ghost", skin: "ghost", tone: "graphite" },
];
function Choice<T extends string | number>({ label, value, options, onChange, note }: {
  label: string; value: T; options: { v: T; t: string }[]; onChange: (v: T) => void; note: string;
}) {
  return (
    <div className="grid grid-cols-[150px_auto_1fr] items-center gap-4 py-2.5">
      <span className="text-[12.5px] font-medium text-studio-ink-strong">{label}</span>
      <span className="flex border border-studio-rule">
        {options.map((o) => (
          <button key={String(o.v)} type="button" onClick={() => onChange(o.v)}
            className={`px-2.5 py-1 font-mono text-[11px] transition-colors ${o.v === value ? "bg-studio-ink-strong text-studio-bg" : "text-studio-ink hover:bg-studio-chip-bg"}`}>
            {o.t}
          </button>
        ))}
      </span>
      <span className="text-[12px] leading-snug text-studio-ink-faint">{note}</span>
    </div>
  );
}

export function HyperspaceHUDStudy({ page }: { page: LatticesPage }) {
  const [scene, setScene] = useState<Scene>("hover");
  const [opts, setOpts] = useState<Opts>(PROPOSED);
  const set = <K extends keyof Opts>(k: K) => (v: Opts[K]) => setOpts((o) => ({ ...o, [k]: v }));
  const m = model(scene);

  return (
    <main className="w-full px-6 py-10 lg:px-7">
      <style>{`.hud-hover{transition:background .12s ease}.hud-hover:hover{background:${white(0.5)}!important}` +
        `.skin-dark .hud-hover:hover{background:rgba(255,255,255,.08)!important}.skin-ruled .hud-hover:hover{background:${ink(0.045)}!important}`}</style>
      <header className="max-w-[980px] border-b border-studio-rule pb-7">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">{page.bucket} / {page.surface}</div>
        <h1 className="mt-4 text-[36px] font-medium leading-tight text-studio-ink-strong">{page.label}</h1>
        {page.blurb ? <p className="mt-4 max-w-[66ch] text-[15px] leading-[1.7] text-studio-ink">{page.blurb}</p> : null}
      </header>

      <section className="py-6">
        <div className="flex flex-wrap gap-1.5">
          {SCENES.map((s) => (
            <button key={s.key} type="button" onClick={() => setScene(s.key)}
              className={`border px-3 py-1.5 text-[12px] transition-colors ${s.key === scene ? "border-studio-ink-strong text-studio-ink-strong" : "border-studio-rule text-studio-ink-faint hover:text-studio-ink"}`}>
              {s.label}
            </button>
          ))}
        </div>

        <div className="mt-5 divide-y divide-studio-rule border-y border-studio-rule max-w-[1000px]">
          <Choice label="Surface" value={opts.skin} onChange={set("skin")}
            options={[{ v: "lens", t: "lens" }, { v: "precise", t: "precise" }, { v: "ruled", t: "ruled" }, { v: "ghost", t: "ghost" }]}
            note={SKIN_NOTES[opts.skin]} />
          <Choice label="Tone" value={opts.tone} onChange={set("tone")}
            options={[{ v: "light", t: "light" }, { v: "graphite", t: "graphite" }]}
            note="Graphite is the dark icon tile: #101518 at 82%, #f2f2f2 type, 8% white hairline. Lens ignores it; ghost is always dark." />
          <Choice label="Chip selection" value={opts.chipSelect} onChange={set("chipSelect")}
            options={[{ v: "badge+border", t: "badge + border" }, { v: "badge", t: "badge" }]}
            note="The numbered badge already says selected and in what order." />
          <Choice label="Map tile" value={opts.map} onChange={set("map")}
            options={[{ v: "solid", t: "all coral" }, { v: "main", t: "main only" }]}
            note="Three coral windows fill the tile into one block." />
          <Choice label="Title width" value={opts.titleCap} onChange={set("titleCap")}
            options={[{ v: 116, t: "116pt" }, { v: 168, t: "168pt" }]}
            note="Room to spare, yet the titles cut off." />
          <Choice label="Overview HUD" value={opts.overview} onChange={set("overview")}
            options={[{ v: "empty", t: "two lines" }, { v: "one-line", t: "one line" }, { v: "layouts", t: "layouts here" }]}
            note="“layouts here” would let the HUD replace Overview's own layout stage." />
          <Choice label="Hover preview" value={opts.preview} onChange={set("preview")}
            options={[{ v: "current", t: "current" }, { v: "slim", t: "slim" }]}
            note="Same radius and hairlines as the HUD; one header line." />
        </div>
      </section>

      <section className="grid gap-8 pb-10" style={{ overflowX: "auto" }}>
        <Stage label="Today" m={m} opts={TODAY} />
        <Stage label="Proposed" m={m} opts={opts} />
      </section>

      <section className="grid gap-8 border-t border-studio-rule pt-8 pb-10" style={{ overflowX: "auto" }}>
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">Every surface, same scene and fixes</div>
        {GALLERY.map((g) => (
          <Stage key={g.label} label={g.label} m={m} opts={{ ...opts, skin: g.skin, tone: g.tone }} />
        ))}
      </section>
    </main>
  );
}
