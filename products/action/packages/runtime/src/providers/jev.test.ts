import assert from "node:assert/strict";
import { test } from "node:test";
import { createJevPolicy } from "./jev.js";
const state = { observationId: "test", url: "https://example.test", title: "Fixture", text: "", observeMs: 0, controls: [
  { id: "1", name: "Search", role: "button", value: "", operations: ["CLICK" as const] },
  { id: "2", name: "Query", role: "input", value: "", operations: ["TYPE_TEXT" as const] },
] };
const operation = { choice: "CLICK", confidence: 0.9, probabilities: { CLICK: 0.9, TYPE_TEXT: 0.05, DONE: 0.04, BLOCKED: 0.01 } };
test("Jev sends speculative compatible heads in one request and consumes only selected head", async () => {
  let calls = 0;
  const policy = createJevPolicy({ apiKey: "fixture", verify: async () => true, fetch: (async (_, init) => {
    calls++; const body = JSON.parse(String(init?.body));
    assert.deepEqual(Object.keys(body.questions.click_target.criteria), ["1"]);
    assert.deepEqual(Object.keys(body.questions.type_text_target.criteria), ["2"]);
    return Response.json({ model: "jev-test", answers: { operation, click_target: { choice: "1", confidence: 1, probabilities: { "1": 1 } }, type_text_target: { deliberately: "unused" } } });
  }) as typeof fetch });
  const decision = await policy.choose("Search", state, []);
  assert.equal(decision.operation, "CLICK"); assert.equal("target" in decision && decision.target, "1"); assert.equal(decision.model, "jev-test"); assert.equal(calls, 1);
});
test("Jev rejects invented targets and malformed probability distributions", async () => {
  for (const target of [{ choice: "99", confidence: 1, probabilities: { "99": 1 } }, { choice: "1", confidence: 1, probabilities: { "1": 0.1 } }]) {
    const policy = createJevPolicy({ apiKey: "fixture", verify: async () => true, fetch: (async () => Response.json({ answers: { operation, click_target: target } })) as typeof fetch });
    await assert.rejects(policy.choose("Search", state, []), /invalid choice/);
  }
});
