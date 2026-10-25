/** The original studies stay editable in one place; Studio owns discovery. */
export const SPACE_NAVIGATION_HREF = "/studio/studies/space-navigation";
export const SPACE_NAVIGATION_ASSETS = "/study-assets/space-navigation";
export const SPACE_NAVIGATION_SOURCE = "studies/space-navigation-2026-10-13";

export const spaceNavigationStudies = [
  { slug: "opus-previews", title: "Fixed-center filmstrip", author: "Opus", group: "Previews", file: "opus-previews/index.html", description: "Every desktop in a filmstrip. Compare a fixed center with a traveling focus, against a quiet backdrop." },
  { slug: "previews", title: "Desktop previews", author: "Codex", group: "Previews", file: "previews/index.html", description: "Filmstrip, window atlas, and neighbor peek. The desktop stays still while preview shapes carry the change." },
  { slug: "pull-back", title: "Pull back → canvas", author: "Codex", group: "Canvas", file: "pull-back/index.html", description: "A connected grid of workspaces, a fixed lens, and a minimap at the bottom left." },
  { slug: "aperture-lens", title: "Aperture lens", author: "Opus + Codex", group: "Canvas", file: "aperture-lens/index.html", description: "Opus’s aperture with a new cut-glass material pass. Compare the original and sharper Lattices treatment at any zoom." },
  { slug: "spatial", title: "Beyond the rail", author: "Codex", group: "Spatial motion", file: "spatial/index.html", description: "Passing light, threshold, and focus echo explore how the whole desktop can acknowledge navigation." },
  { slug: "opus-spatial", title: "Spatial desktop", author: "Opus", group: "Spatial motion", file: "opus-spatial/index.html", description: "Flanks, landing, and ghost carry: three independent treatments beyond the top rail." },
  { slug: "rail", title: "Rail motion", author: "Codex", group: "Early explorations", file: "index.html", description: "Shuttle, viewport, and quiet compass, with the original native baseline recording for comparison." },
  { slug: "opus", title: "Odometer, lens & wake", author: "Opus", group: "Early explorations", file: "opus/index.html", description: "Number flips, a stretching focus, and a remembered origin for rapid desktop traversal." },
] as const;
