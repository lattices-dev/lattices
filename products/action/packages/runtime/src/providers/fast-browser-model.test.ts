import assert from "node:assert/strict";
import { test } from "node:test";
import { createFastBrowserPolicy } from "./fast-browser-model.js";
const snapshot = { observationId: "one", url: "https://example.test", title: "Test", text: "", controls: [], observeMs: 0 };
test("choice and text use independently configured models without extra choice calls", async () => {
  const requests: { model: string }[] = [];
  const policy = createFastBrowserPolicy({ baseURL: "https://model.test/v1", apiKey: "fixture", model: "chooser", textModel: "writer", verify: async () => true, fetch: (async (url, init) => {
    assert.equal(String(url), "https://model.test/v1/chat/completions");
    const body = JSON.parse(String(init?.body)); requests.push(body);
    return Response.json({ choices: [{ message: { content: JSON.stringify(body.model === "chooser" ? { operation: "TYPE_TEXT", target: "1" } : { text: "Lisbon" }) } }] });
  }) as typeof fetch });
  assert.deepEqual(await policy.choose("Go", snapshot, []), { operation: "TYPE_TEXT", target: "1" });
  assert.equal(await policy.writeText!("Go", snapshot, "1"), "Lisbon");
  assert.deepEqual(requests.map(r => r.model), ["chooser", "writer"]);
});
test("rejects selector or code fields in model decisions", async () => {
  const policy = createFastBrowserPolicy({ baseURL: "https://model.test/v1", apiKey: "fixture", model: "chooser", verify: async () => false, fetch: (async () => Response.json({ choices: [{ message: { content: '{"operation":"CLICK","target":"1","selector":"button"}' } }] })) as typeof fetch });
  await assert.rejects(policy.choose("Go", snapshot, []), /shape/);
});
