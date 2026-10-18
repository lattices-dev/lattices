# Lattices field guide — batch 02

Three silent, illustrated explainers for aspiring Mac power users. Each runs for 40 seconds at 1280×720 and 30 fps, with four ten-second teaching beats. The persistent disclosure identifies every scene as an illustrative example, not a live desktop recording.

| Slug | Topic | Visual mechanism |
| --- | --- | --- |
| `macos-automation-permissions` | Three permissions, three different jobs | One tool connects to separate control, capture, and app-command branches. |
| `observe-act-verify` | A click is not a completed task | An illustrated Save action is accepted, an error appears, and a bounded recovery sequence follows. |
| `window-snapping-vs-tiling` | Snapping, tiling, and workspaces | A chosen window snaps left; a tiler reflows as a third window joins; related windows form a named group. |

## Source and authoring

`videos.json` owns the teaching copy and transcript labels. `build.mjs` generates the three independently previewable HyperFrames projects, their per-film brief/storyboard/design specification, captions, and full transcripts. `sources.json` records the official documentation and claim boundaries reviewed on October 2, 2026. The editorial review is also recorded in `docs/seo/explainer-batch-02.md` at the repository root. It is a documentation review, not a native app benchmark.

The films continue the accepted paper-and-green visual treatment and reuse locally frozen Montserrat and IBM Plex Mono font files, with their SIL Open Font Licenses. The compositions use a graphics sub-composition and a caption sub-composition, with paused, seekable GSAP timelines. All meaningful motion is derived from composition time. Each mechanism settles into a reading hold before the next teaching beat.

The new projects were initialized and checked against HyperFrames **0.8.112**, which the latest-version probe confirmed on the review date. Their package scripts pin that version. The earlier batch retains its own pin. The permission connector uses the registry's SVG line-draw primitive as a reference; its installed source is retained under `compositions/components/`.

No narration or music is present. The baked-in explanation, optional WebVTT captions, and full transcript carry the same teaching content. Full transcripts additionally enumerate the on-screen diagram labels. Browser captions can overlay baked-in text, so the full transcript should remain available alongside the player.

## Rebuild and check

Run from the repository root:

```sh
node studies/seo-explainers/batch-02/build.mjs
for slug in macos-automation-permissions observe-act-verify window-snapping-vs-tiling; do
  npx --yes hyperframes@0.8.112 check "studies/seo-explainers/batch-02/$slug" --snapshots --strict --json > "studies/seo-explainers/batch-02/evidence/$slug-check.json"
done
npx --yes hyperframes@0.8.112 keyframes studies/seo-explainers/batch-02/window-snapping-vs-tiling --json > studies/seo-explainers/batch-02/evidence/window-keyframes.json
npx --yes hyperframes@0.8.112 keyframes studies/seo-explainers/batch-02/window-snapping-vs-tiling --selector '#snap-selected' --shot studies/seo-explainers/batch-02/evidence/window-snap-motion.png --layout strip --from 1 --to 5 --samples 5
npx --yes hyperframes@0.8.112 preview studies/seo-explainers/batch-02/macos-automation-permissions --background --port 5193 --no-open
```

Use another available preview port if 5193 is occupied. Run initial `npx` installs serially: concurrent installs into the same npm cache can race. Once installed, independent checks can use the resolved CLI directly.

## Render on hetz

The isolated render directory is `/root/lattices-seo-explainers-batch02-20261002`. The workflow uses the existing `/opt/node22/bin` runtime, cached headless Chrome, and `/usr/bin/ffmpeg`. It does not replace other remote jobs. This source tree contains no credentials.

```sh
rsync -az --exclude snapshots --exclude .hyperframes studies/seo-explainers/batch-02/ hetz:/root/lattices-seo-explainers-batch02-20261002/
ssh hetz 'export PATH=/opt/node22/bin:$PATH; cd /root/lattices-seo-explainers-batch02-20261002; mkdir -p renders; for slug in macos-automation-permissions observe-act-verify window-snapping-vs-tiling; do npx --yes hyperframes@0.8.112 render "$slug" --quality delivery --fps 30 --workers 2 --strict-all --skill faceless-explainer --output "renders/$slug.mp4" > "evidence/$slug-render.log" 2>&1 || exit 1; done'
rsync -az --include '*.mp4' --exclude '*' hetz:/root/lattices-seo-explainers-batch02-20261002/renders/ apps/site/public/learn/media/
rsync -az --include '*-render.log' --exclude '*' hetz:/root/lattices-seo-explainers-batch02-20261002/evidence/ studies/seo-explainers/batch-02/evidence/
node studies/seo-explainers/batch-02/export-media.mjs
```

The export step requires local `ffmpeg` and `ffprobe`. It rejects unexpected duration, geometry, or frame rate, fully decodes each MP4, extracts a full-size JPEG poster, creates a decoded four-beat contact sheet, records file sizes and SHA256 hashes, and writes `batch-02-manifest.json` from the actual caption and transcript files. The manifest is generated separately so the earlier assets remain intact.

After all outputs exist, import the finished batch using the repository's safe merge command:

```sh
node studies/seo-explainers/merge-manifests.mjs apps/site/public/learn/media/batch-02-manifest.json
```

## Evidence

`evidence/*-check.json` records strict checks of lint, runtime, layout, motion and text contrast. Each project also retains full-frame preview snapshots. `window-keyframes.json` and `window-snap-motion.png` record a focused seekable-motion inspection. `*-render.log` preserves the remote render result. `*-ffprobe.json`, `media-verification.json`, and `*-contact.jpg` are generated from the delivered encoded files.

All three local strict checks passed with zero findings after correcting the final permission-note width and preserving the workspace windows' vertical placement during their reveal. The final frames were independently reviewed before rendering.

The final encoded MP4s each measure exactly 40 seconds, 1280×720, 30 fps and 1,200 H.264 frames. All three fully decode without errors. The delivered file sizes are 847,959 bytes for permissions, 999,281 bytes for observe/act/verify, and 822,021 bytes for snapping/tiling/workspaces. Their SHA256 values are preserved in `evidence/media-verification.json`. The decoded contact sheets were visually reviewed across all four teaching beats; full-size final frames are retained as `*-final.jpg`. These are silent videos with no audio stream.
