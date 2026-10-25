# Lattices: refine the current app

## User correction — October 24

“Opus's inspiration was like just way way out of whack. It's like an entirely different design language. It needs to be immersed in what Lattice's already is ... just improvements on the current current design.”

The deliverable is an implemented interactive Studio design, not a critique or a design essay. The rejected Plan is not the starting point. The native app and the user's screenshots are the visual authority. The user wants Studio first; do not implement, build, or relaunch the native app.

## Immerse before editing

Open and look at all three supplied screenshots, not just their filenames. These are the current visual world to preserve:

- Overview: `/Users/arach/Library/Application Support/Talkie.dev/Screenshots/Talkie Capture - 2026-10-24 13.04.36 - Window Lattices - 1760x760 - 82594c60 t0ms.png`
- Layers: `/Users/arach/Library/Application Support/Talkie.dev/Screenshots/Talkie Capture - 2026-10-24 13.04.42 - Window Lattices - 1760x760 - 96ba5abd t0ms.png`
- Machines: `/Users/arach/Library/Application Support/Talkie.dev/Screenshots/Talkie Capture - 2026-10-24 13.04.49 - Window Lattices - 1760x760 - 3e5a2a0c t0ms.png`

Read these current native sources under `/Users/arach/dev/lattices` read-only, plus the palette and typography definitions they use:

- `apps/mac/Sources/AppShell/MachinesPageView.swift`
- `apps/mac/Sources/AppShell/DeskCanvas.swift`
- `apps/mac/Sources/AppShell/MachineArrangementCanvas.swift`
- `apps/mac/Sources/Core/Overlays/Overview/OverviewDesk.swift`
- Locate the current Layers overview and AppShell chrome, and use their existing hierarchy.

## Direction

Make a recognizable, refined next version of those screenshots. Preserve the dark graphite palette, subdued green live state, macOS system typography, small mono metadata, native-style buttons, left navigation, compact page toolbar, subtle dotted canvas and monitor proportions. Keep Machines' canvas above its machine table. Keep Overview's layers rail, spatial displays and desktop strip. Keep Layers' workspace context and display preview. Host and monitor distinctions must remain legible within this existing language.

Focus the design effort on precision:

1. Beautiful but restrained monitor edges and screenshot presentation; consistent corner radii, quiet highlights, readable captions that do not compete with content.
2. Clearer host names, input/source labels, selected/online/elsewhere states, retaining the actual product semantics.
3. Better spacing, column alignment and row hierarchy in the tables below; coherent subtle selection shared with the canvas.
4. A well-composed canvas that fits the original 1760×760 window with useful table rows still visible.
5. Consistent treatment across Machines Desk/Hosts, Overview and Layers without restructuring the app.

Do not use Plan's drafting-board theme, coral accent, physical millimetre rulers, new top navigation, oversized inspector, or decorative hardware silhouettes. Do not bring back Gallery/Paperlight or invent another named visual world. Avoid green washes, gratuitous gradients, giant headings and new card stacks. A small green accent for live state is already part of the app; fidelity to that existing identity is the point.

Screens can use existing illustrative window previews, but the overall composition and chrome must strongly resemble the user's screenshots. Preserve known distinction between viewing a host, VNC, visiting, and physical input ownership. Offline and unknown input states remain explicit. Do not introduce fake live claims.

## Implementation and ownership

Work only in `/Users/arach/dev/lattices-design`, branch `codex/web-workspace`. Follow its AGENTS.md. This checkout is dirty. Baseline hash/copy snapshot: `/tmp/lattice-native-refinement-20261024-213235`. Preserve every unrelated file and all earlier studies.

You own the actual design implementation in:

- `design/studio/src/studio/studies/Lattice.tsx`
- `design/studio/src/studio/studies/lattice/` (new Refined component and scoped CSS preferred; retain rejected Plan files as history)
- `studies/lattice-surfaces-2026-10-24/README.md`
- assets/captures under this study directory if needed

Default the live route to **Refined**. Put earlier experiments behind a discreet archive control, explicitly rejected history. Ideally expose a **Current / Refined** comparison with the user's screenshot for each corresponding surface, so the continuity is easy to assess; use the existing study asset route after inspecting it, and copy screenshots unchanged if needed. Keep the review controls outside the mock app.

Existing route `http://localhost:3050/embed/lattice`, Studio `http://localhost:3050/studio/studies/lattice`. Server is already running. Do not touch server dependencies, Scout, native code, or unrelated Studio studies. No new worktree. No commits or pushes.

## Completion

Implement the design fully and make the default preview usable. Report changed files and the route. Parent handles final browser verification and any narrow fit fixes; do not get stuck on a screenshot command again. Run only a bounded check if quick. Full Studio typecheck already has the unrelated `studio/live/server` import error; do not fix it. Provide actual implemented design, not a critique. Native remains unchanged.
