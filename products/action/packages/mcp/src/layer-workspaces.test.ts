import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { LayerWorkspaces } from "./layer-workspaces.js";

function deferred() {
  let finish!: () => void;
  const promise = new Promise<void>((resolve) => { finish = resolve; });
  return { promise, finish };
}

describe("named layer workspace routing", () => {
  it("retains independent context across concurrent async calls and nested dispatch", async () => {
    const workspaces = new LayerWorkspaces((workspace) => ({ workspace, view: 0, lease: workspace }));
    const stageReady = deferred();
    const agentReady = deferred();
    const nestedDispatch = async () => {
      await Promise.resolve();
      return workspaces.current();
    };
    await Promise.all([
      workspaces.run("stage", async () => {
        workspaces.current().view = 42;
        stageReady.finish();
        await agentReady.promise;
        assert.equal((await nestedDispatch()).workspace, "stage");
        assert.equal(workspaces.current().view, 42);
        assert.equal(workspaces.current().lease, "stage");
      }),
      workspaces.run("agent", async () => {
        await stageReady.promise;
        workspaces.current().view = 73;
        agentReady.finish();
        assert.equal((await nestedDispatch()).workspace, "agent");
        assert.equal(workspaces.current().view, 73);
        assert.equal(workspaces.current().lease, "agent");
      }),
    ]);
    assert.equal(workspaces.current().workspace, "default");
    assert.equal(workspaces.current().view, 0);
  });

  it("serializes mutations in one workspace without blocking another", async () => {
    const workspaces = new LayerWorkspaces((workspace) => ({ workspace }));
    const entered = deferred();
    const release = deferred();
    const events: string[] = [];
    const first = workspaces.run("stage", async () => {
      events.push("first-start");
      entered.finish();
      await release.promise;
      events.push("first-end");
    });
    await entered.promise;
    const second = workspaces.run("stage", async () => { events.push("second"); });
    await workspaces.run("agent", async () => { events.push("agent"); });
    assert.deepEqual(events, ["first-start", "agent"]);
    release.finish();
    await Promise.all([first, second]);
    assert.deepEqual(events, ["first-start", "agent", "first-end", "second"]);
  });

  it("recovers its queue after rejection without leaking the failed scope", async () => {
    const workspaces = new LayerWorkspaces((workspace) => ({ workspace }));
    await assert.rejects(workspaces.run("agent", async () => { throw new Error("operator paused"); }), /operator paused/);
    await workspaces.run("agent", async () => assert.equal(workspaces.current().workspace, "agent"));
    assert.equal(workspaces.current().workspace, "default");
    assert.equal(workspaces.get("stage"), workspaces.get("stage"));
    assert.notEqual(workspaces.get("stage"), workspaces.get("agent"));
  });
});
