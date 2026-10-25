# Lattices picture-in-picture demo

A silent, 30-second edit of the October 18 screen recording. The video preserves the full 3440 × 1440 desktop and presents three interactions at their original speed.

- `renders/Lattices-picture-in-picture-30s.mp4`: finished 30 fps export.
- `index.html` and `compositions/`: editable HyperFrames timeline.
- `BRIEF.md`: edit decisions and source ranges.
- `SOURCE.md`: source recording provenance.
- `assets/screen-recording.mp4`: intact local source copy.

Preview: `npx hyperframes preview --background`

Check: `npm run check`

Render: `npm run render -- --quality delivery --fps 30 --video-frame-format png --output renders/Lattices-picture-in-picture-30s.mp4`
