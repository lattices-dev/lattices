/**
 * Records a real Action presentation run in a dedicated fixture browser.
 * No user profile, no model: a deterministic policy drives the actual
 * content-script handlers while Playwright records the rendered page,
 * so the saved video shows the exact overlay that executed each input.
 */
import { runFastBrowser } from "../../runtime/src/fast-browser.ts";
import { createRequire } from "node:module";
import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.ACTION_PLAYWRIGHT_MODULE || "playwright");

const output = new URL(`../../../artifacts/presentation-demo-${Date.now()}`, import.meta.url).pathname;
await mkdir(output, { recursive: true });

const build = await Bun.build({ entrypoints: [fileURLToPath(new URL("../src/content-script.ts", import.meta.url))], target: "browser" });
if (!build.success) throw new Error("Content script build failed");
const script = await build.outputs[0].text();

const browser = await chromium.launch({ headless: true, ...(process.env.ACTION_CHROME_EXECUTABLE ? { executablePath: process.env.ACTION_CHROME_EXECUTABLE } : {}) });
const context = await browser.newContext({ viewport: { width: 960, height: 640 }, recordVideo: { dir: output, size: { width: 960, height: 640 } } });
const page = await context.newPage();

const home = `<body style="margin:0;font-family:system-ui;background:#f6f1e8;color:#1c1a17">
  <main style="max-width:640px;margin:120px auto;padding:0 24px">
    <h1 style="font-size:34px;letter-spacing:-.02em">Biography desk</h1>
    <p style="color:#6b6459">Look up a life worth reading about.</p>
    <form style="display:flex;gap:10px;margin-top:28px" onsubmit="return false">
      <input id="q" aria-label="Person" placeholder="Name a person…" style="flex:1;font-size:17px;padding:12px 14px;border:1.5px solid #d8d0c2;border-radius:10px">
      <button id="go" type="button" style="font-size:15px;padding:12px 20px;border:0;border-radius:10px;background:#ef6a47;color:#fff">Search</button>
    </form>
    <nav style="margin-top:56px;display:flex;gap:18px;font-size:14px">
      <a href="https://action.test/about" style="color:#8a5a44">About</a>
      <a href="https://action.test/archive" style="color:#8a5a44">Archive</a>
    </nav>
  </main>
  <script>
    document.querySelector('#go').onclick = () => {
      const q = document.querySelector('#q').value || 'someone';
      document.title = 'Results: ' + q;
      document.querySelector('main').innerHTML =
        '<h1 style="font-size:30px">' + q + '</h1><p style="color:#6b6459">Polish–French physicist and chemist. ' +
        'Pioneered research on radioactivity; first person to win two Nobel Prizes.</p>';
    };
  <\/script></body>`;

await page.route("https://action.test/**", route => route.fulfill({ contentType: "text/html", body: home }));
await page.goto("https://action.test/");
await page.evaluate(() => {
  window.chrome = { runtime: { onMessage: { addListener: fn => { window.actionMessage = message => new Promise(resolve => fn(message, {}, resolve)); } } } };
});
await page.addScriptTag({ content: script });
const message = (method, params) => page.evaluate(({ method, params }) => window.actionMessage({ method, params }), { method, params });

// Let the first frame settle before the run so the recording starts on the fixture.
await page.waitForTimeout(700);

const result = await runFastBrowser({
  goal: "Search for Marie Curie",
  tabId: 1,
  presentation: { sound: true, volume: 0.4 },
  transport: {
    observe: async () => (await message("action.fast.observe", {})).result,
    act: async choice => (await message("action.fast.act", choice)).result,
  },
  policy: {
    // Deterministic fixture policy: tests the runtime and presentation, not a model.
    choose: async (_goal, state) => state.title.startsWith("Results:") ? { operation: "DONE" }
      : state.controls.find(c => c.name.includes("Person")).value !== "Marie Curie"
        ? { operation: "TYPE_TEXT", target: state.controls.find(c => c.name.includes("Person")).id }
        : { operation: "CLICK", target: state.controls.find(c => c.name === "Search").id },
    writeText: async () => "Marie Curie",
    verify: async (_goal, snap) => snap.title === "Results: Marie Curie" && snap.text.includes("radioactivity"),
  },
  onStep: step => console.log(JSON.stringify({ event: "step", op: step.decision?.operation, status: step.receipt?.status, executeMs: Math.round(step.executeMs), observeMs: Math.round(step.observeMs) })),
});

// Hold the finished frame so the receipt state is visible in the video.
await page.waitForTimeout(1200);
const video = page.video();
await context.close();
await browser.close();
const videoPath = await video.path();
console.log(JSON.stringify({ status: result.status, steps: result.history.length, elapsedMs: Math.round(result.elapsedMs), video: videoPath, output }));
if (result.status !== "verified") process.exitCode = 1;
