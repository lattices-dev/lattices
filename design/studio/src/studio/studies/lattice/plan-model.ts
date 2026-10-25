// Plan fixtures. Physical sizes come from each panel's published diagonal and
// pixel aspect; desk positions, host arrangements and windows are illustrative.
// Nothing here reads a daemon or changes a real workspace.

export type PlanHostID = "local" | "arts-mini" | "archie" | "air";
export type MonitorID = "aw" | "u32" | "dell" | "air-builtin";

export interface Monitor {
  id: MonitorID;
  name: string;
  diagonalIn: number;
  px: [number, number];
  /** Illustrative desk elevation: left edge and lift above the desk, in mm. */
  desk: { x: number; lift: number };
  inputs: { host: PlanHostID; port: string }[];
  /** Host whose input the panel is showing; null when Lattices hasn't read it. */
  owner: PlanHostID | null;
  builtin?: boolean;
}

export interface PlanHost {
  id: PlanHostID;
  name: string;
  model: string;
  platform: string;
  build: string;
  /** Front face of a headless computer, in mm, drawn at canvas scale. */
  body?: { w: number; h: number };
  vnc: boolean;
  visit: boolean;
  /** The host's own display arrangement, offsets in mm (illustrative). */
  arrangement: { monitor: MonitorID; x: number; y: number }[];
}

export interface PlanWindow {
  id: number;
  host: PlanHostID;
  monitor: MonitorID;
  app: string;
  kind: "terminal" | "code" | "browser" | "notes";
  title: string;
  layer?: string;
  desktop: number;
  /** Fractions of the display: x, y, w, h. */
  frame: [number, number, number, number];
}

export const mmSize = (m: Pick<Monitor, "diagonalIn" | "px">) => {
  const diag = m.diagonalIn * 25.4;
  const ratio = m.px[0] / m.px[1];
  const h = diag / Math.sqrt(1 + ratio * ratio);
  return { w: h * ratio, h };
};

export const monitors: Monitor[] = [
  { id: "aw", name: "AW3425DWM", diagonalIn: 34, px: [3440, 1440], desk: { x: 0, lift: 105 },
    inputs: [{ host: "arts-mini", port: "HDMI 2" }], owner: "arts-mini" },
  { id: "u32", name: "U32J59x", diagonalIn: 31.5, px: [3840, 2160], desk: { x: 830, lift: 80 },
    inputs: [{ host: "local", port: "HDMI 1" }, { host: "arts-mini", port: "HDMI 2" }], owner: "arts-mini" },
  { id: "dell", name: "DELL S3422DWG", diagonalIn: 34, px: [3440, 1440], desk: { x: 1560, lift: 105 },
    inputs: [{ host: "local", port: "DisplayPort" }, { host: "archie", port: "HDMI 2" }], owner: "local" },
  { id: "air-builtin", name: "Built-in Retina", diagonalIn: 13.6, px: [2560, 1664], desk: { x: 2440, lift: 8 },
    inputs: [{ host: "air", port: "Built-in" }], owner: "air", builtin: true },
];

export const planHosts: PlanHost[] = [
  { id: "local", name: "This Mac", model: "Mac Studio", platform: "macOS", build: "32f063cb", body: { w: 197, h: 95 }, vnc: false, visit: false,
    arrangement: [{ monitor: "u32", x: 0, y: 0 }, { monitor: "dell", x: 760, y: 58 }] },
  { id: "arts-mini", name: "arts-mini", model: "Mac mini", platform: "macOS", build: "e053d49c", body: { w: 127, h: 50 }, vnc: true, visit: false,
    arrangement: [{ monitor: "aw", x: 0, y: 0 }, { monitor: "u32", x: 850, y: 40 }] },
  { id: "archie", name: "archie", model: "Linux workstation", platform: "Linux · Hyprland", build: "3354caa6", vnc: true, visit: true,
    arrangement: [{ monitor: "dell", x: 0, y: 0 }] },
  { id: "air", name: "air", model: "MacBook Air", platform: "macOS", build: "32f063cb", vnc: true, visit: false,
    arrangement: [{ monitor: "air-builtin", x: 0, y: 0 }] },
];

export const planWindows: PlanWindow[] = [
  { id: 1, host: "local", monitor: "dell", app: "Ghostty", kind: "terminal", title: "fab · capture pipeline", layer: "fab", desktop: 1, frame: [0.015, 0.06, 0.48, 0.9] },
  { id: 2, host: "local", monitor: "dell", app: "Ghostty", kind: "terminal", title: "mini: fab · desk", layer: "fab", desktop: 1, frame: [0.505, 0.06, 0.48, 0.9] },
  { id: 3, host: "local", monitor: "u32", app: "Xcode", kind: "code", title: "DeskCanvas.swift", layer: "Lattices", desktop: 1, frame: [0.03, 0.07, 0.62, 0.86] },
  { id: 4, host: "local", monitor: "u32", app: "Ghostty", kind: "terminal", title: "lattices · shell", layer: "Lattices", desktop: 1, frame: [0.67, 0.07, 0.3, 0.52] },
  { id: 5, host: "local", monitor: "u32", app: "Safari", kind: "browser", title: "Release notes", layer: "Lattices", desktop: 2, frame: [0.12, 0.08, 0.76, 0.84] },
  { id: 6, host: "local", monitor: "dell", app: "Notes", kind: "notes", title: "Talkie · capture ideas", layer: "Talkie", desktop: 2, frame: [0.3, 0.12, 0.4, 0.76] },
  { id: 11, host: "arts-mini", monitor: "aw", app: "Ghostty", kind: "terminal", title: "arts-mini: fab · desk", desktop: 1, frame: [0.02, 0.06, 0.6, 0.9] },
  { id: 12, host: "arts-mini", monitor: "aw", app: "Safari", kind: "browser", title: "Spotify · Discover Weekly", desktop: 1, frame: [0.64, 0.06, 0.34, 0.9] },
  { id: 13, host: "arts-mini", monitor: "u32", app: "Xcode", kind: "code", title: "Session.swift", desktop: 1, frame: [0.04, 0.07, 0.92, 0.86] },
  { id: 21, host: "archie", monitor: "dell", app: "kitty", kind: "terminal", title: "nvim · hyprland.conf", desktop: 1, frame: [0.006, 0.015, 0.494, 0.97] },
  { id: 22, host: "archie", monitor: "dell", app: "kitty", kind: "terminal", title: "btop", desktop: 1, frame: [0.506, 0.015, 0.488, 0.479] },
  { id: 23, host: "archie", monitor: "dell", app: "firefox", kind: "browser", title: "Arch Wiki", desktop: 1, frame: [0.506, 0.506, 0.488, 0.479] },
  { id: 31, host: "air", monitor: "air-builtin", app: "Safari", kind: "browser", title: "Calendar", desktop: 1, frame: [0.06, 0.08, 0.6, 0.8] },
  { id: 32, host: "air", monitor: "air-builtin", app: "Ghostty", kind: "terminal", title: "air · shell", desktop: 1, frame: [0.5, 0.3, 0.45, 0.6] },
];

export const planLayers = ["Lattices", "fab", "Talkie"];
/** Desktops per local display (illustrative). */
export const desktopCount: Partial<Record<MonitorID, number>> = { u32: 3, dell: 4 };
