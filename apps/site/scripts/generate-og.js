import puppeteer from "puppeteer";
import { readFileSync } from "fs";
import { join, dirname, extname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const publicDir = join(__dirname, "..", "public");
const repoRoot = join(__dirname, "..", "..", "..");

// ── Grid ────────────────────────────────────────────────────────
// 30px grid: GCD(1200, 630) = 30, so it tiles exactly: 40 columns, 21 rows.
const G = 30;
const W = 1200;
const H = 630;

// A registration cross 2G in from the top-left corner, its arms running 6G.
const CROSS = { x: G * 2, y: G * 2, len: G * 6 };

// ── The guide ───────────────────────────────────────────────────
// Every card shares one layout, so the family reads as a set:
//   brand    the card's own mark, cropped to its drawn bounds, fitted to a 4G box at (4G, 4G)
//   copy     the title 1G below the mark, then subtitle and tag, in a 12G column
//   preview  from (18G, 4G) out past the right and bottom edges: 660 × 510 visible
//   family   product cards sign off at the foot of the column with the Lattices mark
const BRAND = G * 4; // the box's size, and its inset from the top and left edges
const COLUMN = G * 12;
const PREVIEW = { x: G * 18, y: G * 4, w: W - G * 18, h: H - G * 4 };

// ── Marks from the brand kits (bun run brand) ───────────────────
function kitFile(slug, file) {
  return readFileSync(join(publicDir, "brand", slug, file), "utf8");
}

// Each kit's README records its glyph's measured bounds. Cropping to them lets
// every mark fill the same box, however much padding its own canvas carries.
function glyphBounds(slug) {
  const n = String.raw`(\d+(?:\.\d+)?)`; // not [\d.]+, which takes the sentence's full stop
  const found = kitFile(slug, "README.md").match(
    new RegExp(`Measured glyph bounds in viewBox units: ${n}, ${n}, ${n} × ${n}`),
  );
  if (!found) {
    throw new Error(`brand/${slug}/README.md has no glyph bounds; run bun run brand ${slug}`);
  }
  return found.slice(1).map(Number);
}

// The kit's mark for dark grounds, with its longer side at `size`.
function mark(slug, size) {
  const [x, y, w, h] = glyphBounds(slug);
  const scale = size / Math.max(w, h);
  return kitFile(slug, `${slug}-dark.svg`).replace(/<svg\b[^>]*>/, (tag) =>
    tag
      .replace(/\s(?:width|height|style|viewBox)="[^"]*"/g, "")
      .replace(
        "<svg",
        `<svg viewBox="${x} ${y} ${w} ${h}" width="${+(w * scale).toFixed(2)}" height="${+(h * scale).toFixed(2)}"`,
      ),
  );
}

// ── Previews ────────────────────────────────────────────────────
// Each fills the preview window: product art cropped to cover it, or an
// interface mock drawn at that size.
const MIME = { ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp" };

function artPreview(path, position = "center") {
  const data = readFileSync(join(repoRoot, path)).toString("base64");
  return `<img class="art" src="data:${MIME[extname(path)]};base64,${data}" style="object-position: ${position}" alt="">`;
}

function lights() {
  return `<div class="lights"><i style="background: #ff5f57"></i><i style="background: #febc2e"></i><i style="background: #28c840"></i></div>`;
}

// The app's screen map, drawn at its compact 360px width and scaled up to fill the window.
function screenMapPreview() {
  const zoom = PREVIEW.w / 360;
  const layer = (name, count, active = false) => `
          <div style="display: flex; align-items: center; gap: 5px; padding: 4px 10px; font-size: 9px; ${active ? "background: rgba(239,106,71,0.08); color: rgba(255,255,255,0.6); border-radius: 4px; margin: 0 4px;" : "color: rgba(255,255,255,0.35);"}">
            <div style="width: 5px; height: 5px; border-radius: 50%; background: ${active ? "#ef6a47" : "rgba(255,255,255,0.25)"};"></div>${name}
            <span style="margin-left: auto; color: rgba(255,255,255,${active ? 0.25 : 0.15});">${count}</span>
          </div>`;
  const key = (label, lit = false) => `
        <div style="font-size: 8px; padding: 3px 8px; border-radius: 3px; ${lit ? "background: rgba(239,106,71,0.1); border: 1px solid rgba(239,106,71,0.2); color: #ef6a47;" : "background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.06); color: rgba(255,255,255,0.3);"}">${label}</div>`;
  return `
    <div class="mock" style="width: 360px; height: ${(PREVIEW.h / zoom).toFixed(2)}px; zoom: ${zoom.toFixed(4)};">
      <div style="display: flex; align-items: center; padding: 12px 16px 8px; gap: 8px;">
        <div style="display: flex; gap: 6px;">
          <div style="width: 10px; height: 10px; border-radius: 50%; background: #ff5f57;"></div>
          <div style="width: 10px; height: 10px; border-radius: 50%; background: #febc2e;"></div>
          <div style="width: 10px; height: 10px; border-radius: 50%; background: #28c840;"></div>
        </div>
        <span style="font-size: 12px; font-weight: 600; color: rgba(255,255,255,0.7); margin-left: 6px;">Lattices</span>
        <span style="font-size: 10px; color: rgba(255,255,255,0.2); margin-left: auto;">2 monitors</span>
      </div>
      <div style="flex: 1; display: flex; overflow: hidden;">
        <div style="width: 86px; border-right: 1px solid rgba(255,255,255,0.06); padding: 8px 0; flex-shrink: 0;">
          <div style="font-size: 8px; font-weight: 600; color: rgba(255,255,255,0.25); padding: 0 10px 6px; letter-spacing: 0.1em;">LAYERS</div>
          ${layer("All", 19)}
          ${layer("L0", 6)}
          ${layer("L1", 4, true)}
          ${layer("L2", 7)}
          ${layer("L3", 4)}
          ${layer("L4", 3)}
        </div>
        <div style="flex: 1; position: relative; padding: 10px; display: flex; flex-direction: column;">
          <div style="display: flex; gap: 4px; margin-bottom: 8px; padding: 0 2px;">
            <div style="font-size: 8px; padding: 3px 8px; border-radius: 4px; background: rgba(255,255,255,0.08); color: rgba(255,255,255,0.5); font-weight: 500;">ALL</div>
            <div style="font-size: 8px; padding: 3px 8px; border-radius: 4px; color: rgba(255,255,255,0.2);">1</div>
            <div style="font-size: 8px; padding: 3px 8px; border-radius: 10px; background: rgba(239,106,71,0.15); color: #ef6a47; font-weight: 600; border: 1px solid rgba(239,106,71,0.3);">2</div>
          </div>
          <div style="flex: 1; display: grid; grid-template-columns: 1fr 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 4px;">
            <div style="grid-column: 1 / 3; background: rgba(239,106,71,0.06); border: 1px solid rgba(239,106,71,0.2); border-radius: 5px; padding: 8px;">
              <div style="font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.6);">Google Chrome</div>
              <div style="font-size: 7px; color: rgba(255,255,255,0.15); margin-top: 2px;">688×720</div>
            </div>
            <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 5px; padding: 8px;">
              <div style="font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.6);">Terminal</div>
              <div style="font-size: 7px; color: rgba(255,255,255,0.15); margin-top: 2px;">arach@~</div>
            </div>
            <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 5px; padding: 8px;">
              <div style="font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.6);">Finder</div>
              <div style="font-size: 7px; color: rgba(255,255,255,0.15); margin-top: 2px;">wallpapers</div>
            </div>
            <div style="background: rgba(255,255,255,0.02); border: 1px dashed rgba(255,255,255,0.08); border-radius: 5px; padding: 8px;">
              <div style="font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.4);">Messages</div>
            </div>
            <div style="background: rgba(255,255,255,0.02); border: 1px dashed rgba(255,255,255,0.08); border-radius: 5px; padding: 8px;">
              <div style="font-size: 9px; font-weight: 600; color: rgba(255,255,255,0.4);">Preview</div>
            </div>
          </div>
        </div>
      </div>
      <div style="padding: 8px 12px; border-top: 1px solid rgba(255,255,255,0.06); display: flex; gap: 4px; flex-wrap: wrap;">
        ${key("s spread")}${key("t tile")}${key("d distrib")}${key("g grow")}${key("f flatten", true)}
      </div>
      <div style="display: flex; align-items: center; padding: 6px 14px; border-top: 1px solid rgba(255,255,255,0.04); font-size: 8px; color: rgba(255,255,255,0.2);">
        <div style="display: flex; align-items: center; gap: 5px;">
          <div style="width: 5px; height: 5px; border-radius: 50%; background: #ef6a47;"></div>
          <span>:9399</span>
        </div>
        <span style="margin-left: auto;">4 pending</span>
      </div>
    </div>`;
}

// The docs site on its Configuration page, with the real nav.
function docsPreview() {
  const nav = [
    ["Introduction", ["Overview", "Quickstart"]],
    ["Architecture & API", ["Concepts", "Agent API", "Agent Guide", "Embedded SDK"]],
    ["User Guide", ["Configuration", "Layers & Tab Groups", "Screen OCR & Search", "Mouse Gestures"]],
  ];
  const groups = nav
    .map(
      ([title, items]) => `
        <div class="docs-group">${title}</div>
        ${items.map((item) => `<div class="docs-item${item === "Configuration" ? " is-active" : ""}">${item}</div>`).join("")}`,
    )
    .join("");
  return `
    <div class="mock">
      <div class="chrome">${lights()}<span class="chrome-title">lattices.dev/docs/config</span></div>
      <div class="docs">
        <nav class="docs-nav">${groups}</nav>
        <article class="docs-page">
          <div class="docs-kicker">User Guide</div>
          <h1>Configuration</h1>
          <p>Place a <code>.lattices.json</code> file in your project root to define your workspace layout.</p>
          <pre class="code">{
  <b>"ensure"</b>: <em>true</em>,
  <b>"panes"</b>: [
    { <b>"name"</b>: "shell", <b>"size"</b>: <em>60</em> },
    { <b>"name"</b>: "server", <b>"cmd"</b>: "bun dev" },
    { <b>"name"</b>: "tests", <b>"cmd"</b>: "bun test --watch" }
  ]
}</pre>
          <h2>Layouts</h2>
          <div class="panes">
            <div class="is-main">shell<small>60%</small></div>
            <div>server<small>bun dev</small></div>
            <div>tests<small>bun test --watch</small></div>
          </div>
        </article>
      </div>
    </div>`;
}

// A session from the config above: the main-vertical layout, titled the way lattices titles it.
function terminalPreview() {
  const prompt = `<span class="t-prompt">~/dev/my-app $</span>`;
  return `
    <div class="mock">
      <div class="chrome">${lights()}<span class="chrome-title">[lattices:my-app-3f9a2c] shell</span></div>
      <div class="term">
        <div class="term-pane">
          <div>${prompt} cat .lattices.json</div>
          <pre>{
  <b>"ensure"</b>: <em>true</em>,
  <b>"panes"</b>: [
    { <b>"name"</b>: "shell", <b>"size"</b>: <em>60</em> },
    { <b>"name"</b>: "server", <b>"cmd"</b>: "bun dev" },
    { <b>"name"</b>: "tests", <b>"cmd"</b>: "bun test --watch" }
  ]
}</pre>
          <div>${prompt} <span class="t-cursor"></span></div>
        </div>
        <div class="term-stack">
          <div class="term-pane">
            <div>${prompt} bun dev</div>
            <div class="t-dim">VITE ready in 212 ms</div>
            <div class="t-dim">➜ Local: <span class="t-soft">localhost:5173</span></div>
          </div>
          <div class="term-pane">
            <div>${prompt} bun test --watch</div>
            <div class="t-ok">12 pass</div>
            <div class="t-dim">0 fail</div>
            <div class="t-dim">Ran 12 tests across 3 files.</div>
          </div>
        </div>
      </div>
      <div class="tmux-status">[my-app-3f9a2c] 0:zsh*</div>
    </div>`;
}

// Real calls against the daemon, in the order an agent would make them.
function apiPreview() {
  const call = (method, params, result) => `
        <div>
          <div><span class="rpc-dir">→</span> <span class="rpc-method">${method}</span> <span class="rpc-params">${params}</span></div>
          <div class="rpc-result"><span class="rpc-dir">←</span> ${result}</div>
        </div>`;
  return `
    <div class="mock">
      <div class="chrome">
        <span class="ws-badge">WS</span>
        <span class="chrome-title">ws://127.0.0.1:9399</span>
        <span class="chrome-meta"><span class="live"></span>connected</span>
      </div>
      <div class="rpc-log">
        ${call("windows.search", `{"query":"vox"}`, `[{"wid":265,"app":"iTerm2","matchSource":"ocr"},\n   {"wid":318,"app":"Zed","matchSource":"title"}]`)}
        ${call("terminals.search", `{"cwd":"vox","hasClaude":true}`, `[{"tty":"/dev/ttys003","tmuxSession":"vox-8c21d0"}, …]`)}
        ${call("windows.place", `{"wid":265,"placement":"left"}`, `{"ok":true,"status":"ok", …}`)}
        ${call("voice.say", `{"text":"vox is on the left."}`, `{"id":"job_9f3","state":"queued"}`)}
        <div><span class="rpc-dir">→</span> <span class="t-cursor"></span></div>
      </div>
    </div>`;
}

// The /speech page's two visuals on one desk: the queue window, and the HUD
// reading along over the workspace, spoken words lit like the mark's bars.
function speechPreview() {
  return `
    <div class="speech-desk">
      <div class="speech-window">
        <div class="chrome">${lights()}<span class="chrome-title">Speech</span><span class="chrome-meta">voice af_heart</span></div>
        <div class="speech-queue">
          <div class="is-playing"><span>▶</span><strong>Agent summary — release build</strong><time>02:14</time></div>
          <div><span>02</span><strong>Download finished</strong><time>00:08</time></div>
          <div><span>03</span><strong>Release notes draft</strong><time>01:42</time></div>
        </div>
        <div class="speech-foot"><span class="live"></span>ws://127.0.0.1:9397<span class="chrome-meta">2 queued</span></div>
      </div>
      <div class="speech-hud">
        <span class="speech-hud-dot"></span>
        <div class="speech-hud-text">
          <strong>Reading · Agent summary</strong>
          <span><b>the release build finished —</b> thirty-four tests passed…</span>
        </div>
        <time>01:58</time>
      </div>
    </div>`;
}

// The Action mark's arrowhead (ActionMark.tsx), tip at the origin; rotate(45) points it up-left, like a pointer.
const ACTION_CURSOR =
  "M 0 0 C 0 -2 3 -3 8 -3.730461265239989 L 170 -79.27230188634977 Q 180 -83.93537846789975 175 -73.93537846789975 L 140 -26 Q 124 0 140 26 L 175 73.93537846789975 Q 180 83.93537846789975 170 79.27230188634977 L 8 3.730461265239989 C 3 3 0 2 0 0 Z";

// The HUD's brand chip: the light app icon, cropped to its tile.
function actionTile(size) {
  return kitFile("action", "action-icon-light.svg").replace(
    'viewBox="0 0 1024 1024"',
    `viewBox="100 100 824 824" width="${size}" height="${size}"`,
  );
}

// Action driving an app in the background: its cursor on Save inside the aim
// frame, the driver badge beside it, and the supervision HUD top-right, where
// Action puts it, narrating the drive.
function actionPreview() {
  return `
    <div class="action-desk">
      <div class="action-window">
        <div class="chrome"><div class="lights action-lights"><i></i><i></i><i></i></div><span class="chrome-title">release-notes.md</span></div>
        <div class="action-sheet">
          <label>Export As</label><div class="action-field">release-notes.pdf</div>
          <label>Where</label><div class="action-field">Documents<i>⌄</i></div>
          <div class="action-buttons">
            <span>Cancel</span>
            <span class="action-target">Save
              <svg class="action-cursor" width="50" height="50"><path d="${ACTION_CURSOR}" transform="scale(${(50 / 181.39).toFixed(4)}) rotate(45)" /></svg>
              <b class="action-badge"><i></i>Codex  ·  Save</b>
            </span>
          </div>
        </div>
      </div>
      <div class="action-hud">
        <div class="action-hud-head">
          ${actionTile(30)}
          <div><strong>Action</strong><small>1 active session</small></div>
          <span class="action-hud-toggle"><svg width="12" height="12" viewBox="0 0 12 12"><path d="M2.5 7.5 6 4l3.5 3.5" /></svg></span>
        </div>
        <div class="action-hud-log">
          <strong>Codex · export release notes</strong>
          <em>Using app controls in the background</em>
          <span>Opening File ▸ Export</span>
          <span>Naming it release-notes.pdf</span>
          <b>Saving to Documents</b>
        </div>
        <div class="action-hud-foot">
          <span class="action-hud-quit">Quit</span>
          <span class="action-hud-stop"><i></i>STOP</span>
        </div>
      </div>
    </div>`;
}

// ── Pages config ────────────────────────────────────────────────
// Every card, product or not, carries the family coral, the accent on every mark.
const latticesAccent = ["#ef6a47", "#d4502c"];

const pages = [
  {
    filename: "og.png",
    tag: "npm install -g lattices",
    title: "lattices",
    subtitle:
      "Screen map, window tiling, and workspace management for macOS developers.",
    preview: screenMapPreview,
  },
  {
    filename: "og-docs.png",
    tag: "docs",
    title: "lattices",
    subtitle:
      "CLI reference, Screen Map guide, RPC API, and configuration docs.",
    preview: docsPreview,
  },
  {
    filename: "og-cli.png",
    tag: "CLI",
    title: "lattices cli",
    subtitle:
      "Declarative tmux sessions. Define your layouts in JSON, launch with one command.",
    preview: terminalPreview,
  },
  {
    filename: "og-api.png",
    tag: "WebSocket API",
    title: "lattices api",
    subtitle:
      "20+ RPC methods over WebSocket. Window tiling, screen map, terminal discovery, and more.",
    preview: apiPreview,
  },
  {
    filename: "og-action.png",
    product: "action",
    tag: "lattices.dev/action",
    title: "action",
    subtitle:
      "Native macOS automation, capture, and review for agents.",
    preview: actionPreview,
  },
  {
    filename: "og-blink.png",
    product: "blink",
    tag: "lattices.dev/blink",
    title: "blink",
    subtitle:
      "Spatial notes: each note is a floating panel, and the desktop is the workspace.",
    preview: () => artPreview("products/blink/landing/public/hero-desk.png"),
  },
  {
    filename: "og-speech.png",
    product: "speech",
    tag: "lattices.dev/speech",
    title: "speech",
    subtitle:
      "Queue text, choose a voice, and control playback independently.",
    preview: speechPreview,
  },
];

// ── HTML builder ────────────────────────────────────────────────
function buildHTML(config) {
  const { tag, title, subtitle, product } = config;
  const [accentFrom, accentTo] = latticesAccent;

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Space+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      width: ${W}px;
      height: ${H}px;
      font-family: 'Space Grotesk', -apple-system, sans-serif;
      background: #111113;
      color: #ebebef;
      position: relative;
      overflow: hidden;
    }

    /* ── 30px grid — tiles perfectly (1200/30=40, 630/30=21) ── */
    .grid {
      position: absolute;
      inset: 0;
      background-image:
        linear-gradient(rgba(255, 255, 255, 0.025) 1px, transparent 1px),
        linear-gradient(90deg, rgba(255, 255, 255, 0.025) 1px, transparent 1px);
      background-size: ${G}px ${G}px;
    }

    /* ── Cross at (${CROSS.x}, ${CROSS.y}): arms run right and down, fading out ── */
    .cross-h, .cross-v {
      position: absolute;
      top: ${CROSS.y}px; left: ${CROSS.x}px;
    }
    .cross-h {
      width: ${CROSS.len}px; height: 1px;
      background: linear-gradient(to right, rgba(255,255,255,0.25), rgba(255,255,255,0.06) 50%, transparent);
    }
    .cross-v {
      width: 1px; height: ${CROSS.len}px;
      background: linear-gradient(to bottom, rgba(255,255,255,0.25), rgba(255,255,255,0.06) 50%, transparent);
    }

    .glow {
      position: absolute;
      top: -${G * 2}px; left: -${G * 2}px;
      width: ${G * 12}px; height: ${G * 12}px;
      border-radius: 50%;
      background: radial-gradient(circle, rgba(255,255,255,0.03) 0%, transparent 70%);
    }

    /* ── Copy column ─────────────────────── */
    .copy {
      position: absolute;
      top: ${BRAND}px; left: ${BRAND}px;
      width: ${COLUMN}px;
      display: flex;
      flex-direction: column;
    }

    .brand {
      width: ${BRAND}px; height: ${BRAND}px;
      display: flex;
      align-items: center;
      margin-bottom: ${G}px;
    }
    .brand svg { display: block; }

    .title {
      font-family: 'JetBrains Mono', monospace;
      font-size: 48px;
      font-weight: 700;
      letter-spacing: -0.03em;
      line-height: 1;
      margin-bottom: 16px;
    }

    .subtitle {
      font-size: 17px;
      color: rgba(255, 255, 255, 0.4);
      line-height: 1.5;
      margin-bottom: 24px;
    }

    .tag {
      display: inline-flex;
      align-items: center;
      padding: 6px 16px;
      border-radius: 6px;
      border: 1px solid rgba(255, 255, 255, 0.12);
      background: rgba(255, 255, 255, 0.04);
      font-family: 'JetBrains Mono', monospace;
      font-size: 13px;
      font-weight: 500;
      color: rgba(255, 255, 255, 0.45);
      width: fit-content;
      letter-spacing: 0.02em;
    }

    /* ── Family sign-off: product cards only ── */
    .family {
      position: absolute;
      left: ${BRAND}px; bottom: ${G * 2}px;
      display: flex;
      align-items: center;
      gap: 12px;
      font-family: 'JetBrains Mono', monospace;
      font-size: 20px;
      font-weight: 600;
      color: rgba(255, 255, 255, 0.72);
    }
    .family svg { display: block; }

    /* ── Preview window: runs off the right and bottom edges ── */
    .preview {
      position: absolute;
      left: ${PREVIEW.x}px; top: ${PREVIEW.y}px;
      width: ${PREVIEW.w}px; height: ${PREVIEW.h}px;
      border-top-left-radius: 16px;
      overflow: hidden;
      background: #18181a;
      box-shadow: 0 0 0 1px rgba(255,255,255,0.09), -24px -12px 64px rgba(0,0,0,0.5);
    }
    .art { display: block; width: 100%; height: 100%; object-fit: cover; }

    .mock {
      width: 100%; height: 100%;
      display: flex;
      flex-direction: column;
      font-family: 'JetBrains Mono', monospace;
      color: rgba(255,255,255,0.7);
    }
    .chrome {
      display: flex;
      align-items: center;
      gap: 14px;
      height: 46px;
      padding: 0 20px;
      border-bottom: 1px solid rgba(255,255,255,0.06);
      flex-shrink: 0;
    }
    .lights { display: flex; gap: 8px; }
    .lights i { display: block; width: 12px; height: 12px; border-radius: 50%; }
    .chrome-title { font-size: 13px; color: rgba(255,255,255,0.45); }
    .chrome-meta { margin-left: auto; font-size: 13px; color: rgba(255,255,255,0.3); }

    pre { font-family: inherit; white-space: pre; }
    pre b { font-weight: 400; color: #7ec8e3; }
    pre em { font-style: normal; color: #ef6a47; }

    /* docs */
    .docs { flex: 1; display: flex; min-height: 0; }
    .docs-nav {
      width: 196px;
      flex-shrink: 0;
      padding: 22px 0 0 22px;
      border-right: 1px solid rgba(255,255,255,0.06);
      font-family: 'Space Grotesk', sans-serif;
    }
    .docs-group {
      font-family: 'JetBrains Mono', monospace;
      font-size: 10px;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: rgba(255,255,255,0.28);
      margin: 18px 0 8px;
    }
    .docs-group:first-child { margin-top: 0; }
    .docs-item { font-size: 14px; color: rgba(255,255,255,0.45); padding: 5px 0 5px 12px; border-left: 2px solid transparent; }
    .docs-item.is-active { color: #ef6a47; border-left-color: #ef6a47; }
    .docs-page { flex: 1; padding: 28px 30px 0; font-family: 'Space Grotesk', sans-serif; min-width: 0; }
    .docs-kicker {
      font-family: 'JetBrains Mono', monospace;
      font-size: 11px;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: rgba(255,255,255,0.3);
      margin-bottom: 10px;
    }
    .docs-page h1 { font-size: 32px; font-weight: 600; letter-spacing: -0.02em; color: rgba(255,255,255,0.92); margin-bottom: 12px; }
    .docs-page h2 { font-size: 20px; font-weight: 600; color: rgba(255,255,255,0.85); margin: 18px 0 0; }
    .docs-page p { font-size: 15px; line-height: 1.55; color: rgba(255,255,255,0.55); }
    .docs-page code { font-family: 'JetBrains Mono', monospace; font-size: 13px; color: rgba(255,255,255,0.8); }
    .docs-page .code {
      margin-top: 16px;
      padding: 16px 18px;
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 10px;
      background: #111113;
      font-family: 'JetBrains Mono', monospace;
      font-size: 12px;
      line-height: 1.65;
      color: rgba(255,255,255,0.6);
    }

    .panes {
      display: grid;
      grid-template-columns: 60% 1fr;
      grid-template-rows: 96px 96px;
      gap: 6px;
      margin-top: 12px;
    }
    .panes div {
      display: flex;
      justify-content: space-between;
      padding: 10px 12px;
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 8px;
      background: rgba(255,255,255,0.02);
      font-family: 'JetBrains Mono', monospace;
      font-size: 12px;
      color: rgba(255,255,255,0.7);
    }
    .panes .is-main { grid-row: 1 / 3; border-color: rgba(239,106,71,0.3); background: rgba(239,106,71,0.06); }
    .panes small { font-size: 11px; color: rgba(255,255,255,0.35); }

    /* terminal */
    .term { flex: 1; display: grid; grid-template-columns: 60% 1fr; min-height: 0; background: #141416; }
    .term-stack { display: grid; grid-template-rows: 1fr 1fr; border-left: 1px solid rgba(255,255,255,0.1); }
    .term-stack .term-pane + .term-pane { border-top: 1px solid rgba(255,255,255,0.1); }
    .term-pane { padding: 16px 14px; font-size: 12px; line-height: 1.7; color: rgba(255,255,255,0.7); overflow: hidden; }
    .term-pane pre { color: rgba(255,255,255,0.55); margin: 2px 0; }
    .t-prompt { color: rgba(255,255,255,0.4); }
    .t-dim { color: rgba(255,255,255,0.38); }
    .t-soft { color: rgba(255,255,255,0.6); }
    .t-ok { color: rgba(255,255,255,0.85); }
    .t-cursor { display: inline-block; width: 8px; height: 15px; vertical-align: -3px; background: rgba(255,255,255,0.5); }
    .tmux-status {
      flex-shrink: 0;
      height: 26px;
      padding: 0 12px;
      display: flex;
      align-items: center;
      background: rgba(239,106,71,0.14);
      color: #ef6a47;
      font-size: 12px;
    }

    /* api */
    .ws-badge { font-size: 12px; color: rgba(255,255,255,0.55); padding: 4px 9px; background: rgba(255,255,255,0.06); border-radius: 5px; }
    .rpc-log { flex: 1; padding: 22px 22px 0; display: flex; flex-direction: column; gap: 20px; font-size: 15px; line-height: 1.7; }
    .rpc-dir { color: rgba(255,255,255,0.3); }
    .rpc-method { color: #ef6a47; }
    .rpc-params { color: rgba(255,255,255,0.6); }
    .rpc-result { color: rgba(255,255,255,0.38); white-space: pre; }
    .live { width: 7px; height: 7px; border-radius: 50%; background: #ef6a47; display: inline-block; margin-right: 8px; vertical-align: 1px; }

    /* speech: the queue window and the HUD, on a desk ruled like the page's */
    .speech-desk {
      position: relative;
      width: 100%; height: 100%;
      background-image:
        linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px),
        linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px);
      background-size: 32px 32px;
      font-family: 'JetBrains Mono', monospace;
    }
    .speech-window {
      position: absolute;
      top: 28px; left: 28px; right: 0;
      border: 1px solid rgba(255,255,255,0.1);
      border-right: 0;
      border-radius: 12px 0 0 12px;
      background: #1c1c1e;
      overflow: hidden;
    }
    .speech-queue { display: grid; gap: 1px; background: rgba(255,255,255,0.06); }
    .speech-queue > div {
      display: grid;
      grid-template-columns: 36px 1fr auto;
      gap: 12px;
      align-items: center;
      padding: 20px 24px;
      background: #1c1c1e;
      color: rgba(255,255,255,0.4);
      font-size: 13px;
    }
    .speech-queue strong { color: rgba(255,255,255,0.92); font-weight: 550; font-size: 16px; }
    .speech-queue .is-playing { background: rgba(239,106,71,0.15); color: #ef6a47; }
    .speech-foot {
      display: flex;
      align-items: center;
      height: 42px;
      padding: 0 24px;
      border-top: 1px solid rgba(255,255,255,0.06);
      font-size: 12px;
      color: rgba(255,255,255,0.3);
    }
    .speech-hud {
      position: absolute;
      left: 60px; right: 60px; bottom: 60px;
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 14px;
      align-items: center;
      padding: 16px 24px;
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 999px;
      background: #1c1c1e;
      box-shadow: 0 18px 40px -18px rgba(0,0,0,0.9);
    }
    .speech-hud-dot { width: 8px; height: 8px; border-radius: 50%; background: #ef6a47; box-shadow: 0 0 10px #ef6a47; }
    .speech-hud-text { display: grid; gap: 4px; min-width: 0; }
    .speech-hud-text strong { color: rgba(255,255,255,0.92); font-size: 13px; font-weight: 550; }
    .speech-hud-text span { color: rgba(255,255,255,0.35); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .speech-hud-text b { font-weight: 400; color: rgba(255,255,255,0.85); }
    .speech-hud time { color: rgba(255,255,255,0.55); font-size: 13px; }

    /* action: a background app's export sheet, Action's cursor aimed at Save, the supervision HUD over it */
    .action-desk {
      position: relative;
      width: 100%; height: 100%;
      background-image:
        linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px),
        linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px);
      background-size: 32px 32px;
      font-family: 'JetBrains Mono', monospace;
    }
    .action-window {
      position: absolute;
      top: 150px; left: 28px; width: 330px;
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 12px;
      background: #1c1c1e;
    }
    .action-lights i { background: rgba(255,255,255,0.14); }
    .action-sheet {
      display: grid;
      grid-template-columns: auto 1fr;
      gap: 14px 16px;
      align-items: center;
      padding: 28px 24px;
      font-size: 13px;
      color: rgba(255,255,255,0.4);
    }
    .action-field {
      display: flex;
      align-items: center;
      justify-content: space-between;
      height: 40px;
      padding: 0 14px;
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 8px;
      background: rgba(255,255,255,0.03);
      font-size: 15px;
      color: rgba(255,255,255,0.85);
      white-space: nowrap;
    }
    .action-field i { font-style: normal; color: rgba(255,255,255,0.35); }
    .action-buttons { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 12px; margin-top: 10px; }
    .action-buttons > span {
      position: relative;
      display: flex;
      align-items: center;
      height: 40px;
      padding: 0 22px;
      border: 1px solid rgba(255,255,255,0.12);
      border-radius: 8px;
      font-size: 15px;
      color: rgba(255,255,255,0.7);
    }
    .action-buttons > .action-target { background: rgba(255,255,255,0.9); border-color: transparent; color: #111113; font-weight: 600; }
    .action-target::after {
      content: "";
      position: absolute;
      inset: -8px;
      border: 2px solid rgba(255,255,255,0.45);
      border-radius: 14px;
      background: rgba(255,255,255,0.07);
      box-shadow: inset 0 0 0 2px rgba(239,106,71,0.55);
    }
    .action-cursor {
      position: absolute;
      left: 60px; top: 29px;
      z-index: 2;
      overflow: visible;
      fill: #ef6a47;
      filter: drop-shadow(0 4px 8px rgba(0,0,0,0.6));
    }
    .action-badge {
      position: absolute;
      left: 108px; top: 68px;
      z-index: 2;
      display: flex;
      align-items: center;
      gap: 10px;
      height: 30px;
      padding: 0 12px;
      border: 1px solid rgba(255,255,255,0.14);
      border-radius: 4px;
      background: linear-gradient(#333335, #1a1a1b 50%, #151516 75%, #1d1d1f);
      box-shadow: 0 12px 28px -10px rgba(0,0,0,0.9);
      font-size: 13px;
      font-weight: 400;
      letter-spacing: 0.04em;
      color: rgba(255,255,255,0.82);
      white-space: pre;
    }
    .action-badge i { width: 7px; height: 7px; border-radius: 1px; background: #ef6a47; }
    .action-hud {
      position: absolute;
      top: 28px; right: 28px; width: 304px;
      z-index: 3;
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: 14px;
      background: #1c1c1e;
      box-shadow: 0 18px 40px -18px rgba(0,0,0,0.9);
      overflow: hidden;
    }
    .action-hud-head {
      display: flex;
      align-items: center;
      gap: 12px;
      height: 54px;
      padding: 0 14px 0 16px;
      border-bottom: 1px solid rgba(255,255,255,0.08);
    }
    .action-hud-head svg { display: block; flex-shrink: 0; }
    .action-hud-head strong { display: block; font-size: 13px; font-weight: 600; color: rgba(255,255,255,0.92); }
    .action-hud-head small { display: block; font-size: 12px; color: rgba(255,255,255,0.4); }
    .action-hud-toggle {
      margin-left: auto;
      display: grid;
      place-items: center;
      width: 30px; height: 30px;
      border: 1px solid rgba(255,255,255,0.14);
      border-radius: 50%;
      color: rgba(255,255,255,0.6);
    }
    .action-hud-toggle path { fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
    .action-hud-log { display: grid; gap: 5px; padding: 16px 18px 18px; background: rgba(0,0,0,0.2); }
    .action-hud-log strong { font-size: 15px; font-weight: 600; color: rgba(255,255,255,0.92); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .action-hud-log em { font-style: normal; font-size: 12px; color: rgba(255,255,255,0.4); margin-bottom: 10px; }
    .action-hud-log span, .action-hud-log b { font-size: 13px; font-weight: 400; color: rgba(255,255,255,0.46); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .action-hud-log b { font-weight: 500; color: rgba(255,255,255,0.92); }
    .action-hud-foot {
      display: flex;
      align-items: center;
      justify-content: space-between;
      height: 58px;
      padding: 0 14px;
      border-top: 1px solid rgba(255,255,255,0.08);
    }
    .action-hud-foot span { display: flex; align-items: center; gap: 8px; height: 32px; padding: 0 14px; border-radius: 8px; font-size: 12px; }
    .action-hud-quit { border: 1px solid rgba(255,255,255,0.19); background: #242426; color: rgba(255,255,255,0.86); font-weight: 500; }
    .action-hud-stop { background: #ef6a47; color: #101518; font-weight: 700; letter-spacing: 0.06em; }
    .action-hud-stop i { width: 9px; height: 9px; border-radius: 2px; background: currentColor; }

    .accent-bar {
      position: absolute;
      bottom: 0; left: 0; right: 0;
      height: 4px;
      background: linear-gradient(90deg, ${accentFrom}, ${accentTo});
    }
  </style>
</head>
<body>
  <div class="grid"></div>
  <div class="glow"></div>
  <div class="cross-h"></div>
  <div class="cross-v"></div>

  <div class="copy">
    <div class="brand">${mark(product ?? "lattices", BRAND)}</div>
    <div class="title">${title}</div>
    <div class="subtitle">${subtitle}</div>
    <div class="tag">${tag}</div>
  </div>
  ${product ? `<div class="family">${mark("lattices", 24)}<span>lattices</span></div>` : ""}

  <div class="preview">${config.preview()}</div>

  <div class="accent-bar"></div>
</body>
</html>`;
}

// ── Generate ────────────────────────────────────────────────────
async function generate(configs) {
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox"],
  });

  for (const config of configs) {
    const page = await browser.newPage();
    await page.setViewport({ width: W, height: H, deviceScaleFactor: 2 });

    const html = buildHTML(config);
    // Not networkidle0: one stalled connection to the font CDN starves it past the timeout.
    await page.setContent(html, { waitUntil: "load" });
    await page.evaluate(async () => {
      document.body.offsetHeight; // lay out first, so the faces in use start loading
      await document.fonts.ready;
    });
    await new Promise((r) => setTimeout(r, 800));

    const output = join(publicDir, config.filename);
    await page.screenshot({
      path: output,
      type: "png",
      clip: { x: 0, y: 0, width: W, height: H },
    });
    await page.close();
    console.log(`  ✓ ${config.filename}`);
  }

  await browser.close();
}

console.log("Generating OG images...\n");
await generate(pages);
console.log("\nDone!");
