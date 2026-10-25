# Lattices architectural title pair

A reusable title treatment using the approved generated L-shaped building as concept artwork. It does not replace the official Lattices logo.

Default: 3440 × 1440, 30 fps, a 2.5-second intro and a 2.5-second outro. Silent. The artwork stays fixed while the text settles gently into place.

## Customize

Edit `config.json`: `topic`, optional `endingText` (empty by default), canvas `width` and `height`, `introDuration`, `outroDuration`, and `fps`. Keep text short and check its fit. For 16:9, use 1920 × 1080; only the default ultrawide exports have been visually verified.

```sh
node build.mjs
npm run check
npm run dev
npm run render -- --quality delivery --output titles-preview.mp4
```

`build.mjs` generates `index.html` from `template.html.template`. It scales and centers the layout for the configured canvas. `edit-points.json` records the intro/outro boundary. The supplied individual MP4s are ready to append to future video edits; the combined preview plays them back to back.

## Included dependencies

Artwork, font files and GSAP are frozen under `assets/`. Font license and asset provenance are included. The source artwork pixels are unchanged; only the blank graphite margins are blended in the HTML composition. No private recording or product repository is required. HyperFrames CLI may need an initial npm download.
