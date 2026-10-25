# Lattice surfaces: Opus art direction

October 24, 2026. Critique and direction only. No Studio or app source was changed.

**What I looked at:** the three native screenshots (13.04.36/42/49), the study source (`Lattice.tsx`, `lattice/{model.ts,Preview.tsx,lattice.css}`), the README, and the running prototype. I rendered `http://localhost:3050/embed/lattice` (Gallery, Machines › Hosts) in headless Chrome at 1600×1000 and looked at the screenshots. I did not click through Instrument, Paperlight, Overview or Layers.

## 1. Why it reads as model output

The problem goes deeper than the sage colour. The study starts from a component kit and fills it with data. It should start from the data, which here is physical hardware in physical places.

- **The geometry is false.** Each host gets an equal column, and each monitor is sized to fill its column. The 13.6" Air comes out nearly as wide as a 34" ultrawide, even though the real Air panel is about 290 mm wide and the ultrawide about 800 mm. Every screen is the same height and sits on one shelf. The tool's subject is spatial truth, and the study turns it into a product grid. The native Hosts canvas (screenshot 3) is rougher but more honest, because it at least keeps arrangement and real captures.
- **Status is spent on the default state.** "Reachable" appears four times in the canvas and four more times in the table. When every row says the same thing, the dot carries no information. This is the main dashboard tell.
- **Every noun gets a three-line caption.** Name, then mono resolution, then input. Host, then model, then status. At 8–10 px, this stacking of small grey type is the house style of generated admin UIs.
- **The screen contents talk about the product.** The fake desktops say "Your workspace, programmable." and show `struct Workspace {`. The product describes itself inside its own previews. That copy is marketing, and it is recursive.
- **The chrome is skeuomorphic but generic.** Stands, chins and soft bezel highlights make every monitor look like the same stock monitor icon. A U32J59x and an AW3425DWM should not look alike.
- **The palette is a template.** Charcoal with low-chroma sage is a tasteful default that belongs to no brand. Lattices already has a mark system: ink `#101518`/`#f2f2f2` with a single coral accent, `#ef6a47`. A green selection colour contradicts it directly.
- **Content is nested in cards, then a card, then a card.** Canvas card inside a section inside the app frame, each with a 1 px rule and an 8–10 px radius. Lists are tables with an icon column, a chevron and a check mark. Then the inspector repeats the selected row.

I disagree with one point in the framing: the fix is not a different mood. The study removed the one thing that makes this surface special, the real arrangement of real screens, and replaced it with polish.

## 2. Two directions

### A. Plan (physical scale)

- **First viewport:** one borderless canvas that fills the content area, with no card frame. Every display is drawn as a plain rectangle at true physical size, using millimetres from the diagonal and aspect ratio, at one shared scale. The lattice grid is the unit of measure: one cell is 100 mm. You can see at a glance that the Air is small and the ultrawides are large.
- **Hosts:** each machine's displays keep their own arrangement and are grouped inside a hairline hull drawn round them, like a room outline on a floor plan. The hostname sits on the plan in 15 px semibold at the hull's top-left. It is a label, not a header row. This Mac is the origin: its hull is solid and the remote hulls are dashed. Mac Studio and other headless hosts show as a small square with no screen.
- **Screen contents:** flat window rectangles taken from the window fixture, with the app icon and nothing else. There is no fake text or wallpaper. Offline shows a 45° hatch over the last-known geometry.
- **Lists:** one outline with no table. Hosts are 13 px rows and their displays are indented 12 px rows, each with a proportional silhouette at the same physical scale as the canvas. Metadata stays out of the list and appears only in the inspector. Selection is a coral 2 px leading bar plus ink text, with no fill.
- **Remove:** stands, chins, status pills, the column grid, the card frames, sage, and the redundant inspector header.

### B. Patchbay (signal flow)

- **First viewport:** a Desk-first view. Physical monitors stand on one baseline at physical scale, across the top. Hosts sit as compact tiles on a lower rail, and actual wires run from each host to the monitor input it is plugged into.
- **The wire grammar carries the product's distinctions.** A solid coral wire means "currently owns input". A solid ink wire means "plugged in but not active". A dotted wire means "View" (a capture stream). A dashed wire with an arrowhead means "Visit". The shared U32J59x shows its truth directly: two wires arrive and one is lit.
- **Lists:** these read like Rogue Amoeba's Loopback or Dante Controller. Rows are monitors and their ports are cells. It is dense and tabular, in SF Mono throughout.
- **Strength:** it states input ownership more clearly than anything else could. **Weakness:** it serves Desk well but Hosts badly. Remote displays grouped by machine turn into a tangle of wires, and the canvas stops looking like your desk.

## 3. Recommendation: A, with one idea taken from B

Plan works for both modes. Desk and Hosts become the same rectangles: Desk places them where they physically sit, and Hosts animates them into per-machine hulls. The objects stay the same and the grouping changes. From B, take only the **input notch**: a small coral tab on the bottom edge of the monitor that owns input, labelled with the owning host's initial. The other attached hosts get grey notches, so the shared U32J59x shows `M` lit and `a` dim.

**What makes it recognisably Lattices:** the grid is a real ruler. Monitors are drawn to scale against the lattice, and the brand's single coral accent marks exactly one thing at a time.

### Design contract for the Studio pass

1. **Scale:** 1 px = 2.5 mm at 100% zoom. Size each display from its diagonal and aspect ratio. Add `diagonalIn` to the fixtures (34, 34, 31.5, 13.6). Never stretch a display to fill space.
2. **Grid:** 40 px cells (100 mm), `#f2f2f2` at 4% opacity, and no dot grid. Display origins snap to the grid.
3. **Palette:** ink `#101518` background, `#f2f2f2` text with 64% and 40% steps, and rules at 8%. Coral `#ef6a47` is used only for selection, the input owner and the focus ring. Hue is not used anywhere else.
4. **Status:** reachable is the default and is not shown. Unreachable gets the hatch, 40% text, and the word "offline" once. A build mismatch appears only in the inspector.
5. **Type:** SF Pro, 15 semibold for hostnames on the canvas, 13 for list rows, 11 for display names under a selected screen only. SF Mono appears only in the inspector (resolution, build hash, address). The minimum size is 11 px.
6. **Screens:** a 1 px `#f2f2f2`/16% frame with a 2 px radius, and no bezel, chin or stand. Contents are flat window rectangles taken from the `windows` fixture, plus an app icon. No fake text.
7. **Selection:** one coral state is shared by the canvas, the list and the inspector: a 2 px outline on the canvas and a 2 px leading bar in the list. Selecting a host lights its hull, and selecting a display lights only that display.
8. **This Mac:** the hull is solid and pinned at the origin. Remote hulls are dashed. The local hull is never collapsed into a header strip.
9. **Verbs:** View, Visit and input appear only in the inspector as three separate labelled controls. The input notch is the only representation of input on the canvas.
10. **Remove:** the study's marketing heading, the treatment cards, the "Select a host…" hint, status dots, chevrons and check marks.
11. **Honesty:** add a footer that reads "Illustrative fixtures". Window geometry comes only from `model.ts`, and no screen shows text the user did not write.
