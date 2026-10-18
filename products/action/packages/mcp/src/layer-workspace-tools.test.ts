import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { advertisedTools } from "./index.js";

describe("named workspace MCP discovery", () => {
  const tools = advertisedTools();
  const layers = tools.filter((tool) => tool.name.startsWith("layer_") || tool.name.startsWith("action.layer."));

  it("advertises an optional workspace on every layer tool", () => {
    assert.equal(layers.length >= 14, true);
    for (const tool of layers) {
      const workspace = tool.inputSchema.properties?.workspace as { type?: string } | undefined;
      assert.equal(workspace?.type, "string", tool.name);
      assert.equal(tool.inputSchema.required?.includes("workspace") ?? false, false, tool.name);
    }
  });

  it("advertises explicit preview placement only on open and pip", () => {
    const previews = layers.filter((tool) => tool.inputSchema.properties?.previewWorkspace);
    assert.equal(previews.length, 2);
    assert.equal(previews.some((tool) => /(?:_|\.)open$/.test(tool.name)), true);
    assert.equal(previews.some((tool) => /(?:_|\.)pip$/.test(tool.name)), true);
  });

  it("keeps desktop input separate from workspace primitives", () => {
    const execute = tools.find((tool) => tool.name === "act_execute" || tool.name === "action.act.execute");
    assert.ok(execute);
    assert.equal(execute.inputSchema.properties?.workspace, undefined);
  });

  it("exposes full-display preview framing on open and pip without changing snapshot framing", () => {
    const previews = layers.filter((tool) => tool.inputSchema.properties?.previewFull);
    assert.equal(previews.length, 2);
    for (const tool of previews) {
      assert.match(tool.name, /(?:_|\.)(open|pip)$/);
      assert.equal((tool.inputSchema.properties?.previewFull as { type?: string }).type, "boolean");
      assert.equal(tool.inputSchema.required?.includes("previewFull") ?? false, false);
    }
    const snapshot = layers.find((tool) => /(?:_|\.)snapshot$/.test(tool.name));
    assert.ok(snapshot?.inputSchema.properties?.full);
    assert.equal(snapshot.inputSchema.properties.previewFull, undefined);
  });
});
