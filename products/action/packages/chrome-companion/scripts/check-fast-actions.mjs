/** Real DOM guard checks in an isolated headless browser; no model or user profile. */
import assert from "node:assert/strict";
import { runFastBrowser } from "../../runtime/src/fast-browser.ts";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.ACTION_PLAYWRIGHT_MODULE || "playwright");
const build = await Bun.build({ entrypoints: [fileURLToPath(new URL("../src/content-script.ts", import.meta.url))], target: "browser" });
if (!build.success) throw new Error("Content script build failed");
const script = await build.outputs[0].text();
const browser = await chromium.launch({ headless: true, ...(process.env.ACTION_CHROME_EXECUTABLE ? { executablePath: process.env.ACTION_CHROME_EXECUTABLE } : {}) });
try {
  const page = await browser.newPage();
  await page.route("https://action.test/**", route => route.fulfill({ contentType: "text/html", body: '<form><label for="city">City</label><input id="city"><button type="button" id="go">Search</button></form><aside id="unrelated">Animation</aside><input type="password" value="secret"><button disabled>Disabled</button>' }));
  async function reset() {
    await page.goto("https://action.test/");
    await page.evaluate(() => { window.chrome = { runtime: { onMessage: { addListener: fn => { window.actionMessage = message => new Promise(resolve => fn(message, {}, resolve)); } } } }; window.clicks = 0; document.querySelector('#go').onclick = () => window.clicks++; });
    await page.addScriptTag({ content: script });
  }
  const message = (method, params) => page.evaluate(({ method, params }) => window.actionMessage({ method, params }), { method, params });
  const observe = async () => { const response = await message("action.fast.observe", {}); assert.equal(response.ok, true); return response.result; };
  const click = s => message("action.fast.act", { observationId: s.observationId, target: s.controls.find(c => c.name === "Search").id, operation: "CLICK" });
  let passed = 0;
  await reset();
  await page.evaluate(() => document.querySelector('#city').addEventListener('input', e => { e.target.disabled = true; }));
  const partial = await observe();
  const stopped = await message("action.fast.act", { observationId: partial.observationId, target: partial.controls.find(c => c.name === "City").id, operation: "TYPE_TEXT", text: "Lisbon", presentation: { sound: false } });
  assert.equal(stopped.result.status, "uncertain");
  assert.equal(await page.inputValue('#city'), "Lis"); passed++;

  for (const [name, mutation, expected] of [
    ["unrelated changes", () => { document.querySelector('#unrelated').textContent = 'Frame two'; }, "executed"],
    ["moved target", () => { document.querySelector('#go').style.marginLeft = '100px'; }, "executed"],
    ["replaced target", () => { const e = document.querySelector('#go'); e.replaceWith(e.cloneNode(true)); }, "stale"],
    ["changed field", () => { document.querySelector('#city').value = 'London'; }, "stale"],
    ["disabled target", () => { document.querySelector('#go').disabled = true; }, "stale"],
    ["hidden target", () => { document.querySelector('#go').style.visibility = 'hidden'; }, "stale"],
    ["overlay", () => { const e = document.createElement('div'); e.style.cssText = 'position:fixed;inset:0;z-index:999;background:white'; document.body.append(e); }, "stale"],
    ["changed context", () => { document.querySelector('label').textContent = 'Different task'; }, "stale"],
  ]) {
    await reset(); const s = await observe(); assert.equal(s.controls.length, 2);
    await page.evaluate(mutation); const r = await click(s); assert.equal(r.result.status, expected, name); passed++;
  }
  await reset(); let s = await observe();
  assert.equal((await click(s)).result.status, "executed");
  assert.equal((await click(s)).result.status, "stale");
  assert.equal(await page.evaluate(() => window.clicks), 1); passed++;
  await reset(); s = await observe();
  assert.equal((await message("action.fast.act", { observationId: s.observationId, target: "999", operation: "CLICK" })).result.status, "invalid"); passed++;
  await reset(); s = await observe();
  assert.equal((await message("action.fast.act", { observationId: s.observationId, target: s.controls.find(c => c.name === "City").id, operation: "TYPE_TEXT", text: "Lisbon" })).result.status, "executed");
  assert.equal(await page.inputValue('#city'), "Lisbon"); passed++;
  await reset();
  await page.evaluate(() => { document.querySelector('#go').onclick = () => { document.title = 'Results: ' + document.querySelector('#city').value; }; });
  const result = await runFastBrowser({ goal: "Search Lisbon", tabId: 1,
    transport: { observe, act: async choice => (await message("action.fast.act", choice)).result },
    policy: {
      // Deterministic fixture policy tests the runtime; this is not model evidence.
      choose: async (_goal, state) => state.title === "Results: Lisbon" ? { operation: "DONE" } :
        state.controls.find(c => c.name === "City").value !== "Lisbon" ?
          { operation: "TYPE_TEXT", target: state.controls.find(c => c.name === "City").id } :
          { operation: "CLICK", target: state.controls.find(c => c.name === "Search").id },
      writeText: async () => "Lisbon",
      verify: async () => await page.title() === "Results: Lisbon" && await page.inputValue('#city') === "Lisbon",
    },
  });
  assert.equal(result.status, "verified");
  assert.equal(result.history.filter(s => s.receipt?.status === "executed").length, 2); passed++;
  await reset(); s = await observe();
  const visibleChoice = { observationId: s.observationId, target: s.controls.find(c => c.name === "Search").id, operation: "CLICK", presentation: true };
  const visibleClick = message("action.fast.act", visibleChoice);
  await page.waitForSelector('[data-action-presentation]');
  const during = await observe();
  assert.equal(during.controls.length, 2);
  assert.equal(during.text.includes("Action ·"), false);
  assert.equal((await visibleClick).result.status, "executed");
  assert.equal(await page.evaluate(() => window.clicks), 1); passed++;
  await reset(); s = await observe();
  const changingClick = message("action.fast.act", { ...visibleChoice, observationId: s.observationId });
  await page.waitForSelector('[data-action-presentation]');
  await page.evaluate(() => { document.querySelector('#go').disabled = true; });
  assert.equal((await changingClick).result.status, "stale");
  assert.equal(await page.evaluate(() => window.clicks), 0); passed++;
  // Progressive presentation typing: value lands in real chunks, keystrokes count them.
  await reset(); s = await observe();
  await page.evaluate(() => { window.inputEvents = 0; document.querySelector('#city').addEventListener('input', () => window.inputEvents++); });
  const typed = await message("action.fast.act", { observationId: s.observationId, target: s.controls.find(c => c.name === "City").id, operation: "TYPE_TEXT", text: "Barcelona", presentation: { sound: false, volume: 0 } });
  assert.equal(typed.result.status, "executed");
  assert.equal(await page.inputValue('#city'), "Barcelona");
  assert.ok((await page.evaluate(() => window.inputEvents)) >= 3, "progressive input events"); passed++;
  // Muted presentation still executes the same guarded path.
  await reset(); s = await observe();
  assert.equal((await message("action.fast.act", { observationId: s.observationId, target: s.controls.find(c => c.name === "Search").id, operation: "CLICK", presentation: { sound: false } })).result.status, "executed");
  assert.equal(await page.evaluate(() => window.clicks), 1); passed++;
  // Reduced motion skips spatial animation but preserves guarded execution.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await reset(); s = await observe();
  assert.equal((await message("action.fast.act", { observationId: s.observationId, target: s.controls.find(c => c.name === "Search").id, operation: "CLICK", presentation: true })).result.status, "executed");
  assert.equal(await page.evaluate(() => window.clicks), 1);
  await page.emulateMedia({ reducedMotion: null }); passed++;
  console.log(JSON.stringify({ passed, fixtureTask: result.status, browser: browser.version(), evidence: "real DOM; Action content-script handlers; no model or extension transport benchmark" }));
} finally { await browser.close(); }
