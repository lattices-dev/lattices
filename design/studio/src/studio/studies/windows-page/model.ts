/* An invented desk for the Windows page study: two monitors, a project called
   tideline, and a few windows off the current desktops. Frames are fractions of
   the display. */

export type DisplayID = "left" | "wide";

export interface Display {
  id: DisplayID;
  name: string;
  resolution: string;
  ratio: number;
  desktops: number;
  current: number;
}

export interface Win {
  id: string;
  app: string;
  title: string;
  display: DisplayID | null;
  desktop: number | null;
  state: "visible" | "minimized" | "hidden";
  layer?: string;
  frame?: [number, number, number, number];
}

export const displays: Display[] = [
  { id: "left", name: "U32J59x", resolution: "1920 × 1080", ratio: 16 / 9, desktops: 1, current: 1 },
  { id: "wide", name: "DELL S3422DWG", resolution: "3440 × 1440", ratio: 43 / 18, desktops: 7, current: 2 },
];

export const windows: Win[] = [
  { id: "w1", app: "Notes", title: "Tideline release checklist", display: "left", desktop: 1, state: "visible", layer: "Tideline", frame: [0.04, 0.06, 0.92, 0.88] },
  { id: "w2", app: "Ghostty", title: "tideline — bun dev", display: "wide", desktop: 2, state: "visible", layer: "Tideline", frame: [0, 0, 0.34, 0.62] },
  { id: "w3", app: "Zed", title: "tideline/src/harbor/sync.ts", display: "wide", desktop: 2, state: "visible", layer: "Tideline", frame: [0.34, 0, 0.36, 1] },
  { id: "w4", app: "Chrome", title: "localhost:5173 — Tideline", display: "wide", desktop: 2, state: "visible", layer: "Tideline", frame: [0.7, 0, 0.3, 1] },
  { id: "w5", app: "Ghostty", title: "tideline — bun test --watch", display: "wide", desktop: 2, state: "visible", layer: "Tideline", frame: [0, 0.62, 0.34, 0.38] },
  { id: "w6", app: "Linear", title: "TID-142 Harbor sync drops the last tide", display: "wide", desktop: 1, state: "visible", layer: "Planning" },
  { id: "w7", app: "Slack", title: "#tideline", display: "wide", desktop: 1, state: "visible", layer: "Planning" },
  { id: "w8", app: "Figma", title: "Tideline — Charts", display: "wide", desktop: 3, state: "visible" },
  { id: "w9", app: "Chrome", title: "NOAA Tides & Currents", display: null, desktop: null, state: "minimized" },
  { id: "w10", app: "System Settings", title: "Displays", display: null, desktop: null, state: "hidden" },
];

export const layers = ["Tideline", "Planning"];

export const placements = [
  { id: "left", label: "Left half" },
  { id: "right", label: "Right half" },
  { id: "max", label: "Fill" },
  { id: "center", label: "Center" },
] as const;

export type Group = { key: string; label: string; detail: string; windows: Win[] };

/** One group per desktop that has windows, then everything not on a desktop. */
export function groupByDesktop(list: Win[]): Group[] {
  const groups: Group[] = [];
  for (const d of displays) {
    for (let n = 1; n <= d.desktops; n++) {
      const here = list.filter(w => w.display === d.id && w.desktop === n);
      if (!here.length) continue;
      groups.push({ key: `${d.id}-${n}`, label: `Desktop ${n}`, detail: d.current === n ? `${d.name} · showing` : d.name, windows: here });
    }
  }
  const off = list.filter(w => w.display === null);
  if (off.length) groups.push({ key: "off", label: "Minimized and hidden", detail: "", windows: off });
  return groups;
}

export const onScreen = (w: Win) => w.state === "visible" && w.display !== null && displays.find(d => d.id === w.display)?.current === w.desktop;
