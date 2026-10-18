"use client";

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface TilePreset {
  name: string;
  grid: { cols: number; rows: number };
  cell?: { col: number; row: number };
  rect: Rect;
  family: string;
  description?: string;
}

export interface TilePresetFamily {
  key: string;
  label: string;
  caption: string;
  grid: { cols: number; rows: number };
  blurb?: string;
  presets: TilePreset[];
}

export interface ComposedLayout {
  key: string;
  label: string;
  caption: string;
  grid: { cols: number; rows: number };
  members: string[];
}

function cellRect(cols: number, rows: number, col: number, row: number): Rect {
  return {
    x: col / cols,
    y: row / rows,
    w: 1 / cols,
    h: 1 / rows,
  };
}

function family(
  key: string,
  label: string,
  cols: number,
  rows: number,
  blurb: string,
  entries: Array<[string, number, number, string?]>,
): TilePresetFamily {
  return {
    key,
    label,
    caption: `${cols} × ${rows}`,
    grid: { cols, rows },
    blurb,
    presets: entries.map(([name, col, row, description]) => ({
      name,
      grid: { cols, rows },
      cell: { col, row },
      rect: cellRect(cols, rows, col, row),
      family: key,
      description,
    })),
  };
}

export const SPECIAL_PRESETS: TilePreset[] = [
  {
    name: "maximize",
    grid: { cols: 1, rows: 1 },
    cell: { col: 0, row: 0 },
    rect: { x: 0, y: 0, w: 1, h: 1 },
    family: "special",
    description: "Full screen (100% × 100%)",
  },
  {
    name: "center",
    grid: { cols: 1, rows: 1 },
    rect: { x: 0.15, y: 0.1, w: 0.7, h: 0.8 },
    family: "special",
    description: "Centered floating (70% × 80%, offset 15% / 10%)",
  },
];

export const TILE_FAMILIES: TilePresetFamily[] = [
  family("halves-v", "Halves", 2, 1, "Full-height vertical split.", [
    ["left", 0, 0],
    ["right", 1, 0],
  ]),
  family("halves-h", "Halves · stacked", 1, 2, "Full-width horizontal split.", [
    ["top", 0, 0],
    ["bottom", 0, 1],
  ]),
  family("quarters", "Quarters", 2, 2, "Classic 2 × 2 quadrants.", [
    ["top-left", 0, 0],
    ["top-right", 1, 0],
    ["bottom-left", 0, 1],
    ["bottom-right", 1, 1],
  ]),
  family("thirds-v", "Thirds", 3, 1, "Full-height vertical thirds.", [
    ["left-third", 0, 0],
    ["center-third", 1, 0],
    ["right-third", 2, 0],
  ]),
  family("sixths", "Sixths", 3, 2, "Two-row × three-column lattice.", [
    ["top-left-third", 0, 0],
    ["top-center-third", 1, 0],
    ["top-right-third", 2, 0],
    ["bottom-left-third", 0, 1],
    ["bottom-center-third", 1, 1],
    ["bottom-right-third", 2, 1],
  ]),
  family("fourths-v", "Fourths", 4, 1, "Full-height columns, divided in four.", [
    ["first-fourth", 0, 0],
    ["second-fourth", 1, 0],
    ["third-fourth", 2, 0],
    ["last-fourth", 3, 0],
  ]),
  family("eighths", "Eighths", 4, 2, "Two-row × four-column lattice.", [
    ["top-first-fourth", 0, 0],
    ["top-second-fourth", 1, 0],
    ["top-third-fourth", 2, 0],
    ["top-last-fourth", 3, 0],
    ["bottom-first-fourth", 0, 1],
    ["bottom-second-fourth", 1, 1],
    ["bottom-third-fourth", 2, 1],
    ["bottom-last-fourth", 3, 1],
  ]),
  family("thirds-h", "Thirds · stacked", 1, 3, "Full-width horizontal thirds.", [
    ["top-third", 0, 0],
    ["middle-third", 0, 1],
    ["bottom-third", 0, 2],
  ]),
  family("edges-v", "Edge quarters", 4, 1, "Narrow side rails.", [
    ["left-quarter", 0, 0, "Leftmost 25% column"],
    ["right-quarter", 3, 0, "Rightmost 25% column"],
  ]),
  family("edges-h", "Edge quarters · stacked", 1, 4, "Narrow top / bottom rails.", [
    ["top-quarter", 0, 0, "Top 25% row"],
    ["bottom-quarter", 0, 3, "Bottom 25% row"],
  ]),
];

export const COMPOSED_LAYOUTS: ComposedLayout[] = [
  {
    key: "split",
    label: "Split",
    caption: "halves · 2 windows",
    grid: { cols: 2, rows: 1 },
    members: ["left", "right"],
  },
  {
    key: "stack",
    label: "Stack",
    caption: "stacked halves · 2 windows",
    grid: { cols: 1, rows: 2 },
    members: ["top", "bottom"],
  },
  {
    key: "thirds",
    label: "Thirds",
    caption: "three columns · 3 windows",
    grid: { cols: 3, rows: 1 },
    members: ["left-third", "center-third", "right-third"],
  },
  {
    key: "quadrants",
    label: "Quadrants",
    caption: "2 × 2 · 4 windows",
    grid: { cols: 2, rows: 2 },
    members: ["top-left", "top-right", "bottom-left", "bottom-right"],
  },
  {
    key: "six-up",
    label: "Six-up",
    caption: "3 × 2 · 6 windows",
    grid: { cols: 3, rows: 2 },
    members: [
      "top-left-third",
      "top-center-third",
      "top-right-third",
      "bottom-left-third",
      "bottom-center-third",
      "bottom-right-third",
    ],
  },
  {
    key: "eight-up",
    label: "Eight-up",
    caption: "4 × 2 · 8 windows",
    grid: { cols: 4, rows: 2 },
    members: [
      "top-first-fourth",
      "top-second-fourth",
      "top-third-fourth",
      "top-last-fourth",
      "bottom-first-fourth",
      "bottom-second-fourth",
      "bottom-third-fourth",
      "bottom-last-fourth",
    ],
  },
];

const PRESET_BY_NAME = new Map<string, TilePreset>();
for (const preset of SPECIAL_PRESETS) PRESET_BY_NAME.set(preset.name, preset);
for (const fam of TILE_FAMILIES) {
  for (const preset of fam.presets) PRESET_BY_NAME.set(preset.name, preset);
}

export function findPreset(name: string): TilePreset | undefined {
  return PRESET_BY_NAME.get(name);
}

const GRID_PATTERN = /^(grid:)?(\d+)x(\d+):(\d+),(\d+)$/i;

export interface ParsedGrid {
  cols: number;
  rows: number;
  col: number;
  row: number;
  rect: Rect;
}

export function parseGrid(input: string): ParsedGrid | null {
  const trimmed = input.trim();
  const match = trimmed.match(GRID_PATTERN);
  if (!match) return null;
  const oneBased = !match[1];
  const cols = Number(match[2]);
  const rows = Number(match[3]);
  let col = Number(match[4]);
  let row = Number(match[5]);
  if (oneBased) {
    col -= 1;
    row -= 1;
  }
  if (!cols || !rows) return null;
  if (col < 0 || col >= cols || row < 0 || row >= rows) return null;
  return {
    cols,
    rows,
    col,
    row,
    rect: cellRect(cols, rows, col, row),
  };
}

export function formatFraction(value: number): string {
  if (value === 0) return "0";
  if (value === 1) return "1";
  const rounded = Math.round(value * 1000) / 1000;
  return rounded.toString();
}

export function formatPct(value: number): string {
  return `${Math.round(value * 100)}%`;
}
