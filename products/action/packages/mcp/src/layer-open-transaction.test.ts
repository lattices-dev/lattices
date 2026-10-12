import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { canRollbackLayerOpen, completeLayerOpen } from "./layer-open-transaction.js";
import type { AgentLayerStatus } from "@action/protocol";

describe("layer open completion", () => {
  it("rolls back only the created display instance, including reused process ids", () => {
    const created: AgentLayerStatus = {
      active: true, owner: "caller",
      layer: { pid: 100, displayId: 7, startedAt: "first", bounds: { x: 0, y: 0, width: 800, height: 600 }, pip: false, windows: [] },
    };
    assert.equal(canRollbackLayerOpen(created, created), true);
    assert.equal(canRollbackLayerOpen(created, { active: false, owner: "caller" }), true);
    assert.equal(canRollbackLayerOpen(created, { active: true, owner: "caller", pid: 100 }), false);
    for (const patch of [{ pid: 101 }, { displayId: 8 }, { startedAt: "replacement" }]) {
      assert.equal(canRollbackLayerOpen(created, { ...created, layer: { ...created.layer!, ...patch } }), false);
    }
  });
  it("successful setup keeps the layer open", async () => {
    let closed = 0;
    assert.deepEqual(await completeLayerOpen(async () => ({ ok: true }), async () => { closed++; return true; }), { ok: true });
    assert.equal(closed, 0);
  });
  it("Page.navigate timeout closes the created layer before returning the error", async () => {
    const events: string[] = [];
    await assert.rejects(completeLayerOpen(async () => {
      events.push("navigate"); throw new Error("Page.navigate timed out");
    }, async () => { events.push("close"); return true; }), /Page.navigate timed out\. The created layer was closed\./);
    assert.deepEqual(events, ["navigate", "close"]);
  });
  it("an active cleanup result must not claim successful closure", async () => {
    await assert.rejects(completeLayerOpen(async () => { throw new Error("lease failed"); }, async () => false), /Cleanup did not confirm closure/);
  });
  it("cleanup failure preserves the original failure and gives recovery guidance", async () => {
    await assert.rejects(completeLayerOpen(async () => { throw new Error("Page.navigate timed out"); }, async () => { throw new Error("host unavailable"); }), /Page.navigate timed out\. Cleanup failed \(host unavailable\)/);
  });
});
