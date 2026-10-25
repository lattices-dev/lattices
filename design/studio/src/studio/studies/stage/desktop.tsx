"use client";

/**
 * The fake desktop and the overlays the Stage system draws over it: windows,
 * the island, the suggestion card and the space switcher. One ink, one coral,
 * from the HUD language study (studies/hud-language-2026-10-17).
 */

import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import type { Rect } from "./layout";

// ── tokens ───────────────────────────────────────────────────────────────

export const INK = "rgba(16,21,24,0.86)"; // #101518 at 86%
export const KEYLINE = "rgba(255,255,255,0.12)";
export const CORAL = "#ef6a47";
export const TEXT = "rgba(255,255,255,0.92)";
export const TEXT2 = "rgba(255,255,255,0.5)";
export const BLOCK_FILL = "rgba(255,255,255,0.09)";
export const BLOCK_LINE = "rgba(255,255,255,0.24)";
const FONT = `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif`;

/** The simulated display, in points. Overlays are drawn at this size, then scaled. */
export const DISPLAY_W = 1440;
export const DISPLAY_H = 900;
const MENU_BAR = 24;
const PAD = 8;

// ── demo windows (an invented project, tideline) ─────────────────────────

export interface DemoWindow {
  app: string;
  title: string;
  tone: "light" | "dark";
  /** In the tideline layer — used by the "who joins" alternative. */
  layer: boolean;
  /** Where it sits before Stage moves it. */
  home: Rect;
  /** Not a Stage window: no title, or under 200×160. */
  utility?: boolean;
}

export const WINDOWS: DemoWindow[] = [
  { app: "Zed", title: "tideline — api/routes.ts", tone: "dark", layer: true, home: { x: 0.03, y: 0.05, w: 0.46, h: 0.58 } },
  { app: "Ghostty", title: "tideline · bun dev", tone: "dark", layer: true, home: { x: 0.3, y: 0.42, w: 0.4, h: 0.5 } },
  { app: "Chrome", title: "tideline.local:3000", tone: "light", layer: true, home: { x: 0.52, y: 0.04, w: 0.44, h: 0.6 } },
  { app: "Linear", title: "TID-214 Tide tables", tone: "dark", layer: true, home: { x: 0.09, y: 0.5, w: 0.34, h: 0.44 } },
  { app: "Notes", title: "Standup", tone: "light", layer: false, home: { x: 0.66, y: 0.5, w: 0.3, h: 0.42 } },
  { app: "Mail", title: "Inbox — 3 unread", tone: "light", layer: false, home: { x: 0.19, y: 0.16, w: 0.36, h: 0.44 } },
  { app: "Figma", title: "tideline / hero", tone: "dark", layer: false, home: { x: 0.57, y: 0.28, w: 0.38, h: 0.5 } },
];

export const PALETTE_WINDOW: DemoWindow = {
  app: "Color Meter",
  title: "",
  tone: "dark",
  layer: false,
  utility: true,
  home: { x: 0.855, y: 0.05, w: 0.115, h: 0.16 },
};

// ── desktop ──────────────────────────────────────────────────────────────

function useWidth<T extends HTMLElement>() {
  const [width, setWidth] = useState(DISPLAY_W);
  const observer = useRef<ResizeObserver | null>(null);
  // A callback ref measures the node as soon as it mounts, then follows it.
  const ref = useCallback((el: T | null) => {
    observer.current?.disconnect();
    observer.current = null;
    if (!el) return;
    setWidth(el.getBoundingClientRect().width || DISPLAY_W);
    const ro = new ResizeObserver(() => setWidth(el.getBoundingClientRect().width || DISPLAY_W));
    ro.observe(el);
    observer.current = ro;
  }, []);
  return [ref, width] as const;
}

/**
 * A display drawn to scale. `children` are windows placed in the visible frame
 * (unit rects); `overlay` is drawn in display points and scaled with it, never
 * below `minOverlayScale` so the type stays legible in small panels.
 */
export function Desktop({
  children,
  overlay,
  minOverlayScale = 0.62,
  grid,
}: {
  children?: ReactNode;
  overlay?: ReactNode;
  minOverlayScale?: number;
  /** Home cells drawn as faint outlines. */
  grid?: Rect[];
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const scale = width / DISPLAY_W;
  const overlayScale = Math.max(scale, minOverlayScale);

  return (
    <div
      ref={ref}
      style={{
        position: "relative",
        width: "100%",
        aspectRatio: `${DISPLAY_W} / ${DISPLAY_H}`,
        overflow: "hidden",
        borderRadius: 8,
        border: "1px solid rgba(255,255,255,0.08)",
        background:
          "radial-gradient(120% 90% at 20% 0%, #2a3640 0%, #161c22 45%, #0c0f12 100%)",
        fontFamily: FONT,
        userSelect: "none",
      }}
    >
      {/* menu bar */}
      <div
        style={{
          position: "absolute",
          inset: "0 0 auto 0",
          height: `${(MENU_BAR / DISPLAY_H) * 100}%`,
          background: "rgba(10,12,14,0.55)",
          display: "flex",
          alignItems: "center",
          gap: 10 * scale + 4,
          padding: `0 ${14 * scale + 4}px`,
          fontSize: Math.max(6, 12 * scale),
          color: "rgba(255,255,255,0.7)",
        }}
      >
        <span style={{ fontWeight: 600 }}></span>
        <span style={{ fontWeight: 600 }}>Zed</span>
        <span>File</span>
        <span>Edit</span>
        <span>View</span>
        <span style={{ marginLeft: "auto" }}>Fri 10:42</span>
      </div>

      {/* visible frame */}
      <div
        style={{
          position: "absolute",
          left: `${(PAD / DISPLAY_W) * 100}%`,
          right: `${(PAD / DISPLAY_W) * 100}%`,
          top: `${((MENU_BAR + PAD) / DISPLAY_H) * 100}%`,
          bottom: `${(PAD / DISPLAY_H) * 100}%`,
        }}
      >
        {grid?.map((cell, i) => (
          <div
            key={`cell-${i}`}
            style={{
              ...rectStyle(cell),
              border: "1px dashed rgba(255,255,255,0.12)",
              borderRadius: 4,
            }}
          />
        ))}
        {children}
      </div>

      {/* overlays, in display points */}
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 0,
          width: DISPLAY_W,
          height: DISPLAY_H,
          transformOrigin: "0 0",
          transform: `scale(${scale})`,
          pointerEvents: "none",
          zIndex: 100,
        }}
      >
        {/* Each overlay scales itself by --k from its own anchor, so small panels stay legible. */}
        <div
          style={{
            position: "absolute",
            inset: 0,
            pointerEvents: "none",
            ["--k" as string]: overlayScale / scale,
          }}
        >
          {overlay}
        </div>
      </div>
    </div>
  );
}

export function rectStyle(r: Rect): CSSProperties {
  return {
    position: "absolute",
    left: `${r.x * 100}%`,
    top: `${r.y * 100}%`,
    width: `${r.w * 100}%`,
    height: `${r.h * 100}%`,
  };
}

// ── a window ─────────────────────────────────────────────────────────────

export function Win({
  win,
  frame,
  forward = false,
  muted = false,
  z = 1,
  onClick,
}: {
  win: DemoWindow;
  frame: Rect;
  forward?: boolean;
  muted?: boolean;
  z?: number;
  onClick?: () => void;
}) {
  const light = win.tone === "light";
  const body = light ? "#eceae5" : "#1d2228";
  const bar = light ? "#dcd9d3" : "#262c33";
  const line = light ? "rgba(0,0,0,0.12)" : "rgba(255,255,255,0.08)";
  const ink = light ? "rgba(0,0,0,0.6)" : "rgba(255,255,255,0.6)";
  return (
    <div
      onClick={onClick}
      style={{
        ...rectStyle(frame),
        zIndex: z,
        borderRadius: 6,
        overflow: "hidden",
        background: body,
        border: `1px solid ${light ? "rgba(0,0,0,0.18)" : "rgba(255,255,255,0.1)"}`,
        boxShadow: forward
          ? "0 18px 40px rgba(0,0,0,0.55), 0 2px 6px rgba(0,0,0,0.4)"
          : "0 6px 16px rgba(0,0,0,0.35)",
        opacity: muted ? 0.45 : 1,
        cursor: onClick ? "pointer" : "default",
        transition:
          "left .32s cubic-bezier(.2,.8,.2,1), top .32s cubic-bezier(.2,.8,.2,1), width .32s cubic-bezier(.2,.8,.2,1), height .32s cubic-bezier(.2,.8,.2,1), opacity .2s ease, box-shadow .2s ease",
        containerType: "inline-size",
      }}
    >
      <div
        style={{
          height: "clamp(8px, 9cqw, 18px)",
          background: bar,
          display: "flex",
          alignItems: "center",
          gap: "clamp(2px, 1.4cqw, 5px)",
          padding: "0 clamp(3px, 2.4cqw, 8px)",
          borderBottom: `1px solid ${line}`,
        }}
      >
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            style={{
              width: "clamp(3px, 2.4cqw, 7px)",
              aspectRatio: "1",
              borderRadius: "50%",
              background: light ? "rgba(0,0,0,0.2)" : "rgba(255,255,255,0.2)",
              flex: "none",
            }}
          />
        ))}
        {win.title ? (
          <span
            style={{
              marginLeft: "clamp(2px, 1.6cqw, 6px)",
              fontSize: "clamp(5px, 5.2cqw, 11px)",
              color: ink,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            <b style={{ fontWeight: 600 }}>{win.app}</b> {win.title}
          </span>
        ) : null}
      </div>
      <div style={{ padding: "clamp(3px, 4cqw, 12px)", display: "grid", gap: "clamp(2px, 2.4cqw, 7px)" }}>
        {[72, 54, 86, 40, 66].map((w, i) => (
          <div key={i} style={{ height: "clamp(2px, 1.6cqw, 5px)", width: `${w}%`, borderRadius: 3, background: line }} />
        ))}
      </div>
    </div>
  );
}

// ── the top slot ─────────────────────────────────────────────────────────

/** Top centre, 6pt under the visible frame. Stage's island and the card share it. */
function TopSlot({ children }: { children: ReactNode }) {
  return (
    <div style={{ position: "absolute", top: MENU_BAR + 6, left: 0, right: 0, display: "flex", justifyContent: "center" }}>
      <div style={{ transform: "scale(var(--k, 1))", transformOrigin: "50% 0" }}>{children}</div>
    </div>
  );
}

const pill: CSSProperties = {
  height: 24,
  borderRadius: 12,
  background: INK,
  boxShadow: `inset 0 0 0 1px ${KEYLINE}`,
  display: "flex",
  alignItems: "center",
  fontSize: 12,
  color: TEXT,
  whiteSpace: "nowrap",
  pointerEvents: "auto",
};

const Dot = ({ hollow = false }: { hollow?: boolean }) => (
  <span
    style={{
      width: 6,
      height: 6,
      borderRadius: 3,
      background: hollow ? "transparent" : CORAL,
      boxShadow: hollow ? `inset 0 0 0 1.25px ${CORAL}` : "none",
      flex: "none",
    }}
  />
);

const Sep = () => <span style={{ width: 1, height: 12, background: KEYLINE, flex: "none" }} />;

const Key = ({ children }: { children: ReactNode }) => (
  <span
    style={{
      padding: "0 5px",
      height: 16,
      lineHeight: "16px",
      borderRadius: 4,
      boxShadow: `inset 0 0 0 1px ${KEYLINE}`,
      color: TEXT2,
      fontSize: 11,
    }}
  >
    {children}
  </span>
);

/**
 * The island. At rest: coral dot, the word Stage. Hovered: the count, the
 * window that is forward, and how to leave.
 */
export function Island({
  count,
  forward,
  expanded,
  onHover,
}: {
  count: number;
  forward: string;
  /** Force the hover state (for the static frame). Undefined = follow the pointer. */
  expanded?: boolean;
  onHover?: (hovering: boolean) => void;
}) {
  const [hover, setHover] = useState(false);
  const open = expanded ?? hover;
  return (
    <TopSlot>
      <div
        onMouseEnter={() => {
          setHover(true);
          onHover?.(true);
        }}
        onMouseLeave={() => {
          setHover(false);
          onHover?.(false);
        }}
        style={{ ...pill, gap: 7, padding: "0 11px", transition: "padding .18s ease" }}
      >
        <Dot />
        <span style={{ fontWeight: 500 }}>Stage</span>
        {open ? (
          <>
            <Sep />
            <span style={{ color: TEXT2 }}>{count} {count === 1 ? "window" : "windows"}</span>
            <Sep />
            <span>
              {forward} <span style={{ color: TEXT2 }}>forward</span>
            </span>
            <Sep />
            <Key>Esc</Key>
            <span style={{ color: TEXT2 }}>or</span>
            <Key>Hyper X</Key>
            <span style={{ color: TEXT2 }}>leaves</span>
          </>
        ) : null}
      </div>
    </TopSlot>
  );
}

/** Alternative island: position always shown, nothing on hover. */
export function IslandCount({ index, count }: { index: number; count: number }) {
  return (
    <TopSlot>
      <div style={{ ...pill, gap: 7, padding: "0 11px" }}>
        <Dot />
        <span style={{ fontWeight: 500 }}>Stage</span>
        <span style={{ color: TEXT2, fontVariantNumeric: "tabular-nums" }}>
          {index + 1} of {count}
        </span>
      </div>
    </TopSlot>
  );
}

// ── the suggestion card ──────────────────────────────────────────────────

const OFFER_MS = 9000;

/**
 * Only while Stage is off, in the island's slot. A one-line decision, the map
 * of where each window lands, Tile and Not now, and a coral line that drains
 * as the offer times out.
 */
export function SuggestionCard({
  names,
  cells,
  shape,
  onTile,
  onDismiss,
  onTimeout,
  still = false,
}: {
  names: string[];
  cells: Rect[];
  shape: string;
  onTile?: () => void;
  onDismiss?: () => void;
  /** When the coral line runs out. Defaults to onDismiss. */
  onTimeout?: () => void;
  /** A drawing: no timer, the line stopped part way, buttons drawn but not live. */
  still?: boolean;
}) {
  const [hover, setHover] = useState(false);
  const left = useRef(OFFER_MS);
  // The offer runs out after OFFER_MS, but not while the pointer is on the card.
  useEffect(() => {
    const expire = onTimeout ?? onDismiss;
    if (still || hover || !expire) return;
    const started = Date.now();
    const t = window.setTimeout(expire, left.current);
    return () => {
      window.clearTimeout(t);
      left.current = Math.max(0, left.current - (Date.now() - started));
    };
  }, [still, hover, onTimeout, onDismiss]);

  return (
    <TopSlot>
      <div
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
        style={{
          width: 300,
          borderRadius: 12,
          background: INK,
          boxShadow: `inset 0 0 0 1px ${KEYLINE}, 0 12px 30px rgba(0,0,0,0.4)`,
          padding: "12px 14px 12px",
          color: TEXT,
          pointerEvents: "auto",
          animation: "stageCardIn .2s ease-out",
        }}
      >
        <div style={{ fontSize: 13 }}>
          Tile {names.length} {names.length === 1 ? "window" : "windows"}{" "}
          <span style={{ color: TEXT2 }}>· {shape}</span>
        </div>
        <div style={{ display: "flex", gap: 12, marginTop: 10 }}>
          <div style={{ position: "relative", flex: 1, height: 66, borderRadius: 4, boxShadow: `inset 0 0 0 1px ${KEYLINE}` }}>
            {cells.map((cell, i) => (
              <div
                key={i}
                style={{
                  ...rectStyle({ x: cell.x + 0.015, y: cell.y + 0.04, w: cell.w - 0.03, h: cell.h - 0.08 }),
                  borderRadius: 3,
                  background: BLOCK_FILL,
                  boxShadow: `inset 0 0 0 1px ${BLOCK_LINE}`,
                  fontSize: 9,
                  color: TEXT2,
                  padding: "2px 4px",
                  overflow: "hidden",
                  whiteSpace: "nowrap",
                }}
              >
                {names[i]}
              </div>
            ))}
          </div>
          <div style={{ display: "grid", gap: 8, width: 92, alignContent: "center" }}>
            {still ? (
              <>
                <span style={btn(true, true)}>Tile</span>
                <span style={btn(false, true)}>Not now</span>
              </>
            ) : (
              <>
                <button onClick={onTile} style={btn(true)}>Tile</button>
                <button onClick={onDismiss} style={btn(false)}>Not now</button>
              </>
            )}
          </div>
        </div>
        <div style={{ marginTop: 10, height: 2, borderRadius: 1, background: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
          <div
            style={{
              height: "100%",
              background: CORAL,
              transformOrigin: "0 50%",
              ...(still
                ? { transform: "scaleX(0.6)" }
                : { animation: `stageDrain ${OFFER_MS}ms linear forwards`, animationPlayState: hover ? "paused" : "running" }),
            }}
          />
        </div>
      </div>
    </TopSlot>
  );
}

function btn(primary: boolean, drawn = false): CSSProperties {
  return {
    height: 26,
    display: "grid",
    placeItems: "center",
    borderRadius: 6,
    fontSize: 12,
    fontFamily: FONT,
    cursor: drawn ? "default" : "pointer",
    border: "none",
    background: primary ? "rgba(255,255,255,0.92)" : "transparent",
    color: primary ? "#101518" : TEXT,
    boxShadow: primary ? "none" : `inset 0 0 0 1px ${KEYLINE}`,
  };
}

/** Alternative offer: the island, unlit. No map and no Not now; it leaves on its own. */
export function SuggestionPill({ count }: { count: number }) {
  return (
    <TopSlot>
      <div style={{ ...pill, gap: 7, padding: "0 11px" }}>
        <Dot hollow />
        <span style={{ fontWeight: 500 }}>Stage</span>
        <span style={{ color: TEXT2 }}>{count} windows?</span>
      </div>
    </TopSlot>
  );
}

// ── the space switcher ───────────────────────────────────────────────────

export const SPACES: Rect[][] = [
  [{ x: 0.06, y: 0.1, w: 0.42, h: 0.8 }, { x: 0.52, y: 0.1, w: 0.42, h: 0.8 }],
  [{ x: 0.14, y: 0.14, w: 0.72, h: 0.72 }],
  [
    { x: 0.06, y: 0.08, w: 0.42, h: 0.38 },
    { x: 0.52, y: 0.08, w: 0.42, h: 0.38 },
    { x: 0.06, y: 0.54, w: 0.42, h: 0.38 },
    { x: 0.52, y: 0.54, w: 0.42, h: 0.38 },
  ],
  [{ x: 0.06, y: 0.12, w: 0.6, h: 0.76 }, { x: 0.72, y: 0.12, w: 0.22, h: 0.3 }],
  [],
  [{ x: 0.08, y: 0.12, w: 0.84, h: 0.76 }],
];

function SpaceMap({ blocks, current, size }: { blocks: Rect[]; current: boolean; size: { w: number; h: number } }) {
  return (
    <div
      style={{
        position: "relative",
        width: size.w,
        height: size.h,
        borderRadius: 4,
        background: "rgba(255,255,255,0.03)",
        boxShadow: `inset 0 0 0 1px ${current ? "rgba(255,255,255,0.5)" : KEYLINE}`,
      }}
    >
      {blocks.map((b, i) => (
        <div key={i} style={{ ...rectStyle(b), borderRadius: 2, background: BLOCK_FILL, boxShadow: `inset 0 0 0 1px ${BLOCK_LINE}` }} />
      ))}
    </div>
  );
}

/** Its own moment: centred, over everything, then gone. Never in the top slot, never takes the pointer. */
export function SpaceSwitcher({ current, from }: { current: number; from: number | null }) {
  const total = SPACES.length;
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        pointerEvents: "none",
      }}
    >
      <div style={{ transform: "scale(var(--k, 1))" }}>
      <div
        style={{
          borderRadius: 12,
          background: INK,
          boxShadow: `inset 0 0 0 1px ${KEYLINE}, 0 16px 40px rgba(0,0,0,0.45)`,
          padding: "12px 14px 10px",
          color: TEXT,
          animation: "stageCardIn .16s ease-out",
        }}
      >
        <div style={{ display: "flex", alignItems: "baseline", fontSize: 13 }}>
          <span>Desktop {current + 1}</span>
          <span style={{ color: TEXT2, marginLeft: 6 }}>of {total}</span>
          <span style={{ marginLeft: "auto", color: TEXT2, letterSpacing: 6 }}>
            <span style={{ color: current === 0 ? "rgba(255,255,255,0.2)" : TEXT2 }}>‹</span>
            <span style={{ color: current === total - 1 ? "rgba(255,255,255,0.2)" : TEXT2 }}>›</span>
          </span>
        </div>
        <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
          {SPACES.map((blocks, i) => (
            <div key={i} style={{ display: "grid", justifyItems: "center", gap: 4 }}>
              <SpaceMap blocks={blocks} current={i === current} size={{ w: 64, h: 40 }} />
              <div
                style={{
                  width: 64,
                  height: 2,
                  borderRadius: 1,
                  background: CORAL,
                  opacity: i === current ? 1 : i === from ? 0.25 : 0,
                  transition: "opacity .2s ease",
                }}
              />
              <span style={{ fontSize: 11, color: i === current ? TEXT : TEXT2 }}>{i + 1}</span>
            </div>
          ))}
        </div>
      </div>
      </div>
    </div>
  );
}

/** Alternative: the switcher takes the top slot, standing in for the island while it shows. */
export function SpaceSwitcherInSlot({ current }: { current: number }) {
  return (
    <TopSlot>
      <div style={{ ...pill, gap: 8, padding: "0 11px", animation: "stageCardIn .16s ease-out" }}>
        <span>
          Desktop {current + 1} <span style={{ color: TEXT2 }}>of {SPACES.length}</span>
        </span>
        <Sep />
        <span style={{ display: "flex", gap: 3 }}>
          {SPACES.map((_, i) => (
            <span
              key={i}
              style={{
                width: 14,
                height: 9,
                borderRadius: 2,
                background: i === current ? CORAL : BLOCK_FILL,
                boxShadow: i === current ? "none" : `inset 0 0 0 1px ${BLOCK_LINE}`,
              }}
            />
          ))}
        </span>
      </div>
    </TopSlot>
  );
}

export const STAGE_KEYFRAMES = `
  @keyframes stageCardIn { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: none; } }
  @keyframes stageDrain { from { transform: scaleX(1); } to { transform: scaleX(0); } }
`;
