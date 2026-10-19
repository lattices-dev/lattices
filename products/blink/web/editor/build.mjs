#!/usr/bin/env node
// Build the Blink v2 editor into a single self-contained dist/editor.html.
//
// 1. Bundle src/main.ts with esbuild (iife, minified, no external network deps).
// 2. Emit dist/editor.html from a template with the JS inlined in <script> and
//    the page/document CSS inlined in <style>. Zero external <script src> /
//    <link href> so native code can loadFileURL / loadHTMLString offline.

import { build } from "esbuild";
import { mkdir, writeFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = __dirname;
const distDir = resolve(root, "dist");
const outHtml = resolve(distDir, "editor.html");

/**
 * Document-level CSS. CodeMirror's own view CSS is injected at runtime by the
 * bundle (via StyleModule), so here we only need the page shell: full-viewport,
 * fully transparent, so the native glass panel shows through.
 */
const PAGE_CSS = `
/* ---------------------------------------------------------------------------
 * Runtime theme variables. Every visual value in BOTH the reader typography
 * (below) and the CM6 editor theme (src/theme.ts) resolves to one of these
 * custom properties. Defaults equal the original hard-coded values.
 *
 * Native code themes the surface at runtime via window.blink.setTheme({...}),
 * which does document.documentElement.style.setProperty(key, value) per entry
 * (keys arrive as full var names, e.g. "--blink-font-size": "14px"), and
 * window.blink.resetTheme(), which strips those inline overrides back to these
 * stylesheet defaults.
 *
 * Heading sizes: --blink-hN-size are the READER sizes (20/17/15). The editor
 * derives its own heading sizes as calc(var(--blink-hN-size) - 3px) in
 * src/theme.ts (-> 17/14/12). Font weights are hard-coded (not themable).
 * ------------------------------------------------------------------------- */
:root {
  color-scheme: dark;

  /* Typography */
  --blink-font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
  --blink-mono-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Monaco, "Cascadia Code", monospace;
  --blink-title-family: var(--blink-font-family);
  --blink-font-size: 13px;
  --blink-line-height: 1.75;

  /* Content padding */
  --blink-pad-x: 20px;
  --blink-pad-y: 16px;

  /* Sheet surface. Transparent preserves the native glass default; reusable
   * treatments can paint an exact brand canvas without choosing card/serif. */
  --blink-sheet-bg: transparent;

  /* Text colors */
  --blink-text: rgba(255, 255, 255, 0.85);
  --blink-text-strong: rgba(255, 255, 255, 0.96);
  --blink-text-muted: rgba(255, 255, 255, 0.45);
  --blink-marker: rgba(255, 255, 255, 0.35);

  /* Links */
  --blink-accent: rgba(158, 203, 255, 0.9);
  --blink-accent-dim: rgba(158, 203, 255, 0.55);

  /* Code */
  --blink-code-bg: rgba(255, 255, 255, 0.07);
  --blink-code-text: rgba(255, 255, 255, 0.8);

  /* Caret + selection */
  --blink-caret: #ffffff;
  --blink-selection: rgba(255, 255, 255, 0.18);

  /* Heading sizes (reader; editor derives - 3px) */
  --blink-h1-size: 20px;
  --blink-h2-size: 17px;
  --blink-h3-size: 15px;

  /* Blockquote */
  --blink-quote-text: rgba(255, 255, 255, 0.65);
  --blink-quote-border: rgba(255, 255, 255, 0.2);

  /* Rules + table borders */
  --blink-rule: rgba(255, 255, 255, 0.15);

  /* ---------------------------------------------------------------------------
   * Sheet templates (Ink). A note's whole visual identity is drawn here and
   * selected via body[data-sheet="…"]; see the sheet blocks below. These vars
   * are the sheet-level knobs (themable like every other --blink-*).
   * ------------------------------------------------------------------------- */

  /* Legibility floor for FLAT sheets (dotted/bracket/marginalia): ink lands
   * directly on the user's wallpaper, which can be any color, so every glyph
   * gets a dark halo. White ink + this halo must survive a white wallpaper.
   * Themes can tune it (e.g. lighten for a dark-only setup). */
  --blink-halo: 0 0 1px rgba(0, 0, 0, 0.9), 0 1px 2px rgba(0, 0, 0, 0.7), 0 0 12px rgba(0, 0, 0, 0.45);

  /* card sheet: warm dark paper + printed-feeling serif for the reader. */
  --blink-card-bg: #1c1917;
  --blink-card-serif: Charter, Georgia, "Times New Roman", "Iowan Old Style", serif;

  /* Frame ink for flat sheets (dotted outline, corner brackets, margin rule). */
  --blink-frame: rgba(255, 255, 255, 0.85);

  /* Entrance duration (Arrival). Native pushes the configured value onto
   * <body> via --blink-enter-ms before running an effect; this default keeps
   * the keyframes well-defined if an entrance ever fires without one. */
  --blink-enter-ms: 260ms;
}

/* Reader mode uses native DOM selection rather than CodeMirror's painted
 * selection layer. Give it the same quiet, themeable treatment. */
::selection {
  background: var(--blink-selection);
}

* { box-sizing: border-box; }
html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100vh;
  overflow: hidden;
  /* Prevent the WKWebView from painting an opaque backdrop. */
  -webkit-user-select: text;
}
html { background: transparent; }
body { background: var(--blink-sheet-bg); }
#editor {
  width: 100%;
  height: 100vh;
  background: transparent;
}
.cm-editor {
  height: 100%;
}
/* Belt-and-suspenders: never let any layer paint an opaque background. */
.cm-editor, .cm-scroller, .cm-content, .cm-gutters {
  background: transparent !important;
}

/* ---------------------------------------------------------------------------
 * Read mode: rendered markdown typography on the same transparent glass.
 * The .blink-reader occupies the full viewport (like #editor), scrolls
 * independently, and paints NO surface of its own. Only edit OR read is
 * displayed at a time (toggled via inline display in main.ts).
 * ------------------------------------------------------------------------- */
.blink-reader {
  display: none;
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100vh;
  overflow-x: hidden;
  overflow-y: auto;
  background: transparent;
  /* Match the editor content box padding. */
  padding: var(--blink-pad-y) var(--blink-pad-x);
  font-family: var(--blink-font-family);
  font-size: var(--blink-font-size);
  line-height: var(--blink-line-height);
  color: var(--blink-text);
  -webkit-font-smoothing: antialiased;
  word-wrap: break-word;
  overflow-wrap: break-word;
}
.blink-reader > :first-child { margin-top: 0; }
.blink-reader > :last-child { margin-bottom: 0; }

.blink-reader h1,
.blink-reader h2,
.blink-reader h3,
.blink-reader h4,
.blink-reader h5,
.blink-reader h6 {
  font-family: var(--blink-title-family);
  font-weight: 600;
  line-height: 1.3;
  margin: 1.4em 0 0.5em;
}
.blink-reader h1 { font-size: var(--blink-h1-size); font-weight: 700; color: var(--blink-text-strong); }
.blink-reader h2 { font-size: var(--blink-h2-size); font-weight: 650; color: var(--blink-text-strong); }
.blink-reader h3,
.blink-reader h4,
.blink-reader h5,
.blink-reader h6 { font-size: var(--blink-h3-size); font-weight: 600; color: var(--blink-text-strong); }

.blink-reader p { margin: 0 0 0.85em; }

.blink-reader a {
  color: var(--blink-accent);
  text-decoration: none;
}
.blink-reader a:hover { text-decoration: underline; }

.blink-reader code {
  font-family: var(--blink-mono-family);
  font-size: 12px;
  color: var(--blink-code-text);
  background: var(--blink-code-bg);
  border-radius: 3px;
  padding: 1px 4px;
}
.blink-reader pre {
  font-family: var(--blink-mono-family);
  font-size: 12px;
  background: var(--blink-code-bg);
  border-radius: 6px;
  padding: 10px 12px;
  overflow-x: auto;
  margin: 0 0 0.85em;
}
/* Code inside a fence: strip the inline chip styling (pre provides the block). */
.blink-reader pre code {
  background: transparent;
  padding: 0;
  border-radius: 0;
  color: var(--blink-code-text);
}

.blink-reader blockquote {
  margin: 0 0 0.85em;
  padding: 0.1em 0 0.1em 12px;
  border-left: 2px solid var(--blink-quote-border);
  color: var(--blink-quote-text);
  font-style: italic;
}

.blink-reader ul,
.blink-reader ol {
  margin: 0 0 0.85em;
  padding-left: 1.5em;
}
.blink-reader li { margin: 0.15em 0; }
.blink-reader li::marker { color: var(--blink-text-muted); }

.blink-reader hr {
  border: none;
  border-top: 1px solid var(--blink-rule);
  margin: 1.4em 0;
}

.blink-reader table {
  border-collapse: collapse;
  margin: 0 0 0.85em;
}
.blink-reader th,
.blink-reader td {
  padding: 4px 8px;
  border: 1px solid var(--blink-rule);
}
.blink-reader th {
  font-weight: 600;
  color: var(--blink-text-strong);
  text-align: left;
}

.blink-reader img { max-width: 100%; }

.blink-reader strong { font-weight: 650; color: var(--blink-text-strong); }
.blink-reader em { font-style: italic; }
.blink-reader del { color: var(--blink-text-muted); }

/* Empty-note placeholder: centered dim italic, fills the reader viewport. */
.blink-reader-empty {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: var(--blink-pad-y) var(--blink-pad-x);
  color: var(--blink-marker);
  font-style: italic;
  font-size: var(--blink-font-size);
}

/* ---------------------------------------------------------------------------
 * VISIBLE HAND — external appends reveal at typing cadence.
 *
 * Edit mode keeps the complete CodeMirror document underneath and replaces
 * only the unrevealed suffix with this caret widget. Read mode uses a cheap
 * plain-text suffix region while the base remains rendered markdown, then
 * swaps to the fully rendered note at completion.
 * ------------------------------------------------------------------------- */
.blink-typeon-caret {
  display: inline-block;
  width: 1.5px;
  height: 1.15em;
  margin: 0 1px;
  vertical-align: -0.18em;
  border-radius: 1px;
  background: var(--blink-caret);
  box-shadow: 0 0 5px rgba(255, 255, 255, 0.28);
  animation: blink-typeon-caret 720ms step-end infinite;
}
/* The real selection stays in the complete document (normally at its full
 * end) while the reveal widget marks the visual append point. */
body[data-type-on] .cm-cursor {
  opacity: 0 !important;
}
/* In-place typed reveal: the appended text is rendered in its FINAL position up
 * front (so nothing reflows at the end); each character starts pending and fades
 * in as the caret walks across it. */
.blink-reader-typing {
  color: var(--blink-text);
}
.blink-tok {
  transition: opacity 220ms ease-out, filter 220ms ease-out;
}
.blink-tok.is-pending {
  opacity: 0;
  /* Paint-only (no reflow): each char resolves from a soft blur into focus, so
   * the overlapping fades read as one continuous sharpening wave, not pops. */
  filter: blur(3px);
}
@keyframes blink-typeon-caret {
  0%, 48% { opacity: 1; }
  49%, 100% { opacity: 0.18; }
}

/* STREAM — the reader layer's arrival: the whole document is rendered in its
 * final layout, then each block (paragraph, list item, heading, code) rises
 * 4px and fades in turn, staggered by --blink-stream-delay (expo out). */
.blink-stream {
  animation: blink-stream-in 380ms cubic-bezier(0.16, 1, 0.3, 1) both;
  animation-delay: var(--blink-stream-delay, 0ms);
}
@keyframes blink-stream-in {
  from { opacity: 0; transform: translateY(4px); }
  to { opacity: 1; transform: none; }
}

/* Attribution is presentation-only and never takes pointer focus. Its quiet
 * capsule mirrors the panel's hover-earned chrome without reserving layout. */
.blink-attribution {
  position: fixed;
  left: 10px;
  bottom: 9px;
  z-index: 10;
  max-width: calc(100vw - 20px);
  padding: 4px 8px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 999px;
  background: rgba(16, 16, 18, 0.72);
  color: var(--blink-text-muted);
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.24);
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
  font-family: var(--blink-font-family);
  font-size: 10.5px;
  font-weight: 500;
  line-height: 1.25;
  letter-spacing: 0.01em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  pointer-events: none;
  opacity: 0;
  transform: translateY(3px);
  transition: opacity 140ms ease-out, transform 140ms ease-out;
}
.blink-attribution.is-visible {
  opacity: 1;
  transform: translateY(0);
}

/* ===========================================================================
 * SHEET TEMPLATES (Ink)
 *
 * A note's visual identity is a "sheet", chosen via body[data-sheet="…"]. The
 * native panel is an invisible carrier: for GLASS/CARD it keeps its glass
 * material; for the FLAT sheets (dotted/bracket/marginalia) native hides the
 * glass entirely and this layer paints everything on a transparent page.
 *
 * Both surfaces (editor + reader) must honor the sheet, so sheet chrome is
 * drawn on body::before / body::after (which cover #editor and #reader alike),
 * and text styling targets the shared type layers.
 *
 * The default (glass) matches the original look byte-for-byte: transparent
 * page, no frame, no halo. Everything below is additive per non-glass sheet.
 * =========================================================================== */

/* --- card: an index card. Near-opaque warm dark paper with a subtle grain,
 *     printed-feeling serif type for the reader, generous padding. Native glass
 *     stays on behind it, but the paper is nearly opaque so it reads as its own
 *     surface. No halo (the paper supplies contrast). ------------------------ */
body[data-sheet="card"] {
  background:
    /* faint grain: two offset radial fields, cheap and asset-free */
    radial-gradient(circle at 20% 30%, rgba(255, 255, 255, 0.018) 0, transparent 55%),
    radial-gradient(circle at 80% 70%, rgba(0, 0, 0, 0.05) 0, transparent 55%),
    var(--blink-card-bg);
}
/* Grain overlay: a tiled inline SVG turbulence, very low opacity. */
body[data-sheet="card"]::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  z-index: 0;
  opacity: 0.04;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)'/%3E%3C/svg%3E");
}
body[data-sheet="card"] #editor,
body[data-sheet="card"] .blink-reader {
  /* Sit above the grain overlay. */
  position: relative;
  z-index: 1;
}
/* Generous padding for the printed feel. */
body[data-sheet="card"] {
  --blink-pad-x: var(--blink-card-pad-x, 28px);
  --blink-pad-y: var(--blink-card-pad-y, 24px);
}
/* Printed-feeling reader type (Charter/Georgia). The editor stays in the
 * system font — writing markdown source in a serif reads oddly. */
body[data-sheet="card"] .blink-reader {
  font-family: var(--blink-card-serif);
}
body[data-sheet="card"] .blink-reader h1,
body[data-sheet="card"] .blink-reader h2,
body[data-sheet="card"] .blink-reader h3,
body[data-sheet="card"] .blink-reader h4,
body[data-sheet="card"] .blink-reader h5,
body[data-sheet="card"] .blink-reader h6,
body[data-sheet="card"] .blink-reader blockquote,
body[data-sheet="card"] .blink-reader-empty {
  font-family: var(--blink-card-serif);
}

/* --- FLAT sheets: transparent page, ink on the wallpaper. Shared halo so white
 *     ink survives any wallpaper. The frame chrome gets a faint dark duplicate
 *     beneath it (drop-shadow) for the same reason. ------------------------- */
body[data-sheet="dotted"],
body[data-sheet="bracket"],
body[data-sheet="marginalia"] {
  background: transparent;
}
/* Text halo across editor and reader type layers. text-shadow on the content
 * layers reaches every glyph without touching layout. */
body[data-sheet="dotted"] .cm-content,
body[data-sheet="dotted"] .blink-reader,
body[data-sheet="bracket"] .cm-content,
body[data-sheet="bracket"] .blink-reader,
body[data-sheet="marginalia"] .cm-content,
body[data-sheet="marginalia"] .blink-reader {
  text-shadow: var(--blink-halo);
}

/* --- dotted: a cut-out. A 1.5px dotted outline inset ~4px with ~8px radius,
 *     drawn on body::before so it frames both surfaces. --------------------- */
body[data-sheet="dotted"]::before {
  content: "";
  position: fixed;
  inset: 4px;
  border: 1.5px dotted var(--blink-frame);
  border-radius: 8px;
  pointer-events: none;
  z-index: 2;
  /* faint dark duplicate beneath the outline so it survives a light wallpaper */
  filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.7));
}

/* --- bracket: architect's framing. Four corner brackets (~18px arms, 2px
 *     stroke) via an inline SVG on body::before; text floats free. ---------- */
body[data-sheet="bracket"]::before {
  content: "";
  position: fixed;
  inset: 4px;
  pointer-events: none;
  z-index: 2;
  filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.7));
  background-image:
    /* top-left */
    linear-gradient(to right, var(--blink-frame) 2px, transparent 2px),
    linear-gradient(to bottom, var(--blink-frame) 2px, transparent 2px),
    /* top-right */
    linear-gradient(to left, var(--blink-frame) 2px, transparent 2px),
    linear-gradient(to bottom, var(--blink-frame) 2px, transparent 2px),
    /* bottom-left */
    linear-gradient(to right, var(--blink-frame) 2px, transparent 2px),
    linear-gradient(to top, var(--blink-frame) 2px, transparent 2px),
    /* bottom-right */
    linear-gradient(to left, var(--blink-frame) 2px, transparent 2px),
    linear-gradient(to top, var(--blink-frame) 2px, transparent 2px);
  background-repeat: no-repeat;
  background-size: 18px 18px;
  background-position:
    top left, top left,
    top right, top right,
    bottom left, bottom left,
    bottom right, bottom right;
}

/* --- marginalia: barest. A single 2px vertical rule down the left edge; text
 *     hangs off it. ---------------------------------------------------------- */
body[data-sheet="marginalia"]::before {
  content: "";
  position: fixed;
  top: 8px;
  bottom: 8px;
  left: 10px;
  width: 2px;
  background: var(--blink-frame);
  pointer-events: none;
  z-index: 2;
  filter: drop-shadow(1px 0 1px rgba(0, 0, 0, 0.7));
}

/* ===========================================================================
 * ENTRANCES (Arrival)
 *
 * The native panel animates its own window (alpha 0→1 over the entrance's
 * duration; for "drop" it also drifts the frame from 8pt above with a spring
 * settle). This layer choreographs the CONTENT, keyed off a transient
 * body[data-enter="…"] attribute set by window.blink.enter() and cleared after
 * the run. --blink-enter-ms carries the configured base duration.
 *
 * Only the content type layers (#editor / .blink-reader) and, for "draw", the
 * flat-sheet frame chrome (body::before) are touched — never geometry. When no
 * data-enter is present the page is in its resting, fully-visible state, so an
 * entrance that never fires (motion disabled / Reduce Motion / "none") looks
 * exactly like today.
 * =========================================================================== */

/* shimmer — content fades up from 0 while a soft highlight sweep crosses the
 * sheet left→right. The sweep is a body::after overlay so it rides above both
 * surfaces without disturbing layout; it self-removes when data-enter clears. */
body[data-enter="shimmer"] #editor,
body[data-enter="shimmer"] .blink-reader {
  animation: blink-enter-fade var(--blink-enter-ms) ease-out both;
}
body[data-enter="shimmer"]::after {
  content: "";
  position: fixed;
  inset: 0;
  z-index: 3;
  pointer-events: none;
  background: linear-gradient(
    105deg,
    transparent 0%,
    transparent 35%,
    rgba(255, 255, 255, 0.14) 50%,
    transparent 65%,
    transparent 100%
  );
  background-size: 250% 100%;
  animation: blink-enter-sweep var(--blink-enter-ms) ease-out both;
}

/* drop — content just fades in; the window scale/drift/settle is native. */
body[data-enter="drop"] #editor,
body[data-enter="drop"] .blink-reader {
  animation: blink-enter-fade var(--blink-enter-ms) ease-out both;
}

/* draw — flat sheets only (native falls back to shimmer on glass/card). The
 * frame chrome strokes itself on via a left→right clip wipe, then the text
 * fades in behind it (delayed by ~55% of the duration so the frame lands
 * first). */
body[data-enter="draw"][data-sheet="dotted"]::before,
body[data-enter="draw"][data-sheet="bracket"]::before,
body[data-enter="draw"][data-sheet="marginalia"]::before {
  animation: blink-enter-draw var(--blink-enter-ms) ease-out both;
}
body[data-enter="draw"] #editor,
body[data-enter="draw"] .blink-reader {
  animation: blink-enter-fade calc(var(--blink-enter-ms) * 0.6) ease-out both;
  animation-delay: calc(var(--blink-enter-ms) * 0.5);
}

@keyframes blink-enter-fade {
  from { opacity: 0; }
  to { opacity: 1; }
}
@keyframes blink-enter-sweep {
  from { background-position: 140% 0; }
  to { background-position: -60% 0; }
}
@keyframes blink-enter-draw {
  from { clip-path: inset(0 100% 0 0); }
  to { clip-path: inset(0 0 0 0); }
}

/* Reduce Motion: the native side already downgrades to "none" (no data-enter is
 * ever set), but honor the OS setting here too so a stray entrance can't animate
 * against the user's wishes. */
@media (prefers-reduced-motion: reduce) {
  body[data-enter] #editor,
  body[data-enter] .blink-reader,
  body[data-enter]::after,
  body[data-enter]::before {
    animation: none !important;
  }
  .blink-typeon-caret {
    animation: none;
  }
  .blink-stream {
    animation: none;
  }
  .blink-attribution {
    transition: none;
  }
}
`.trim();

function htmlTemplate({ css, js }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no" />
<meta name="color-scheme" content="dark" />
<title>Canvas Editor</title>
<style>
${css}
</style>
</head>
<body>
<div id="editor"></div>
<div id="reader" class="blink-reader" style="display:none"></div>
<div id="attribution" class="blink-attribution" role="status" aria-live="polite"></div>
<script>
${js}
</script>
</body>
</html>
`;
}

async function main() {
  const result = await build({
    entryPoints: [resolve(root, "src/main.ts")],
    bundle: true,
    format: "iife",
    minify: true,
    sourcemap: false,
    target: ["es2022", "safari16"],
    platform: "browser",
    legalComments: "none",
    write: false,
    // Keep the bundle in memory; we inline it rather than emit a .js on disk.
    outfile: resolve(distDir, "editor.bundle.js"),
    logLevel: "info",
  });

  const jsFile =
    result.outputFiles.find((f) => f.path.endsWith(".js")) ??
    result.outputFiles[0];
  if (!jsFile) {
    throw new Error("esbuild produced no JS output");
  }
  const js = jsFile.text;

  // Sanity: closing tags inside the inlined JS would break the <script> block.
  if (/<\/script>/i.test(js)) {
    throw new Error("Bundled JS contains a literal </script>; inlining unsafe");
  }

  const html = htmlTemplate({ css: PAGE_CSS, js });

  await mkdir(distDir, { recursive: true });
  await writeFile(outHtml, html, "utf8");

  // Guardrails: no external references, reasonable size.
  if (/<script[^>]+\bsrc=/i.test(html)) {
    throw new Error("Output contains an external <script src>");
  }
  if (/<link[^>]+\bhref=/i.test(html)) {
    throw new Error("Output contains an external <link href>");
  }
  // Read-mode surface must be present: element, styles, and placeholder.
  if (!/id="reader"/.test(html) || !/class="blink-reader"/.test(html)) {
    throw new Error("Output is missing the #reader / .blink-reader element");
  }
  if (!/\.blink-reader\s*\{/.test(html)) {
    throw new Error("Output is missing the .blink-reader typography styles");
  }
  if (!/blink-reader-empty/.test(html)) {
    throw new Error("Output is missing the empty-note placeholder styles");
  }

  // Sheet templates (Ink): every sheet must have a data-sheet CSS block, the
  // flat sheets must carry the text halo, and window.blink.setSheet must exist.
  for (const sheet of ["card", "dotted", "bracket", "marginalia"]) {
    if (!new RegExp(`\\[data-sheet="${sheet}"\\]`).test(html)) {
      throw new Error(`Output is missing the "${sheet}" sheet CSS block`);
    }
  }
  if (!/var\(--blink-halo\)/.test(html)) {
    throw new Error("Output is missing the flat-sheet text halo (--blink-halo)");
  }
  if (!/setSheet/.test(html)) {
    throw new Error("Bundle is missing window.blink.setSheet");
  }

  // Entrances (Arrival): the content-choreography CSS must be present for each
  // effect, the keyframes must exist, and window.blink.enter must be wired.
  for (const enter of ["shimmer", "drop", "draw"]) {
    if (!new RegExp(`\\[data-enter="${enter}"\\]`).test(html)) {
      throw new Error(`Output is missing the "${enter}" entrance CSS block`);
    }
  }
  if (!/@keyframes blink-enter-/.test(html)) {
    throw new Error("Output is missing the entrance keyframes");
  }
  if (!/data-enter/.test(html) || !/--blink-enter-ms/.test(html)) {
    throw new Error("Bundle is missing the entrance runtime (window.blink.enter)");
  }

  // Visible Hand: native must be able to invoke a typed reveal, the bundle
  // must carry both edit/read reveal visuals, and attribution needs a mount.
  if (!/typeOn/.test(html) || !/finishTypeOn/.test(html)) {
    throw new Error("Bundle is missing window.blink.typeOn / finishTypeOn");
  }
  if (!/blink-typeon-caret/.test(html) || !/blink-tok/.test(html)) {
    throw new Error("Output is missing typed-reveal styles");
  }
  if (!/id="attribution"/.test(html) || !/blink-attribution/.test(html)) {
    throw new Error("Output is missing the attribution chip");
  }

  // Theming guardrails. The runtime theme contract is load-bearing (native code
  // is being built against exactly this), so verify the bundle statically.
  //
  // 1. The :root block must declare every themable variable with a default.
  const THEME_VARS = [
    "--blink-font-family",
    "--blink-mono-family",
    "--blink-title-family",
    "--blink-font-size",
    "--blink-line-height",
    "--blink-pad-x",
    "--blink-pad-y",
    "--blink-sheet-bg",
    "--blink-text",
    "--blink-text-strong",
    "--blink-text-muted",
    "--blink-marker",
    "--blink-accent",
    "--blink-accent-dim",
    "--blink-code-bg",
    "--blink-code-text",
    "--blink-caret",
    "--blink-selection",
    "--blink-h1-size",
    "--blink-h2-size",
    "--blink-h3-size",
    "--blink-quote-text",
    "--blink-quote-border",
    "--blink-rule",
    "--blink-halo",
  ];
  const rootMatch = html.match(/:root\s*\{([^}]*)\}/);
  if (!rootMatch) {
    throw new Error("Output is missing the :root theme-variable block");
  }
  const rootBlock = rootMatch[1];
  const missing = THEME_VARS.filter(
    (v) => !new RegExp(`${v}\\s*:`).test(rootBlock)
  );
  if (missing.length > 0) {
    throw new Error(
      `:root is missing theme variable defaults: ${missing.join(", ")}`
    );
  }

  // 2. No raw accent color literal may remain outside the :root defaults —
  //    every consumer must reference var(--blink-accent[-dim]).
  const outsideRoot =
    html.slice(0, rootMatch.index) +
    html.slice(rootMatch.index + rootMatch[0].length);
  if (/rgba\(158,\s*203,\s*255/.test(outsideRoot)) {
    throw new Error(
      "Raw rgba(158,203,255,…) accent color found outside the :root defaults"
    );
  }

  // 3. The setTheme / resetTheme native API must exist on window.blink.
  if (!/setTheme/.test(html) || !/resetTheme/.test(html)) {
    throw new Error("Bundle is missing window.blink.setTheme / resetTheme");
  }

  const { size } = await stat(outHtml);
  const kb = (size / 1024).toFixed(1);
  const maxBytes = 1.5 * 1024 * 1024;
  if (size > maxBytes) {
    throw new Error(`dist/editor.html is ${kb} KB, over the 1.5 MB budget`);
  }

  console.log(`[BLINK] Wrote ${outHtml} (${kb} KB, self-contained)`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
