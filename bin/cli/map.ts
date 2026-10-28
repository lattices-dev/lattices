import {
  createDesktopMapReference,
  intersectMapFrames,
  projectMapFrame,
} from "./map-reference.ts";
import type { DesktopMapReference, MapCanvasRect, MapFrame } from "./map-reference.ts";

type Frame = MapFrame;

export type MapSpace = {
  id: number;
  index: number;
  name?: string;
  display: number;
  isCurrent: boolean;
};

export type MapDisplay = {
  displayIndex: number;
  displayId?: string;
  name?: string;
  currentSpaceId: number;
  spaces?: MapSpace[];
  frame?: Frame;
  visibleFrame?: Frame;
};

export type MapWindow = {
  wid: number;
  app: string;
  pid?: number;
  title: string;
  frame: Frame;
  spaceIds: number[];
  isOnScreen: boolean;
  cgLayer?: number;
  axVerified?: boolean;
  latticesSession?: string;
};

type MapOptions = {
  width?: number;
  height?: number;
  display?: number;
};

export type WorkspaceMapSnapshotWindow = MapWindow & { zIndex: number };

export type WorkspaceMapSnapshotDisplay = MapDisplay & {
  spaces: MapSpace[];
  windows: WorkspaceMapSnapshotWindow[];
};

export type WorkspaceMapSnapshot = {
  version: 1;
  coordinateSystem: {
    origin: "top-left";
    units: "points";
    reference: "global-desktop";
  };
  displays: WorkspaceMapSnapshotDisplay[];
};

const MIN_WIDTH = 32;
const MAX_WIDTH = 120;
const MIN_HEIGHT = 8;
const MAX_HEIGHT = 40;
const FALLBACK_WIDTH = 72;
const FALLBACK_HEIGHT = 24;
const MAX_LEGEND_LABEL = 46;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function cleanLabel(value: string): string {
  return value
    .replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/gu, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/gu, "")
    .replace(/[\p{Cc}\p{Cf}]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// The canvas is a fixed grid, so every glyph inside it must occupy exactly one
// terminal column: printable ASCII, the box-drawing block, and the middle dot.
// Anything else — emoji, CJK, combining marks — is projected to "?".
function canvasLabel(value: string): string {
  return cleanLabel(value).replace(/[^\x20-\x7e·]/gu, "?");
}

function fit(text: string, width: number): string {
  if (width <= 0) return "";
  if (text.length <= width) return text;
  if (width === 1) return text.slice(0, 1);
  return `${text.slice(0, width - 1)}~`;
}

function fitLegend(text: string, width: number): string {
  if (text.length <= width) return text;
  return `${text.slice(0, Math.max(1, width - 1))}…`;
}

function formatFrame(frame: Frame): string {
  return `${Math.round(frame.w)}×${Math.round(frame.h)} @ ${Math.round(frame.x)},${Math.round(frame.y)}`;
}

// ── canvas primitives ────────────────────────────────────────────────
//
// Displays are double-line outer frames; every on-screen window is a
// single-line rectangle whose title bar carries its legend number, so a
// monitor outline never reads as a window.
//
// The map is an x-ray floor plan. A window never fills or erases its interior,
// so a window that is completely covered on the real desktop still reads as its
// own numbered rectangle here. Where two outlines meet, their single-line edges
// merge into the correct box-drawing junction instead of one erasing the other.
// The legend — not the drawing — is the authoritative front-to-back order.

// bit order: 1 = up, 2 = right, 4 = down, 8 = left
const UP = 1;
const RIGHT = 2;
const DOWN = 4;
const LEFT = 8;

const DISPLAY_EDGE_BITS: Record<string, number> = {
  "═": 10,
  "║": 5,
  "╔": 6,
  "╗": 12,
  "╚": 3,
  "╝": 9,
  "╠": 7,
  "╣": 13,
  "╦": 14,
  "╩": 11,
  "╬": 15,
};

const WINDOW_EDGE_BITS: Record<string, number> = {
  "─": 10,
  "│": 5,
  "┌": 6,
  "┐": 12,
  "└": 3,
  "┘": 9,
  "├": 7,
  "┤": 13,
  "┬": 14,
  "┴": 11,
  "┼": 15,
};

function glyphsByBits(bits: Record<string, number>): Map<number, string> {
  return new Map(Object.entries(bits).map(([glyph, value]) => [value, glyph]));
}

const DISPLAY_EDGE_GLYPHS = glyphsByBits(DISPLAY_EDGE_BITS);
const WINDOW_EDGE_GLYPHS = glyphsByBits(WINDOW_EDGE_BITS);

function setCell(canvas: string[][], y: number, x: number, glyph: string): void {
  const row = canvas[y];
  if (!row || x < 0 || x >= row.length) return;
  row[x] = glyph;
}

// Merge new edge bits into whatever edge already occupies the cell, within one
// line weight. A crossing becomes ┼/╬ rather than the newer line winning.
function mergeEdge(
  canvas: string[][],
  y: number,
  x: number,
  bits: number,
  table: Record<string, number>,
  glyphs: Map<number, string>,
): boolean {
  const row = canvas[y];
  if (!row || x < 0 || x >= row.length) return false;
  const existing = table[row[x]!];
  const merged = existing === undefined ? bits : existing | bits;
  row[x] = glyphs.get(merged) ?? glyphs.get(bits) ?? row[x]!;
  return true;
}

function setDisplayEdge(canvas: string[][], y: number, x: number, bits: number): void {
  mergeEdge(canvas, y, x, bits, DISPLAY_EDGE_BITS, DISPLAY_EDGE_GLYPHS);
}

function isDisplayEdge(canvas: string[][], y: number, x: number): boolean {
  const glyph = canvas[y]?.[x];
  return glyph !== undefined && DISPLAY_EDGE_BITS[glyph] !== undefined;
}

// Windows may never write over a display border. Insetting the window bounds
// by one cell already keeps them inside, but that is arithmetic; this is the
// invariant. It makes a damaged double-line frame unreachable however the
// window drawing language evolves.
function mergeWindowEdge(canvas: string[][], y: number, x: number, bits: number): boolean {
  if (isDisplayEdge(canvas, y, x)) return false;
  return mergeEdge(canvas, y, x, bits, WINDOW_EDGE_BITS, WINDOW_EDGE_GLYPHS);
}

function setWindowCell(canvas: string[][], y: number, x: number, glyph: string): void {
  if (isDisplayEdge(canvas, y, x)) return;
  setCell(canvas, y, x, glyph);
}

function writeText(canvas: string[][], y: number, x: number, text: string): void {
  for (let index = 0; index < text.length; index++) setCell(canvas, y, x + index, text[index]!);
}

// Keep a projected rectangle inside the canvas and at least one cell wide/tall
// so a small display or window still has a drawable footprint.
function normalizeRect(rect: MapCanvasRect, columns: number, rows: number): MapCanvasRect {
  let left = clamp(rect.left, 0, columns - 1);
  let right = clamp(rect.right, 0, columns - 1);
  let top = clamp(rect.top, 0, rows - 1);
  let bottom = clamp(rect.bottom, 0, rows - 1);
  if (right - left < 1) {
    if (right + 1 <= columns - 1) right = left + 1;
    else left = right - 1;
  }
  if (bottom - top < 1) {
    if (bottom + 1 <= rows - 1) bottom = top + 1;
    else top = bottom - 1;
  }
  return { left, top, right, bottom };
}

function displayHeader(display: MapDisplay, room: number): string {
  const tag = `D${display.displayIndex}`;
  const name = display.name ? canvasLabel(display.name) : "";
  const space = `Space ${display.currentSpaceId}`;
  const candidates = [
    name ? `${tag} · ${name} · ${space}` : `${tag} · ${space}`,
    `${tag} · ${space}`,
    name ? `${tag} · ${name}` : tag,
    tag,
  ];
  for (const candidate of candidates) {
    if (candidate.length <= room) return candidate;
  }
  return fit(tag, room);
}

function drawDisplay(canvas: string[][], rect: MapCanvasRect, display: MapDisplay): void {
  const { left, top, right, bottom } = rect;

  for (let y = top + 1; y < bottom; y++) {
    for (let x = left + 1; x < right; x++) setCell(canvas, y, x, " ");
  }
  for (let x = left + 1; x < right; x++) {
    setDisplayEdge(canvas, top, x, LEFT | RIGHT);
    setDisplayEdge(canvas, bottom, x, LEFT | RIGHT);
  }
  for (let y = top + 1; y < bottom; y++) {
    setDisplayEdge(canvas, y, left, UP | DOWN);
    setDisplayEdge(canvas, y, right, UP | DOWN);
  }
  setDisplayEdge(canvas, top, left, RIGHT | DOWN);
  setDisplayEdge(canvas, top, right, LEFT | DOWN);
  setDisplayEdge(canvas, bottom, left, UP | RIGHT);
  setDisplayEdge(canvas, bottom, right, UP | LEFT);

  // Identity rides in the top border: ╔═ D0 · Name · Space 1 ═══╗
  const room = right - left - 4;
  if (room >= 2) writeText(canvas, top, left + 1, `═ ${displayHeader(display, room)} `);
}

// ── window outlines and markers ──────────────────────────────────────

type EdgeMark = { y: number; x: number; bits: number };

type WindowShape = {
  marks: EdgeMark[];
  box: boolean;
  left: number;
  top: number;
  right: number;
  bottom: number;
};

// The drawable area for windows: the display rect inset by two cells, so a
// blank gutter always separates the double-line bezel from any window border.
// Without it a maximized window renders "║┌" and the two read as one thick
// frame. On a display too small to afford the gutter the inset falls back to
// one cell — windows still never reach the bezel, which is the hard guarantee.
function windowBounds(rect: MapCanvasRect): MapCanvasRect | undefined {
  const gutter: MapCanvasRect = {
    left: rect.left + 2,
    top: rect.top + 2,
    right: rect.right - 2,
    bottom: rect.bottom - 2,
  };
  if (gutter.right >= gutter.left && gutter.bottom >= gutter.top) return gutter;

  const tight: MapCanvasRect = {
    left: rect.left + 1,
    top: rect.top + 1,
    right: rect.right - 1,
    bottom: rect.bottom - 1,
  };
  return tight.right >= tight.left && tight.bottom >= tight.top ? tight : undefined;
}

// The outline of one window, as edge bits rather than glyphs, so intersecting
// windows can merge into junctions instead of overwriting each other. Windows
// thinner than two cells in a dimension collapse to a rule; they still carry an
// outline and still get a marker below.
function windowShape(bounds: MapCanvasRect, rect: MapCanvasRect): WindowShape | undefined {
  const left = clamp(rect.left, bounds.left, bounds.right);
  const right = clamp(rect.right, bounds.left, bounds.right);
  const top = clamp(rect.top, bounds.top, bounds.bottom);
  const bottom = clamp(rect.bottom, bounds.top, bounds.bottom);
  if (right < left || bottom < top) return undefined;

  const marks: EdgeMark[] = [];
  const wide = right - left >= 1;
  const tall = bottom - top >= 1;

  if (!wide || !tall) {
    const bits = wide ? LEFT | RIGHT : UP | DOWN;
    for (let y = top; y <= bottom; y++) {
      for (let x = left; x <= right; x++) marks.push({ y, x, bits });
    }
    return { marks, box: false, left, top, right, bottom };
  }

  for (let x = left + 1; x < right; x++) {
    marks.push({ y: top, x, bits: LEFT | RIGHT });
    marks.push({ y: bottom, x, bits: LEFT | RIGHT });
  }
  for (let y = top + 1; y < bottom; y++) {
    marks.push({ y, x: left, bits: UP | DOWN });
    marks.push({ y, x: right, bits: UP | DOWN });
  }
  marks.push({ y: top, x: left, bits: RIGHT | DOWN });
  marks.push({ y: top, x: right, bits: LEFT | DOWN });
  marks.push({ y: bottom, x: left, bits: UP | RIGHT });
  marks.push({ y: bottom, x: right, bits: UP | LEFT });
  return { marks, box: true, left, top, right, bottom };
}

type MarkerTier = "full" | "bare";

type MarkerPlacement = { y: number; x: number; text: string; tier: MarkerTier };

// A run is available when no nearer window has claimed it for text and it does
// not sit on a display border.
function runIsFree(
  canvas: string[][],
  claimed: number[][],
  y: number,
  x: number,
  length: number,
): boolean {
  const row = claimed[y];
  if (!row) return false;
  for (let step = 0; step < length; step++) {
    const cx = x + step;
    if (cx < 0 || cx >= row.length || row[cx] !== 0) return false;
    if (isDisplayEdge(canvas, y, cx)) return false;
  }
  return true;
}

function isDigit(canvas: string[][], y: number, x: number): boolean {
  const glyph = canvas[y]?.[x];
  return glyph !== undefined && glyph >= "0" && glyph <= "9";
}

// Find somewhere inside this window's own footprint for its marker that no
// nearer window has already claimed. Markers are placed front to back, so the
// search only ever has to avoid text that is closer to the front.
//
// The marker hugs the window's own left edge and walks down its rows before it
// slides right: a number sitting under its own top-left corner is unambiguous,
// while one pushed along a shared title-bar row reads as the neighbour's.
function findMarkerSlot(
  canvas: string[][],
  claimed: number[][],
  shape: WindowShape,
  text: string,
  tier: MarkerTier,
): MarkerPlacement | undefined {
  const length = text.length;
  // "[12]" delimits itself, but a bare "12" butted against the next window's
  // bare "13" reads as "1213". A bare marker therefore also needs a non-digit
  // cell on each side; those flanks are reserved when it lands.
  const fits = (y: number, x: number): boolean =>
    runIsFree(canvas, claimed, y, x, length) &&
    (tier === "full" || (!isDigit(canvas, y, x - 1) && !isDigit(canvas, y, x + length)));

  const anchors: number[] = [];
  if (shape.left + length <= shape.right) anchors.push(shape.left + 1);
  if (shape.left + length - 1 <= shape.right) anchors.push(shape.left);

  for (const x of anchors) {
    for (let y = shape.top; y <= shape.bottom; y++) {
      if (fits(y, x)) return { y, x, text, tier };
    }
  }
  for (let y = shape.top; y <= shape.bottom; y++) {
    for (let x = shape.left + 1; x + length - 1 <= shape.right; x++) {
      if (fits(y, x)) return { y, x, text, tier };
    }
  }
  return undefined;
}

// A window one cell wide and two cells tall has no room for "[12]" anywhere, so
// fall back to the bare number — but only ever in full. A truncated numeral is
// worse than an absent one, because "12" clipped to "1" is silently another
// window's marker. The legend states which tier a window got.
function markerForms(index: number): { text: string; tier: MarkerTier }[] {
  return [
    { text: `[${index}]`, tier: "full" },
    { text: String(index), tier: "bare" },
  ];
}

function windowDescription(window: MapWindow, room: number): string {
  if (room < 3) return "";
  const app = canvasLabel(window.app);
  const title = canvasLabel(window.title);
  const full = ` ${app}${title ? ` - ${title}` : ""}`;
  if (full.length <= room) return full;
  const short = ` ${app}`;
  if (short.length <= room) return short;
  return fit(short, room);
}

// ── data selection ───────────────────────────────────────────────────

function usableFrame(display: MapDisplay): Frame | undefined {
  return display.visibleFrame ?? display.frame;
}

// The full frame owns the display outline and the global viewport; the visible
// frame is only the usable area windows live in.
function boundaryFrame(display: MapDisplay): Frame | undefined {
  return display.frame ?? display.visibleFrame;
}

function hasArea(frame: Frame | undefined): frame is Frame {
  return !!frame && frame.w > 0 && frame.h > 0;
}

function intersects(a: Frame, b: Frame): boolean {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}

function windowsForDisplay(display: MapDisplay, windows: MapWindow[]): MapWindow[] {
  const frame = usableFrame(display);
  if (!hasArea(frame)) return [];
  return windows.filter((window) =>
    window.isOnScreen &&
    (window.cgLayer !== undefined || window.spaceIds.includes(display.currentSpaceId)) &&
    intersects(window.frame, frame)
  );
}

// ── JSON snapshot (unchanged contract) ───────────────────────────────

function snapshotFrame(frame: Frame): Frame {
  return { x: frame.x, y: frame.y, w: frame.w, h: frame.h };
}

function snapshotSpace(space: MapSpace): MapSpace {
  return {
    id: space.id,
    index: space.index,
    ...(space.name === undefined ? {} : { name: space.name }),
    display: space.display,
    isCurrent: space.isCurrent,
  };
}

function snapshotWindow(window: MapWindow, zIndex: number): WorkspaceMapSnapshotWindow {
  return {
    wid: window.wid,
    app: window.app,
    ...(window.pid === undefined ? {} : { pid: window.pid }),
    title: window.title,
    frame: snapshotFrame(window.frame),
    spaceIds: [...window.spaceIds],
    isOnScreen: window.isOnScreen,
    ...(window.cgLayer === undefined ? {} : { cgLayer: window.cgLayer }),
    ...(window.axVerified === undefined ? {} : { axVerified: window.axVerified }),
    ...(window.latticesSession === undefined ? {} : { latticesSession: window.latticesSession }),
    zIndex,
  };
}

function snapshotDisplay(display: MapDisplay, windows: MapWindow[]): WorkspaceMapSnapshotDisplay {
  return {
    displayIndex: display.displayIndex,
    ...(display.displayId === undefined ? {} : { displayId: display.displayId }),
    ...(display.name === undefined ? {} : { name: display.name }),
    currentSpaceId: display.currentSpaceId,
    spaces: (display.spaces ?? []).map(snapshotSpace),
    ...(display.frame === undefined ? {} : { frame: snapshotFrame(display.frame) }),
    ...(display.visibleFrame === undefined ? {} : { visibleFrame: snapshotFrame(display.visibleFrame) }),
    windows: windowsForDisplay(display, windows).map(snapshotWindow),
  };
}

/**
 * Displays whose daemon payload carries no usable geometry (a pre-frame
 * `spaces.list`, i.e. an app build that predates the workspace map). Windows
 * cannot be assigned to such a display, so a snapshot containing it would
 * silently report an occupied desktop as empty.
 */
export function displaysMissingGeometry(
  displays: MapDisplay[],
  options: Pick<MapOptions, "display"> = {},
): MapDisplay[] {
  return displays.filter((display) =>
    (options.display === undefined || display.displayIndex === options.display) &&
    !hasArea(usableFrame(display))
  );
}

export function createWorkspaceMapSnapshot(
  displays: MapDisplay[],
  windows: MapWindow[],
  options: Pick<MapOptions, "display"> = {},
): WorkspaceMapSnapshot {
  const selected = displays.filter((display) =>
    options.display === undefined || display.displayIndex === options.display
  );
  return {
    version: 1,
    coordinateSystem: {
      origin: "top-left",
      units: "points",
      reference: "global-desktop",
    },
    displays: selected.map((display) => snapshotDisplay(display, windows)),
  };
}

// ── terminal map ─────────────────────────────────────────────────────

type PlacedWindow = { window: MapWindow; index: number };

type DisplayPlacement = {
  display: MapDisplay;
  boundary: Frame;
  usable: Frame;
  windows: PlacedWindow[];
};

function summaryLine(reference: DesktopMapReference, placements: DisplayPlacement[]): string {
  const windowCount = placements.reduce((total, placement) => total + placement.windows.length, 0);
  const pointsPerColumn = Math.round(1 / reference.cellsPerPoint);
  const pointsPerRow = Math.round(reference.cellAspectRatio / reference.cellsPerPoint);
  return [
    `Desktop ${formatFrame(reference.viewport)}`,
    `${placements.length} display${placements.length === 1 ? "" : "s"}`,
    `${windowCount} window${windowCount === 1 ? "" : "s"}`,
    `1 cell ≈ ${pointsPerColumn}×${pointsPerRow} pt`,
  ].join(" · ");
}

function displayLegendLines(placements: DisplayPlacement[]): string[] {
  const rows = placements.map((placement) => {
    const { display, boundary, usable } = placement;
    const name = display.name ? cleanLabel(display.name) : "";
    return {
      tag: `D${display.displayIndex}`,
      identity: `Display ${display.displayIndex}${name ? ` · ${name}` : ""} · Space ${display.currentSpaceId}`,
      frame: `frame ${formatFrame(boundary)}`,
      usable: usable.x === boundary.x && usable.y === boundary.y &&
          usable.w === boundary.w && usable.h === boundary.h
        ? ""
        : `usable ${formatFrame(usable)}`,
    };
  });
  const tagWidth = Math.max(...rows.map((row) => row.tag.length));
  const identityWidth = Math.max(...rows.map((row) => row.identity.length));
  const frameWidth = Math.max(...rows.map((row) => row.frame.length));
  return rows.map((row) =>
    `  ${row.tag.padEnd(tagWidth)}  ${row.identity.padEnd(identityWidth)}  ${row.usable ? row.frame.padEnd(frameWidth) : row.frame}${row.usable ? `  ${row.usable}` : ""}`
  );
}

// Every legend row resolves to exactly one of four states, and the note says
// which: `[n]` on the canvas (no note), a bare number (small), an outline with
// no room for any numeral (too small to label), or nothing drawn at all
// (off-canvas). There is no unannotated absence. The x-ray model has no
// `(occluded)` state — a covered window still draws its whole rectangle.
type Coverage = { outlined: Set<number>; markers: Map<number, MarkerTier> };

function legendNote(index: number, coverage: Coverage): string {
  if (!coverage.outlined.has(index)) return "(off-canvas)";
  const tier = coverage.markers.get(index);
  if (tier === "full") return "";
  return tier === "bare" ? "(small)" : "(too small to label)";
}

function windowLegendLines(placements: DisplayPlacement[], coverage: Coverage): string[] {
  const rows = placements.flatMap((placement) =>
    placement.windows.map(({ window, index }) => ({
      index: String(index),
      tag: `D${placement.display.displayIndex}`,
      label: fitLegend(
        `${cleanLabel(window.app)}${cleanLabel(window.title) ? ` · ${cleanLabel(window.title)}` : ""}`,
        MAX_LEGEND_LABEL,
      ),
      wid: `wid:${window.wid}`,
      geometry: formatFrame(window.frame),
      note: legendNote(index, coverage),
    }))
  );
  if (!rows.length) return ["  No on-screen windows on the current Spaces."];

  const indexWidth = Math.max(...rows.map((row) => row.index.length));
  const tagWidth = Math.max(...rows.map((row) => row.tag.length));
  const labelWidth = Math.max(...rows.map((row) => row.label.length));
  const widWidth = Math.max(...rows.map((row) => row.wid.length));
  const geometryWidth = Math.max(...rows.map((row) => row.geometry.length));
  return rows.map((row) => {
    const line = `  ${row.index.padStart(indexWidth)}  ${row.tag.padEnd(tagWidth)}  ${row.label.padEnd(labelWidth)}  ${row.wid.padEnd(widWidth)}  ${row.geometry}`;
    return row.note ? `${line.padEnd(line.length + geometryWidth - row.geometry.length)}  ${row.note}` : line;
  });
}

export function renderWorkspaceMap(
  displays: MapDisplay[],
  windows: MapWindow[],
  options: MapOptions = {},
): string {
  const selected = displays.filter((display) => options.display === undefined || display.displayIndex === options.display);
  if (!selected.length) return options.display === undefined ? "No displays found." : `Display ${options.display} not found.`;

  const maxColumns = clamp(Math.round(options.width ?? FALLBACK_WIDTH), MIN_WIDTH, MAX_WIDTH);
  const maxRows = clamp(Math.round(options.height ?? FALLBACK_HEIGHT), MIN_HEIGHT, MAX_HEIGHT);

  const placements: DisplayPlacement[] = [];
  const unavailable: MapDisplay[] = [];
  let counter = 0;
  for (const display of selected) {
    const boundary = boundaryFrame(display);
    const usable = usableFrame(display);
    if (!hasArea(boundary) || !hasArea(usable)) {
      unavailable.push(display);
      continue;
    }
    // windows.list is front-to-back; index 1 is the frontmost window of the
    // first selected display, so legend numbers are stable across renders.
    const windowsHere = windowsForDisplay(display, windows).map((window) => ({ window, index: ++counter }));
    placements.push({ display, boundary, usable, windows: windowsHere });
  }

  const unavailableLines = unavailable.map((display) =>
    `  D${display.displayIndex}  Display ${display.displayIndex}${display.name ? ` · ${cleanLabel(display.name)}` : ""}  geometry unavailable — update the Lattices app.`
  );

  const reference = createDesktopMapReference(placements.map((placement) => placement.boundary), {
    maxColumns,
    maxRows,
  });
  if (!reference) {
    return ["No display geometry available.", ...unavailableLines].join("\n");
  }

  const canvas = Array.from({ length: reference.rows }, () =>
    Array.from({ length: reference.columns }, () => " ")
  );
  // Which window owns each cell's marker text. Outlines merge and never claim a
  // cell, so this is only about keeping two numbers from landing on top of each
  // other — the front-most window claims first.
  const claimed = Array.from({ length: reference.rows }, () =>
    Array.from({ length: reference.columns }, () => 0)
  );

  // One uniform projection for the whole desktop. Displays are painted first;
  // their interior fill is the only thing that clears cells.
  const rects = new Map<DisplayPlacement, MapCanvasRect>();
  for (const placement of placements) {
    const rect = normalizeRect(
      projectMapFrame(reference, placement.boundary),
      reference.columns,
      reference.rows,
    );
    rects.set(placement, rect);
    drawDisplay(canvas, rect, placement.display);
  }

  // Pass one: every window outline, merged. Order does not matter because
  // nothing is erased — a covered window keeps its full rectangle.
  const shapes: { window: MapWindow; index: number; shape: WindowShape; primary: boolean }[] = [];
  const outlined = new Set<number>();
  for (const placement of placements) {
    // Windows stay inside the monitor outline, separated from it by a gutter,
    // so the bezel always reads as its own thing. The legend keeps the exact
    // global geometry.
    const bounds = windowBounds(rects.get(placement)!);
    if (!bounds) continue;
    let primaryClaimed = false;
    for (const { window, index } of placement.windows) {
      const clipped = intersectMapFrames(window.frame, placement.usable);
      if (!clipped) continue;
      const shape = windowShape(bounds, projectMapFrame(reference, clipped));
      if (!shape) continue;
      outlined.add(index);
      // Exactly one window per display carries an app/title label: the
      // frontmost one that is actually drawable.
      shapes.push({ window, index, shape, primary: !primaryClaimed });
      primaryClaimed = true;
      for (const mark of shape.marks) mergeWindowEdge(canvas, mark.y, mark.x, mark.bits);
    }
  }

  // Pass two: closure. A window's bottom-right endpoint is restamped as its own
  // corner so it terminates visibly instead of dissolving into a shared rail.
  // Where two windows want the same cell the glyph is identical, so the result
  // is order-independent; where a corner lands mid-edge, closure deliberately
  // wins over line continuity.
  for (const { shape } of shapes) {
    if (shape.box) setWindowCell(canvas, shape.bottom, shape.right, "┘");
  }

  // Pass three: markers, front to back, so the primary window gets the title
  // bar and windows behind it slide to the next free run inside their own
  // footprint. A marker may overwrite an outline; that is the point — every
  // window must stay identifiable.
  const markers = new Map<number, MarkerTier>();
  for (const { window, index, shape, primary } of shapes.sort((a, b) => a.index - b.index)) {
    let placement: MarkerPlacement | undefined;
    for (const { text, tier } of markerForms(index)) {
      placement = findMarkerSlot(canvas, claimed, shape, text, tier);
      if (placement) break;
    }
    if (!placement) continue;
    markers.set(index, placement.tier);
    const { y, x, text, tier } = placement;
    for (let step = 0; step < text.length; step++) {
      setWindowCell(canvas, y, x + step, text[step]!);
      claimed[y]![x + step] = index;
    }
    // Reserve the flanking cells of a bare number without drawing in them, so
    // a window further back cannot butt its own number up against this one.
    if (tier === "bare") {
      for (const cx of [x - 1, x + text.length]) {
        if (claimed[y]?.[cx] === 0) claimed[y]![cx] = index;
      }
    }

    // Only the primary window spells out its app and title on the canvas.
    // Labelling every overlapping window is what turned the map into noise;
    // secondary windows keep their full geometry and their number, and the
    // legend carries their identity.
    if (!primary) continue;

    // The app/title only fills unclaimed cells to the right of the marker and
    // stops before the window's own right edge, so it never buries a number.
    let room = 0;
    for (let cx = x + text.length; cx < shape.right; cx++) {
      if (!runIsFree(canvas, claimed, y, cx, 1)) break;
      room++;
    }
    const description = windowDescription(window, room);
    for (let step = 0; step < description.length; step++) {
      const cx = x + text.length + step;
      setWindowCell(canvas, y, cx, description[step]!);
      claimed[y]![cx] = index;
    }
  }

  const map = canvas.map((row) => row.join("").replace(/\s+$/u, ""));
  const sections: string[] = [
    summaryLine(reference, placements),
    "",
    ...map,
    "",
    "Key · ╔═ display ═╗   ┌[1] frontmost window ─┐   ┌[n]──┘ others, numbered only",
    "       lower n = nearer the front of its own display; n does not order across displays",
    "",
    "Displays",
    ...displayLegendLines(placements),
    ...unavailableLines,
    "",
    "Windows · front to back within each display",
    ...windowLegendLines(placements, { outlined, markers }),
  ];
  return sections.join("\n");
}

export function mapUsage(): string {
  return `Usage: lats map [options]

Render the current Space of every display as one scaled map of the desktop.

Options:
  --include-panels  Read-only on-screen CG inventory, including non-zero layers
  --display <n>  Render one display index
  --width <n>    Maximum map width (32–120; defaults to terminal width)
  --height <n>   Maximum map height (8–40; defaults to 24)
  --json         Return a versioned current-Space snapshot for agents
  -h, --help     Show this help`;
}

async function loadMapState(
  daemonCall: (method: string, params?: Record<string, unknown> | null) => Promise<unknown>,
): Promise<{ displays: MapDisplay[]; windows: MapWindow[] }> {
  try {
    const snapshot = await daemonCall("desktop.snapshot", { includeOffscreen: false }) as {
      displays?: MapDisplay[];
      windows?: MapWindow[];
    };
    if (Array.isArray(snapshot?.displays) && Array.isArray(snapshot?.windows)) {
      return { displays: snapshot.displays, windows: snapshot.windows };
    }
  } catch {
    // Older app builds have map but not desktop.snapshot.
  }
  const [spacesPayload, windowsPayload] = await Promise.all([
    daemonCall("spaces.list"),
    daemonCall("windows.list"),
  ]);
  const displays = (Array.isArray(spacesPayload) ? spacesPayload : (spacesPayload as { displays?: MapDisplay[] })?.displays ?? []) as MapDisplay[];
  const windows = (Array.isArray(windowsPayload) ? windowsPayload : []) as MapWindow[];
  return { displays, windows };
}

export function parseMapOptions(args: string[]): MapOptions & { json: boolean } {
  const options: MapOptions & { json: boolean } = { json: false };
  const numericOptions = new Set(["display", "width", "height"]);

  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") {
      options.json = true;
      continue;
    }

    const match = argument.match(/^--([^=]+)(?:=(.*))?$/u);
    if (!match || !numericOptions.has(match[1]!)) {
      throw new Error(`Unknown option: ${argument}`);
    }

    const name = match[1]! as "display" | "width" | "height";
    const inlineValue = match[2];
    const raw = inlineValue === undefined ? args[++index] : inlineValue;
    if (raw === undefined || raw === "" || raw.startsWith("--")) {
      throw new Error(`--${name} expects a non-negative integer`);
    }

    const parsed = Number(raw);
    if (!Number.isInteger(parsed) || parsed < 0) {
      throw new Error(`--${name} expects a non-negative integer`);
    }
    options[name] = parsed;
  }

  return options;
}

export async function mapCommand(
  args: string[],
  daemonCall: (method: string, params?: Record<string, unknown> | null) => Promise<unknown>,
): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(mapUsage());
    return;
  }
  const includePanels = args.includes("--include-panels");
  const { json, display, height, width: requestedWidth } = parseMapOptions(args.filter(arg => arg !== "--include-panels"));
  const width = requestedWidth ?? process.stdout.columns;
  const state = await loadMapState(daemonCall);
  const displays = state.displays;
  const windows = includePanels
    ? await daemonCall("windows.list", { includePanels: true }) as MapWindow[]
    : state.windows;

  if (json) {
    // A display without geometry would yield a valid-looking snapshot whose
    // windows array is empty — false state, worse than no state. Refuse it.
    const missing = displaysMissingGeometry(displays, { display });
    if (missing.length) {
      const tags = missing.map((entry) => `Display ${entry.displayIndex}`).join(", ");
      throw new Error(
        `${tags} reported no frame geometry; the running Lattices app predates the workspace map snapshot. ` +
        `Update and restart the app (lats app update), then retry.`
      );
    }
    console.log(JSON.stringify(createWorkspaceMapSnapshot(displays, windows, { display }), null, 2));
    return;
  }
  console.log(renderWorkspaceMap(displays, windows, { display, width, height }));
}
