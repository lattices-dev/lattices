export type Treatment = "gallery" | "instrument" | "paperlight";
export type Surface = "Machines" | "Overview" | "Layers";
export type HostID = "local" | "air" | "archie" | "arts-mini";

export interface Display {
  id: string;
  name: string;
  resolution: string;
  ratio: number;
  input?: string;
  scene: "code" | "terminal" | "landscape" | "windows" | "browser";
}

export interface Host {
  id: HostID;
  name: string;
  platform: string;
  model: string;
  connection: string;
  build: string;
  displays: Display[];
}

// Illustrative fixtures, using the names and display families in the supplied
// screenshots. This study never reads a daemon or changes a real workspace.
export const hosts: Host[] = [
  { id: "local", name: "This Mac", platform: "macOS", model: "Mac Studio", connection: "Local computer", build: "32f063cb", displays: [
    { id: "local-main", name: "DELL S3422DWG", resolution: "3440 × 1440", ratio: 2.39, scene: "windows", input: "DisplayPort" },
    { id: "local-side", name: "U32J59x", resolution: "3840 × 2160", ratio: 1.78, scene: "code", input: "HDMI 1" },
  ] },
  { id: "air", name: "air", platform: "macOS", model: "MacBook Air", connection: "Nearby", build: "32f063cb", displays: [
    { id: "air-main", name: "Built-in display", resolution: "2560 × 1664", ratio: 1.54, scene: "landscape" },
  ] },
  { id: "archie", name: "archie", platform: "Linux", model: "Linux workstation", connection: "Connected host", build: "3354caa6", displays: [
    { id: "archie-main", name: "DELL S3422DWG", resolution: "3440 × 1440", ratio: 2.39, scene: "terminal", input: "HDMI 2" },
  ] },
  { id: "arts-mini", name: "arts-mini", platform: "macOS", model: "Mac mini", connection: "Nearby", build: "e053d49c", displays: [
    { id: "mini-main", name: "AW3425DWM", resolution: "3440 × 1440", ratio: 2.39, scene: "terminal", input: "HDMI 2" },
    { id: "mini-side", name: "U32J59x", resolution: "3840 × 2160", ratio: 1.78, scene: "code", input: "HDMI 2" },
  ] },
];

export const windows = [
  { id: 1, app: "Ghostty", title: "fab · capture pipeline", layer: "fab", display: "DELL S3422DWG", space: 1, kind: "terminal" },
  { id: 2, app: "Ghostty", title: "mini: fab · desk", layer: "fab", display: "DELL S3422DWG", space: 1, kind: "terminal" },
  { id: 3, app: "Code", title: "RemoteSession.swift", layer: "Lattices", display: "U32J59x", space: 1, kind: "code" },
  { id: 4, app: "Safari", title: "Lattices · documentation", layer: "Lattices", display: "U32J59x", space: 2, kind: "browser" },
];

export const treatments = [
  { id: "gallery" as const, name: "Gallery", character: "Quiet depth. Clear ownership.", description: "A separate nameplate for every host, softly lit monitor bezels, and one selection that carries into the list.", strength: "The clearest everyday direction.", tradeoff: "Uses more canvas space to make ownership unmistakable." },
  { id: "instrument" as const, name: "Instrument", character: "Precise. Compact. Purposeful.", description: "Host rails, fine registration marks, and compact display groups. Coral marks selection; availability stays quiet.", strength: "The most information in the least space.", tradeoff: "More technical, with a denser reading rhythm." },
  { id: "paperlight" as const, name: "Paperlight", character: "Warm surfaces. Room to breathe.", description: "A warm drawing surface, soft graphite monitor frames, and generously spaced rows that feel more like a native library.", strength: "The gentlest surface for a long session.", tradeoff: "A larger departure from the current dark canvas." },
];
