// Refined fixtures. Names, layers and counts follow the October 24 native
// screenshots; window titles, frames and pictures are illustrative. Nothing
// here reads a daemon or changes a real workspace.

export type RefinedSurface = "Overview" | "Layers" | "Machines";
export type HostId = "local" | "air" | "archie" | "arts-mini";
export type MonitorId = "dell" | "u32" | "aw" | "air";
export type Picture = "blank" | "hypr" | "term-mix" | "code" | "photo";

export interface RefinedHost {
  id: HostId;
  name: string;
  platform: string;
  /** Shown only when it says more than the name, as in MachineRow. */
  address?: string;
  build: string;
  drift?: string;
  visit: boolean;
  vnc: boolean;
}

export const rHosts: RefinedHost[] = [
  { id: "local", name: "This Mac", platform: "macOS", build: "0.15.1 · 32f063cb", visit: false, vnc: false },
  { id: "air", name: "air", platform: "macOS", build: "0.15.1 · 32f063cb", visit: false, vnc: true },
  { id: "archie", name: "archie", platform: "Linux", address: "127.0.0.1:5288", build: "0.15.1 · 3354caa6", visit: true, vnc: true },
  { id: "arts-mini", name: "arts-mini", platform: "macOS", build: "0.15.1 · e053d49c", drift: "Different build", visit: false, vnc: true },
];

export interface PhysicalMonitor {
  id: MonitorId;
  model: string;
  resolution: string;
  inputs: { host: HostId; port: string }[];
  /** Host whose input is on screen. Null when the input hasn't been read. */
  owner: HostId | null;
  builtin?: boolean;
  /** Desk position in millimetres (illustrative placement, real panel sizes). */
  desk: { x: number; y: number; w: number; h: number };
}

export const rMonitors: PhysicalMonitor[] = [
  { id: "aw", model: "AW3425DWM", resolution: "3440 × 1440", inputs: [{ host: "arts-mini", port: "HDMI-2" }], owner: "arts-mini", desk: { x: 0, y: 62, w: 797, h: 333 } },
  { id: "u32", model: "U32J59x", resolution: "3840 × 2160", inputs: [{ host: "local", port: "HDMI-1" }, { host: "arts-mini", port: "HDMI-2" }], owner: "arts-mini", desk: { x: 817, y: 3, w: 697, h: 392 } },
  { id: "dell", model: "DELL S3422DWG", resolution: "3440 × 1440", inputs: [{ host: "local", port: "DP-1" }, { host: "archie", port: "HDMI-2" }], owner: "local", desk: { x: 1534, y: 62, w: 797, h: 333 } },
  { id: "air", model: "Built-in", resolution: "2560 × 1664", inputs: [{ host: "air", port: "Built-in" }], owner: "air", builtin: true, desk: { x: 2351, y: 207, w: 290, h: 188 } },
];

/** Each host's own display arrangement, in canvas points (illustrative). */
export interface HostGroup {
  host: HostId;
  x: number;
  y: number;
  tiles: { monitor: MonitorId; x: number; y: number; w: number; h: number; picture: Picture; main?: boolean }[];
}

export const hostGroups: HostGroup[] = [
  { host: "archie", x: 40, y: 26, tiles: [{ monitor: "dell", x: 0, y: 0, w: 264, h: 110, picture: "hypr" }] },
  { host: "air", x: 328, y: 18, tiles: [{ monitor: "air", x: 0, y: 0, w: 196, h: 127, picture: "photo" }] },
  { host: "arts-mini", x: 0, y: 172, tiles: [
    { monitor: "aw", x: 0, y: 16, w: 264, h: 110, picture: "term-mix" },
    { monitor: "u32", x: 270, y: 0, w: 290, h: 163, picture: "code" },
  ] },
  { host: "local", x: 652, y: 36, tiles: [
    { monitor: "u32", x: 0, y: 0, w: 290, h: 163, picture: "blank" },
    { monitor: "dell", x: 296, y: 30, w: 264, h: 110, picture: "blank", main: true },
  ] },
];

export const pictureOn: Partial<Record<HostId, Partial<Record<MonitorId, Picture>>>> = {
  archie: { dell: "hypr" }, air: { air: "photo" }, "arts-mini": { aw: "term-mix", u32: "code" },
};

export const hostWindows: Record<Exclude<HostId, "local">, { app: string; title: string; monitor: MonitorId }[]> = {
  air: [{ app: "Safari", title: "Calendar", monitor: "air" }, { app: "Ghostty", title: "air · shell", monitor: "air" }],
  archie: [{ app: "kitty", title: "nvim · hyprland.conf", monitor: "dell" }, { app: "kitty", title: "btop", monitor: "dell" }, { app: "firefox", title: "Arch Wiki", monitor: "dell" }],
  "arts-mini": [{ app: "Ghostty", title: "arts-mini: fab · desk", monitor: "aw" }, { app: "Spotify", title: "Discover Weekly", monitor: "aw" }, { app: "Xcode", title: "Session.swift", monitor: "u32" }],
};

// MARK: Overview and Layers

export type WindowKind = "terminal" | "editor" | "browser" | "other";
export type LocalDisplay = "u32" | "dell" | "agent";

export interface LocalDisplayInfo { id: LocalDisplay; name: string; size: string; w: number; h: number; desktops: number; virtual?: boolean; main?: boolean }

export const localDisplays: LocalDisplayInfo[] = [
  { id: "u32", name: "U32J59x", size: "3,840×2,160", w: 3840, h: 2160, desktops: 3 },
  { id: "dell", name: "DELL S3422DWG", size: "3,440×1,440", w: 3440, h: 1440, desktops: 5, main: true },
  { id: "agent", name: "Action Agent Layer", size: "1,920×1,200", w: 1920, h: 1200, desktops: 1, virtual: true },
];

export interface LocalWindow {
  id: number;
  app: string;
  title: string;
  kind: WindowKind;
  layer: string | null;
  display: LocalDisplay;
  desktop: number;
  frame: [number, number, number, number];
  rule?: boolean;
}

export const localWindows: LocalWindow[] = [
  { id: 1, app: "Ghostty", title: "fab", kind: "terminal", layer: "fab", display: "dell", desktop: 1, frame: [0, 0, 0.5, 1], rule: true },
  { id: 2, app: "Ghostty", title: "mini: fab · desk", kind: "terminal", layer: "fab", display: "dell", desktop: 1, frame: [0.5, 0, 0.5, 1], rule: true },
  { id: 3, app: "Ghostty", title: "lattices · shell", kind: "terminal", layer: "Ghostty", display: "u32", desktop: 2, frame: [0.55, 0.08, 0.4, 0.5], rule: true },
  { id: 4, app: "Xcode", title: "DeskCanvas.swift", kind: "editor", layer: null, display: "u32", desktop: 1, frame: [0.04, 0.06, 0.6, 0.86] },
  { id: 5, app: "Safari", title: "Release notes", kind: "browser", layer: null, display: "u32", desktop: 1, frame: [0.62, 0.12, 0.34, 0.7] },
  { id: 6, app: "Zed", title: "MachinesPageView.swift", kind: "editor", layer: null, display: "dell", desktop: 2, frame: [0.05, 0.06, 0.55, 0.88] },
  { id: 7, app: "Chrome", title: "lattices.dev", kind: "browser", layer: null, display: "dell", desktop: 3, frame: [0.2, 0.08, 0.6, 0.84] },
  { id: 8, app: "Notes", title: "Capture ideas", kind: "other", layer: null, display: "agent", desktop: 1, frame: [0.1, 0.1, 0.8, 0.8] },
  { id: 9, app: "Ghostty", title: "archie · ssh", kind: "terminal", layer: null, display: "u32", desktop: 3, frame: [0.1, 0.1, 0.5, 0.6] },
  { id: 10, app: "Talkie", title: "Talkie", kind: "other", layer: null, display: "dell", desktop: 2, frame: [0.64, 0.1, 0.32, 0.6] },
];

export const layerNames = ["Lattices", "fab", "Talkie", "Scout", "usetalkie.com", "Hudson", "arc", "agentlist.io", "Ghostty", "Talkie shots"];
export const ALL = "All windows";
export const UNASSIGNED = "Unassigned";
