import { expect, test } from "bun:test";
import { Router } from "../src/router.ts";
import { registerSpaceFocus } from "../src/spaces.ts";
import { spell, type Op } from "../src/hyprland.ts";

function fixture() {
  const router = new Router(() => new Set(["spaces.read"]));
  const ops: Op[] = [];
  let reads = 0;
  let current = 4;
  registerSpaceFocus(router, {
    snapshot: async () => { reads++; return { monitors: [{ name: "HDMI-A-1", focused: true }], displays: [{ displayId: "HDMI-A-1", displayIndex: 0, currentSpaceId: current }] }; },
    apply: async actions => { ops.push(...actions); current = 1; return actions.map(action => spell(action, true)); },
  });
  return { router, ops, reads: () => reads };
}

test("space dry runs read the focused display without dispatching", async () => {
  const f = fixture();
  const result = await f.router.dispatch("spaces.focus", { workspace: "e+1", dryRun: true });
  expect(result).toMatchObject({ status: "planned", target: "e+1", currentSpaceId: 4 });
  expect(f.ops).toEqual([]);
  expect(f.reads()).toBe(1);
});

test("space switching returns the observed current workspace", async () => {
  const f = fixture();
  const result = await f.router.dispatch("spaces.focus", { workspace: "e+1" });
  expect(result).toMatchObject({ status: "ok", currentSpaceId: 1, displayIndex: 0 });
  expect(f.ops).toEqual([{ op: "focusWorkspace", workspace: "e+1" }]);
});

test("arbitrary dispatcher text and invalid IDs fail before compositor reads", async () => {
  const f = fixture();
  for (const workspace of [0, -1, 1.5, 2147483648, "1", "special:lattices", '1; exec evil', null]) {
    await expect(f.router.dispatch("spaces.focus", { workspace })).rejects.toThrow("workspace must be");
  }
  expect(f.ops).toEqual([]);
  expect(f.reads()).toBe(0);
});

test("relative workspace tokens are correctly spelled in both Hyprland dialects", () => {
  expect(spell({ op: "focusWorkspace", workspace: "e-1" }, true)).toBe('hl.dsp.focus({ workspace = "e-1" })');
  expect(spell({ op: "focusWorkspace", workspace: "previous" }, false)).toBe("workspace previous");
  expect(spell({ op: "focusWorkspace", workspace: 7 }, true)).toBe("hl.dsp.focus({ workspace = 7 })");
});
