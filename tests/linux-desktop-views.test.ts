import { expect, test } from "bun:test";
import { inventory, spaceInventory, consoleCommand, completions, formatResult } from "../apps/linux/DesktopViews.mjs";

const windows = [{ wid: 11, app: "kitty", title: "Editor", displayIndex: 0, spaceIds: [1], isOnScreen: true }, { wid: 12, app: "chromium", title: "Docs", displayIndex: 0, spaceIds: [3], isOnScreen: false }];
const layers = [{ id: "build", label: 'Build "tools"', entries: [{ windows: [windows[0], { wid: 19, app: "kitty", title: "Test runner", presence: "parked", spaceIds: [-1], displayIndex: 0 }] }] }];

test("inventory deduplicates layer members, includes parked windows, and preserves host objects", () => {
  const state = { windows, layers, stage: { parked: [{ wid: 19, app: "kitty", title: "Test runner" }, { wid: 20, app: "foot", title: "Unassigned" }] } };
  const result = inventory(state);
  expect(result).toHaveLength(4);
  expect(result.find(w => w.wid === 11)).toMatchObject({ presence: "showing", layerNames: ['Build "tools"'] });
  expect(result.find(w => w.wid === 12).presence).toBe("elsewhere");
  expect(result.filter(w => w.presence === "parked")).toHaveLength(2);
  expect(windows[0]).not.toHaveProperty("layerNames");
  const spaces = spaceInventory([{ displayIndex: 0, displayId: "DP-1", currentSpaceId: 1, spaces: [{ id: 1 }, { id: 3 }] }], result);
  expect(spaces.map(s => s.visibleCount)).toEqual([1, 1]);
});

test("console exposes bounded reads and exact mutations without falling back to shell execution", () => {
  expect(consoleCommand("lats doctor", windows, layers)).toEqual({ kind: "rpc", method: "app.doctor", params: {}, read: true });
  expect(consoleCommand("lats windows --json", windows, layers)).toMatchObject({ method: "windows.list", json: true });
  expect(consoleCommand("lats\u200bwindows", windows, layers).method).toBe("windows.list");
  expect(consoleCommand("lats\u00a0windows", windows, layers).method).toBe("windows.list");
  expect(consoleCommand('lats search "Docs"', windows, layers).params).toEqual({ query: "Docs", limit: 50 });
  expect(consoleCommand("lats window focus 12 --dry-run", windows, layers).method).toBe("windows.resolve");
  expect(consoleCommand("lats window place 12 right --dry-run --json", windows, layers)).toMatchObject({ method: "windows.place", params: { wid: 12, dryRun: true }, json: true });
  expect(consoleCommand('session "/tmp/project with spaces"', windows, layers).params).toEqual({ path: "/tmp/project with spaces" });
  for (const input of ["rm -rf /", "lats window focus 0xc", "lats window focus 999", "session relative/path", "lats start /tmp/project", "lats doctor --wat", "help --json", "lats app mission --json"])
    expect(consoleCommand(input, windows, layers).kind).toBe("error");
});

test("completion quotes saved layer names so the completed command resolves the same layer", () => {
  const result = completions("lats layer ", windows, layers);
  expect(result).toContain('lats layer "Build \\"tools\\"" --tile');
  expect(consoleCommand(result[0], windows, layers)).toMatchObject({ kind: "rpc", method: "layers.activate", params: { layer: "build", mode: "tile" } });
});

test("transcripts distinguish previews from execution and flatten control characters in window titles", () => {
  expect(formatResult("windows.resolve", { window: { wid: 11, title: "Editor\nFAKE PROMPT" } })).toContain("Editor FAKE PROMPT\nPreview only");
  expect(formatResult("windows.place", { status: "planned", target: { wid: 11 }, placement: "right", frame: { x: 100, y: 0, w: 100, h: 100 } })).toContain("no window moved");
  expect(formatResult("spaces.focus", { status: "planned", target: "e+1" })).toContain("no space changed");
  expect(formatResult("tmux.list", [])).toBe("No tmux sessions running.");
  expect(formatResult("app.doctor", { report: { ok: false, checks: [{ state: "fail", name: "Host connection", detail: "Offline" }] } })).toContain("✗ Host connection: Offline");
  const receipt = { status: "planned", target: "e+1", currentSpaceId: 1 };
  expect(JSON.parse(formatResult("spaces.focus", receipt, true))).toEqual(receipt);
});
