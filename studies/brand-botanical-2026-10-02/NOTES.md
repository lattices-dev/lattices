# Workspace conservatory

A local Lattices botanical brand and component study, October 2, 2026. The fern direction was approved for further exploration. This is a preview, not a production site or native-app change. Workspace rows contain illustrative data and have no connection to the user's Mac.

## What came from Scout

Read and inspected on Arts Mini in `/Users/art/dev/openscout`:

- `design/scout-backgrounds`: warm graphite, finely engraved botanical instruments, a quiet canvas, and four treatments derived from one illustration. Source rendering engine copied to `references/scout/components/backgrounds.js` and adapted into `renderer.js`.
- `design/portal-studies/ascii-render-lab.html`: neutral one-pixel slider tracks, nine-pixel thumbs, tabular readouts, and accent used sparingly.
- `design/portal-studies/scout-local-quiet-ledger.html`: hairline workspace rows, restrained hover tint, and warm paper/ink surfaces.
- `design/studio/components/RuntimePicker.tsx` and `runtime-picker.css`: compact stable-width readout, subdivided option panel, neutral selected rows, directional entry, arrow-key navigation and Escape dismissal. Adapted as a simpler single-group rendering picker, not a port of runtime logic.
- `design/studio/app/atoms/inspector-section/page.tsx`: aligned section labels and concise trailing metadata.

Reference snapshots are saved under `references/scout/components`. Scout preview inspected at remote ports 43143 and 43140. These are development studies; their existence does not imply production use.

## Lattices decisions

- Preserve the canonical three-by-three L mark.
- Use the approved Workspace Fern illustration, not Scout's subject or mascot.
- Give precision to controls and type, while keeping the organic detail inside the illustration.
- Illustration, ASCII, ordered dither and engraved lines share the same source image. The latter three are actual luminance-based canvas treatments.
- The page preview softens the field behind words. Export always saves the artwork without the sample text.
- Keyboard-operable rendering picker, labelled controls, reduced-motion handling, responsive layout, and explicit load/export failure states.

## Preview

From this directory: `python3 -m http.server 43145 --bind 127.0.0.1`

Open `http://127.0.0.1:43145/`. No packages, build step, or external services are required.
