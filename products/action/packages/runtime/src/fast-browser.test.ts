import assert from "node:assert/strict";
import { test } from "node:test";
import { runFastBrowser, type FastPolicy, type FastTransport } from "./fast-browser.js";

const snapshot = () => ({ observationId: "one", url: "https://example.test", title: "Fixture", text: "", observeMs: 0, controls: [{ id: "1", role: "button", name: "Go", value: "", operations: ["CLICK" as const] }] });
const policy: FastPolicy = { choose: async () => ({ operation: "CLICK", target: "1" }), verify: async () => false };
test("rejects invented targets before dispatch", async () => {
  let calls = 0;
  await assert.rejects(runFastBrowser({ goal: "Go", tabId: 1, policy: { ...policy, choose: async () => ({ operation: "CLICK", target: "99" }) }, transport: { observe: async () => snapshot(), act: async () => { calls++; return { status: "executed", executeMs: 0 }; } } }), /outside/);
  assert.equal(calls, 0);
});
test("lost execution reply stops without replay and emits receipt", async () => {
  let calls = 0; let receipts = 0;
  const result = await runFastBrowser({ goal: "Go", tabId: 1, policy, onStep: s => { if (s.receipt) receipts++; }, transport: { observe: async () => snapshot(), act: async () => { calls++; throw new Error("connection lost"); } } });
  assert.equal(result.status, "uncertain"); assert.equal(calls, 1); assert.equal(receipts, 1);
});
test("DONE requires fresh independent verification", async () => {
  let observations = 0;
  const result = await runFastBrowser({ goal: "Go", tabId: 1, policy: { ...policy, choose: async () => ({ operation: "DONE" }), verify: async (_, s) => { assert.equal(s.observationId, "2"); return false; } }, transport: { observe: async () => ({ ...snapshot(), observationId: String(++observations) }), act: async () => { throw new Error("unexpected input"); } } });
  assert.equal(result.status, "unverified");
});
test("confirmed stale rejections get a fresh bounded decision", async () => {
  let count = 0;
  const transport: FastTransport = { observe: async () => snapshot(), act: async () => ({ status: ++count === 1 ? "stale" : "executed", executeMs: 0 }) };
  const result = await runFastBrowser({ goal: "Go", tabId: 1, maxSteps: 2, policy, transport });
  assert.equal(result.status, "budget"); assert.equal(count, 2);
});
test("execution is emitted before a failed next observation", async () => {
  let count = 0; let logged = false;
  await assert.rejects(runFastBrowser({ goal: "Go", tabId: 1, policy, onStep: s => { logged = s.receipt?.status === "executed"; }, transport: { observe: async () => { if (count++) throw new Error("navigation"); return snapshot(); }, act: async () => ({ status: "executed", executeMs: 0 }) } }), /navigation/);
  assert.equal(logged, true);
});
test("waits for delayed page progress without repeating input", async () => {
  let observations = 0; let actions = 0; let choices = 0;
  const result = await runFastBrowser({ goal: "Go", tabId: 1, policy: { choose: async () => ++choices === 1 ? { operation: "CLICK", target: "1" } : { operation: "DONE" }, verify: async () => true }, transport: {
    observe: async () => ({ ...snapshot(), title: ++observations < 4 ? "Original" : "Result" }),
    act: async () => { actions++; return { status: "executed", executeMs: 0 }; },
  } });
  assert.equal(result.status, "verified"); assert.equal(actions, 1); assert.equal(choices, 2);
});
test("unchanged page stops before repeated input", async () => {
  let actions = 0;
  const result = await runFastBrowser({ goal: "Go", tabId: 1, settleTimeoutMs: 1, policy, transport: { observe: async () => snapshot(), act: async () => { actions++; return { status: "executed", executeMs: 0 }; } } });
  assert.equal(result.status, "blocked"); assert.equal(actions, 1);
});
test("navigation wait ignores changing suggestions until URL changes", async () => {
  let observations = 0, choices = 0, actions = 0;
  const result = await runFastBrowser({ goal: "Go", tabId: 1, policy: {
    choose: async () => ++choices === 1 ? { operation: "CLICK", target: "1" } : { operation: "DONE" },
    verify: async (_, s) => s.url.endsWith('/result'),
  }, transport: {
    observe: async () => ({ ...snapshot(), text: `Suggestion ${++observations}`, url: observations < 4 ? 'https://action.test/' : 'https://action.test/result' }),
    act: async () => { actions++; return { status: "executed", navigationExpected: true, executeMs: 0 }; },
  } });
  assert.equal(result.status, "verified"); assert.equal(actions, 1); assert.equal(choices, 2);
});
