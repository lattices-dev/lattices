import { test, expect } from "bun:test";
import { registerEndpoints } from "../src/endpoints.ts";
import { Router } from "../src/router.ts";
import * as moves from "../src/moves.ts";
test("moves preserve first origin, aliases, dry-run and failed-return recovery", async () => {
  moves.clear();
  const w = { wid: 42, address: "0xfake", spaceIds: [1], isFloating: true, displayIndex: 0, frame: {x: 10, y: 20, w: 300, h: 200} } as any;
  let applied: any[] = [], fail = false;
  const router = new Router(() => new Set(["windows.place"]));
  registerEndpoints(router, {bindHost: "127.0.0.1", startedAt: 0, clientCount: () => 0}, undefined, {
    resolveTarget: async () => ({window: w, snap: {displays: [{currentSpaceId: 9}]}}) as any,
    plan: async ops => ops.map(o => o.op),
    apply: async ops => { if (fail) throw Error("compositor failure"); applied.push(...ops); return ops.map(o => o.op); },
    place: async () => { throw Error("unexpected placement"); },
  });
  try {
    await router.dispatch("windows.move", {wid: 42, spaceId: 2, dryRun: true});
    expect(moves.get(42)).toBeUndefined();
    expect(applied).toEqual([]);
    await router.dispatch("windows.move", {wid: 42, spaceId: 2});
    expect(applied[0].workspace).toBe(2);
    w.spaceIds = [2]; w.frame = {x: 100, y: 200, w: 400, h: 300};
    await router.dispatch("windows.move", {wid: 42, displayIndex: 0});
    expect(applied.at(-1).workspace).toBe(9);
    expect(moves.get(42)?.workspace).toBe(1);
    expect(moves.get(42)?.frame).toEqual({x: 10, y: 20, w: 300, h: 200});
    await router.dispatch("windows.moveBack", {wid: 42, dryRun: true});
    expect(moves.get(42)).toBeDefined();
    fail = true;
    await expect(router.dispatch("windows.moveBack", {wid: 42})).rejects.toThrow("compositor failure");
    expect(moves.get(42)).toBeDefined();
    fail = false; applied = [];
    await router.dispatch("windows.moveBack", {wid: 42});
    expect(applied.map(o => o.op)).toEqual(["toWorkspace", "resize", "move"]);
    expect(moves.get(42)).toBeUndefined();
  } finally { moves.clear(); }
});
