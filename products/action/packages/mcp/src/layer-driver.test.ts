import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { AgentLayerStatus } from "@action/protocol";
import type { AgentLayerSnapshot, DevToolsPage } from "@action/runtime";
import { LayerDriver, guardLayerDispatch, type LayerDriverDeps, type LayerStep } from "./layer-driver.js";

function fixture() {
  let status: AgentLayerStatus = {
    active: true,
    owner: "caller",
    subject: { pid: 42 },
    layer: {
      pid: 101,
      displayId: 7,
      startedAt: "2026-10-11T10:00:00Z",
      bounds: { x: 1000, y: 0, width: 800, height: 600 },
      pip: false,
      windows: [],
    },
  };
  const calls: string[] = [];
  const page = {
    target: { id: "owned-page" },
    async call(method: string) { calls.push(method); return {}; },
    async evaluate() { return null; },
    close() { calls.push("close-page"); },
  } as unknown as DevToolsPage;
  const deps: LayerDriverDeps = {
    status: async () => status,
    view: () => undefined,
    guard: async () => {},
    blink: async () => { calls.push("blink"); return { host: "native" }; },
    touch: async () => {},
    mark: async () => {},
    look: async () => ({ unchangedMs: 1000 }) as AgentLayerSnapshot,
    note: async () => {},
    pageOnLayer: async (pid) => {
      assert.equal(pid, 42);
      calls.push("discover-page");
      return { page, port: 9222, geometry: { origin: { x: 1000, y: 50 }, zoom: 1, width: 800, height: 550, visible: true } };
    },
  };
  const driver = new LayerDriver(deps);
  return { driver, deps, calls, page, status: () => status, replace: (patch: Partial<NonNullable<AgentLayerStatus["layer"]>>) => {
    status = { ...status, layer: { ...status.layer!, ...patch } };
  } };
}

describe("layer driver routing contract", () => {
  for (const step of [{ verb: "go", args: { url: "https://example.com" } }, { verb: "js", args: { code: "document.title" } }] satisfies LayerStep[]) {
    it(`refuses ${step.verb} when paused during page discovery`, async () => {
      const test = fixture();
      test.driver.bind(test.status(), "browser", 42);
      const discover = test.deps.pageOnLayer!;
      test.deps.pageOnLayer = async (...args) => {
        const page = await discover(...args);
        test.deps.guard = async () => { throw new Error("operator paused"); };
        return page;
      };
      test.page.evaluate = async () => { throw new Error("must not evaluate"); };
      await assert.rejects(test.driver.step(step), /operator paused/);
      assert.deepEqual(test.calls, ["discover-page", "Emulation.setFocusEmulationEnabled", "close-page"]);
    });
  }

  it("preserves observation while paused and requires resume before new input", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "native");
    test.deps.guard = async () => { throw new Error("operator paused"); };
    await test.driver.step({ verb: "look", args: {} });
    await assert.rejects(test.driver.step({ verb: "type", args: { text: "hello" } }), /operator paused/);
    assert.deepEqual(test.calls, []);
    test.deps.guard = async () => {};
    await test.driver.step({ verb: "type", args: { text: "hello" } });
    assert.deepEqual(test.calls, ["blink"]);
  });

  it("refuses pointer input when paused during aiming", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "browser", 42);
    test.deps.mark = async () => { test.deps.guard = async () => { throw new Error("operator paused"); }; };
    await assert.rejects(test.driver.step({ verb: "click", args: { at: [20, 60], space: "layer" } }), /operator paused/);
    assert.equal(test.calls.some((call) => call.startsWith("Input.")), false);
  });

  it("refuses unbound sessions before input or page discovery", async () => {
    const test = fixture();
    await assert.rejects(test.driver.step({ verb: "type", args: { text: "hello" } }), /No bound/);
    assert.deepEqual(test.calls, []);
  });

  it("does not fall back to native input when CDP discovery fails", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "browser", 42);
    test.deps.pageOnLayer = async () => { throw new Error("CDP unavailable"); };
    await assert.rejects(test.driver.step({ verb: "type", args: { text: "hello" } }), /Native input fallback is disabled/);
    assert.deepEqual(test.calls, []);
  });

  const refused: LayerStep[] = [
    { verb: "click", args: { label: "Browser menu" } },
    { verb: "click", args: { selector: "#missing" } },
    { verb: "click", args: { at: [20, 20], space: "layer" } },
    { verb: "press", args: { key: "cmd+l" } },
    { verb: "drag", args: { from: [20, 60], to: [20, 20], space: "layer" } },
    { verb: "scroll", args: { at: [20, 20], space: "layer", dy: 100 } },
  ];
  for (const step of refused) {
    it(`refuses unsupported browser target ${JSON.stringify(step)}`, async () => {
      const test = fixture();
      test.driver.bind(test.status(), "browser", 42);
      await assert.rejects(test.driver.step(step));
      assert.equal(test.calls.includes("blink"), false);
      assert.equal(test.calls.some((call) => call.startsWith("Input.")), false);
      assert.equal(test.calls.at(-1), "close-page");
    });
  }

  it("reports CDP route, owned target and bound session for successful browser input", async () => {
    const test = fixture();
    const session = test.driver.bind(test.status(), "browser", 42);
    const result = await test.driver.step({ verb: "type", args: { text: "hello" } });
    assert.deepEqual(result, { route: "devtools", session, pageTargetId: "owned-page", text: "hello" });
    assert.deepEqual(test.calls, ["discover-page", "Emulation.setFocusEmulationEnabled", "Input.insertText", "close-page"]);
  });

  it("keeps explicitly native sessions on the native route", async () => {
    const test = fixture();
    const session = test.driver.bind(test.status(), "native");
    const result = await test.driver.step({ verb: "type", args: { text: "hello" } });
    assert.equal(result.route, "blink");
    assert.deepEqual(result.session, session);
    assert.deepEqual(test.calls, ["blink"]);
  });

  for (const patch of [{ pid: 102 }, { displayId: 8 }, { startedAt: "2026-10-11T11:00:00Z" }]) {
    it(`refuses replacement identity ${JSON.stringify(patch)}`, async () => {
      const test = fixture();
      test.driver.bind(test.status(), "browser", 42);
      test.replace(patch);
      await assert.rejects(test.driver.step({ verb: "type", args: { text: "hello" } }), /replaced/);
      assert.deepEqual(test.calls, []);
    });
  }

  it("rechecks session identity after aiming and before pointer input", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "browser", 42);
    test.deps.mark = async () => test.replace({ startedAt: "replacement" });
    await assert.rejects(test.driver.step({ verb: "click", args: { at: [20, 60], space: "layer" } }), /replaced/);
    assert.equal(test.calls.some((call) => call.startsWith("Input.")), false);
    assert.equal(test.calls.includes("blink"), false);
  });

  it("stops a run at the failed browser step without running subsequent native actions", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "browser", 42);
    const result = await test.driver.run([
      { verb: "press", args: { key: "cmd+l" } },
      { verb: "type", args: { text: "must not run" } },
    ]);
    assert.equal(result.ok, false);
    assert.equal(result.failed?.step, 1);
    assert.deepEqual(result.steps, []);
    assert.equal(test.calls.some((call) => call.startsWith("Input.") || call === "blink"), false);
  });

  it("keeps a running script bound to its original session when a new session opens", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "browser", 42);
    const api = test.driver.api();
    test.replace({ startedAt: "replacement" });
    test.driver.bind(test.status(), "native");
    await assert.rejects(api.type("must not run"), /No bound/);
    assert.deepEqual(test.calls, []);
  });

  it("stops a run when a different session is bound between steps", async () => {
    const test = fixture();
    test.driver.bind(test.status(), "native");
    test.deps.blink = async () => {
      test.calls.push("blink");
      test.replace({ startedAt: "replacement" });
      test.driver.bind(test.status(), "native");
      return {};
    };
    const result = await test.driver.run([
      { verb: "type", args: { text: "first" } },
      { verb: "type", args: { text: "must not run" } },
    ]);
    assert.equal(result.ok, false);
    assert.equal(result.failed?.step, 2);
    assert.deepEqual(test.calls, ["blink"]);
  });
});

describe("generic action dispatch guard", () => {
  it("refuses pause or stop after action preparation", async () => {
    const test = fixture();
    const original = test.status();
    for (const reason of ["paused", "stopped"]) {
      test.deps.guard = async () => { throw new Error(`operator ${reason}`); };
      await assert.rejects(guardLayerDispatch(original, test.deps), new RegExp(reason));
    }
  });

  for (const patch of [{ pid: 102 }, { displayId: 8 }, { startedAt: "replacement" }]) {
    it(`refuses replacement ${JSON.stringify(patch)} without choosing a new route`, async () => {
      const test = fixture();
      const original = test.status();
      test.replace(patch);
      await assert.rejects(guardLayerDispatch(original, test.deps), /Refusing to change input routes/);
    });
  }

  it("refuses layer disappearance, appearance, and unready sessions", async () => {
    const test = fixture();
    const active = test.status();
    const inactive: AgentLayerStatus = { active: false, owner: "caller" };
    await assert.rejects(guardLayerDispatch(active, { ...test.deps, status: async () => inactive }), /input routes/);
    await assert.rejects(guardLayerDispatch(inactive, test.deps), /input routes/);
    await assert.rejects(guardLayerDispatch({ ...active, layer: undefined }, test.deps), /input routes/);
  });

  it("allows the unchanged layer and ordinary desktop route", async () => {
    const test = fixture();
    await guardLayerDispatch(test.status(), test.deps);
    const inactive: AgentLayerStatus = { active: false, owner: "caller" };
    await guardLayerDispatch(inactive, { ...test.deps, status: async () => inactive });
  });
});
