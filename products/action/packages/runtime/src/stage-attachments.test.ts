import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentLayerDirector } from "./agent-layer.js";

test("stage attachment validation rejects before dispatch", async () => {
  // A scratch root, and a control that fails the test if reached: validation must
  // reject on its own, never by bouncing off a live layer under ~/Library.
  const director = new AgentLayerDirector("/unused/native-host", { root: mkdtempSync(join(tmpdir(), "action-stage-attach-")) });
  Object.assign(director, { control: async () => { throw new Error("dispatched"); } });
  const cases: [unknown, RegExp][] = [
    [null, /1–64 selectors/],
    [[], /1–64 selectors/],
    [[{}], /bundleId or windowId/],
    [[{windowId: -1}], /Invalid windowId/],
    [[{windowId: 1.5}], /Invalid windowId/],
    [[{bundleId:"x", frame:{x:0,y:0,width:0,height:20}}], /Invalid frame/],
  ];
  for (const [subjects, message] of cases) {
    await assert.rejects(director.attach(subjects), message);
  }
});

test("stage controls preserve explicit selectors and placement; detach is separate", async () => {
  const director = new AgentLayerDirector("/unused/native-host");
  const calls: unknown[] = [];
  Object.assign(director, { control: async (...args: unknown[]) => { calls.push(args); return {ok:true}; } });
  const subjects = [
    {bundleId:"app.openscout.scout", frame:{x:0,y:0,width:1920,height:1080}},
    {windowId:123, frame:{x:10,y:20,width:600,height:400}},
    {bundleId:"com.apple.Terminal", windowId:456},
  ];
  await director.attach(subjects);
  await director.detach();
  assert.deepEqual(calls, [["attach",{subjects},30_000],["detach",{},30_000]]);
});
