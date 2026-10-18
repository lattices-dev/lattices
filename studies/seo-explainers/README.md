# Lattices educational animation pilot

The first batch is documented below. The next three explainers and their independent render workflow live in [`batch-02/`](batch-02/README.md). Rebuilding the first batch preserves later clips in the shared media manifest.

Two silent 36-second explainers for aspiring Mac power users. The videos use readable narrative text and continuous illustrative diagrams. They do not contain recorded desktop evidence or product demos.

- **How the macOS accessibility tree works** follows one Export button from an illustrated window into an app → window → control hierarchy, then explains role, title and supported action.
- **AX vs screenshots: what UI automation can see** compares visible pixels with app-supplied structure, their limits, and separate Accessibility and Screen Recording permissions.

`build.mjs` is the source of truth: edit the two content records, diagram functions or shared style, then rebuild both HyperFrames compositions and captions. Each composition is independently previewable. Fonts are frozen locally with SIL Open Font License copies. GSAP is bundled by the HyperFrames compiler from its pinned CDN script. `sources.json` records the official Apple references checked for the scripts.

## Rebuild and verify

From the repository root:

```sh
node studies/seo-explainers/build.mjs
npx --yes hyperframes@0.8.111 check studies/seo-explainers/ax-tree --snapshots --json
npx --yes hyperframes@0.8.111 check studies/seo-explainers/ax-vs-screenshots --snapshots --json
```

Keep meaningful reading holds. Movement reveals relationships and directs attention; the progress line represents elapsed time. The diagram is a single continuous scene, so it uses one paused GSAP timeline rather than timed nested clips. Motion assertions verify the title entrance and the frame bounds.

## Render on hetz

The pilot used the existing Node 22 runtime, headless Chrome cache and ffmpeg on `hetz`. The render workspace is isolated under `/root/lattices-seo-explainers-20261002`. It does not control or replace other remote jobs.

```sh
rsync -az studies/seo-explainers/ hetz:/root/lattices-seo-explainers-20261002/
ssh hetz 'export PATH=/opt/node22/bin:$PATH; cd /root/lattices-seo-explainers-20261002; npx --yes hyperframes@0.8.111 render ax-tree --quality high --fps 30 --workers 2 --output /root/lattices-seo-explainers-20261002/renders/ax-tree.mp4'
ssh hetz 'export PATH=/opt/node22/bin:$PATH; cd /root/lattices-seo-explainers-20261002; npx --yes hyperframes@0.8.111 render ax-vs-screenshots --quality high --fps 30 --workers 2 --output /root/lattices-seo-explainers-20261002/renders/ax-vs-screenshots.mp4'
rsync -az hetz:/root/lattices-seo-explainers-20261002/renders/ax-tree.mp4 apps/site/public/learn/media/
rsync -az hetz:/root/lattices-seo-explainers-20261002/renders/ax-vs-screenshots.mp4 apps/site/public/learn/media/
node studies/seo-explainers/export-media.mjs
```

The export step requires local ffmpeg and ffprobe. It inspects the actual MP4s, creates 1280×720 JPEG posters from encoded frames, and builds `manifest.json` from measured dimensions/duration plus the actual WebVTT cues and complete transcript text. It writes raw probe evidence under `evidence/`.

## Public outputs

`apps/site/public/learn/media/` contains each MP4, JPEG poster, WebVTT captions and full text transcript. Full transcripts also include all diagram labels and the illustrative disclosure. No narration or music is present; the video can be understood with sound off.

The captions repeat the on-screen explanation. A site should offer the transcript and a caption toggle. If captions are enabled, browser-native controls may overlay some baked-in copy; the separate transcript remains available.

## Delivered verification

Both final MP4s decode cleanly with ffmpeg, contain 1,080 H.264 frames at 30 fps, and measure exactly 36 seconds at 1280×720. The files are 1,397,277 bytes (`ax-tree`) and 1,816,741 bytes (`ax-vs-screenshots`). Final decoded contact sheets and full-size JPEG posters were visually reviewed. `evidence/media-verification.json` records their hashes; the individual check reports and render logs preserve the HyperFrames gate and remote-render evidence.
