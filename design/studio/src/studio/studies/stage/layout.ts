/**
 * Stage geometry. Unit rects, y = 0 at the top, inside the display's visible
 * frame. The "shipped" functions mirror apps/mac/Sources/Core/Desktop/StageLayout.swift
 * line for line; the others are the alternative behaviors the study draws next
 * to them.
 */

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

// ── shipped (StageLayout.swift) ──────────────────────────────────────────

export const ACTIVE_WIDTH = 0.4;
export const ACTIVE_HEIGHT = 0.86;
export const REST_SCALE = 0.84;

/** 1 → 1, 2 and 4 → 2, everything else → 3. */
export function shippedColumns(count: number): number {
  if (count < 2) return 1;
  if (count === 2 || count === 4) return 2;
  return 3;
}

/** Row-major home cells. A short last row is centered. */
export function gridHomes(count: number, cols: number, lastRow: "center" | "stretch" = "center"): Rect[] {
  if (count <= 0) return [];
  const rows = Math.ceil(count / cols);
  const cellH = 1 / rows;
  return Array.from({ length: count }, (_, index) => {
    const row = Math.floor(index / cols);
    const col = index % cols;
    const inRow = Math.min(cols, count - row * cols);
    if (lastRow === "stretch") {
      const w = 1 / inRow;
      return { x: col * w, y: row * cellH, w, h: cellH };
    }
    const cellW = 1 / cols;
    const lead = ((cols - inRow) * cellW) / 2;
    return { x: lead + col * cellW, y: row * cellH, w: cellW, h: cellH };
  });
}

export function shippedHomes(count: number): Rect[] {
  return gridHomes(count, shippedColumns(count));
}

export function inset(rect: Rect, scale: number): Rect {
  const w = rect.w * scale;
  const h = rect.h * scale;
  return { x: rect.x + (rect.w - w) / 2, y: rect.y + (rect.h - h) / 2, w, h };
}

/** activeWidth × activeHeight, centered on its home, clamped to the display. */
export function engaged(home: Rect): Rect {
  const w = ACTIVE_WIDTH;
  const h = ACTIVE_HEIGHT;
  const cx = home.x + home.w / 2;
  const cy = home.y + home.h / 2;
  return {
    x: Math.min(Math.max(cx - w / 2, 0), Math.max(0, 1 - w)),
    y: Math.min(Math.max(cy - h / 2, 0), Math.max(0, 1 - h)),
    w,
    h,
  };
}

export function framesFromHomes(
  homes: Rect[],
  active: number,
  rest: (home: Rect) => Rect = (home) => inset(home, REST_SCALE),
): Rect[] {
  if (active < 0 || active >= homes.length) return homes;
  return homes.map((home, index) => (index === active ? engaged(home) : rest(home)));
}

export function shippedFrames(count: number, active: number): Rect[] {
  return framesFromHomes(shippedHomes(count), active);
}

// ── alternatives ─────────────────────────────────────────────────────────

/** Columns: a near-square grid, and the short last row stretches to the edges. */
export function squareColumns(count: number): number {
  return Math.max(1, Math.ceil(Math.sqrt(count)));
}

export function squareFrames(count: number, active: number): Rect[] {
  return framesFromHomes(gridHomes(count, squareColumns(count), "stretch"), active);
}

/** Engaged: its column and row widen, the neighbors give up the room, nothing overlaps. */
export const ROOM_WIDTH = 0.5;
export const ROOM_HEIGHT = 0.7;

export function makeRoomFrames(count: number, active: number): Rect[] {
  const cols = shippedColumns(count);
  const rows = Math.ceil(count / cols);
  if (active < 0 || active >= count) return shippedHomes(count);
  const activeRow = Math.floor(active / cols);

  const rowH = (row: number) => {
    if (rows === 1) return 1;
    const engagedH = Math.max(1 / rows, ROOM_HEIGHT);
    return row === activeRow ? engagedH : (1 - engagedH) / (rows - 1);
  };
  const rowY = (row: number) => {
    let y = 0;
    for (let r = 0; r < row; r += 1) y += rowH(r);
    return y;
  };

  return Array.from({ length: count }, (_, index) => {
    const row = Math.floor(index / cols);
    const col = index % cols;
    const inRow = Math.min(cols, count - row * cols);
    const y = rowY(row);
    const h = rowH(row);
    let x: number;
    let w: number;
    if (row === activeRow && inRow > 1) {
      const activeCol = active % cols;
      const engagedW = Math.max(1 / inRow, ROOM_WIDTH);
      const otherW = (1 - engagedW) / (inRow - 1);
      x = col < activeCol ? col * otherW : col === activeCol ? activeCol * otherW : activeCol * otherW + engagedW + (col - activeCol - 1) * otherW;
      w = col === activeCol ? engagedW : otherW;
    } else {
      const cellW = 1 / cols;
      const lead = ((cols - inRow) * cellW) / 2;
      x = lead + col * cellW;
      w = cellW;
    }
    const cell = { x, y, w, h };
    // A small, even gap so the cells read as separate windows.
    return insetBy(cell, 0.006, 0.01);
  });
}

/** Resting: the cell less a fixed gutter, instead of a share of it. */
export const GUTTER_X = 0.012;
export const GUTTER_Y = 0.02;

export function insetBy(rect: Rect, dx: number, dy: number): Rect {
  return { x: rect.x + dx, y: rect.y + dy, w: Math.max(0, rect.w - dx * 2), h: Math.max(0, rect.h - dy * 2) };
}

export function gutterFrames(count: number, active: number): Rect[] {
  return framesFromHomes(shippedHomes(count), active, (home) => insetBy(home, GUTTER_X, GUTTER_Y));
}

/** One window: it fills the visible frame less a margin. */
export const FILL_MARGIN = 0.03;

export function fillFrame(): Rect {
  return insetBy({ x: 0, y: 0, w: 1, h: 1 }, FILL_MARGIN * 0.62, FILL_MARGIN);
}
