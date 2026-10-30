import assert from "node:assert/strict";
import { test } from "node:test";
import { AgentLayerDirector } from "./agent-layer.js";

test("stage attachment validation rejects before dispatch", async () => {
  const director = new AgentLayerDirector("/unused/native-host");
  for (const subjects of [null, [], [{}], [{windowId: -1}], [{windowId: 1.5}], [{bundleId:"x", frame:{x:0,y:0,width:0,height:20}}]]) {
    await assert.rejects(director.attach(subjects));
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

test("open_window validation rejects before dispatch", async () => {
  const director = new AgentLayerDirector("/unused/native-host");
  for (const input of [null, [], {}, {bundleId:""}, {bundleId:"x", url:"file:///etc/hosts"}, {bundleId:"x", file:"relative.txt"},
    {bundleId:"x", url:"https://a.test", file:"/tmp/a"}, {bundleId:"x", frame:{x:0,y:0,width:-1,height:20}}]) {
    await assert.rejects(director.openWindow(input));
  }
});

test("open_window sends only the fields it was given", async () => {
  const director = new AgentLayerDirector("/unused/native-host");
  const calls: unknown[] = [];
  Object.assign(director, { control: async (...args: unknown[]) => { calls.push(args); return {ok:true}; } });
  const frame = {x:100,y:100,width:1100,height:640};
  await director.openWindow({bundleId:"com.google.Chrome", url:"https://example.com", frame});
  await director.openWindow({bundleId:"com.apple.TextEdit", file:"/tmp/notes.txt"});
  assert.deepEqual(calls, [
    ["open_window",{bundleId:"com.google.Chrome", url:"https://example.com", frame},30_000],
    ["open_window",{bundleId:"com.apple.TextEdit", file:"/tmp/notes.txt"},30_000],
  ]);
});
