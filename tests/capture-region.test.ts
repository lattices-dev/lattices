import { expect, test } from "bun:test";
import { parseCaptureRegionArgs } from "../bin/cli/capture.ts";
import { createWorkspaceMapSnapshot } from "../bin/cli/map.ts";

test("still regions accept global signed coordinates and artifact options", () => {
  expect(parseCaptureRegionArgs(["--x", "-120", "--y=0", "--width", "500", "--height", "400", "--filename", "panel.png", "--run-id", "run-1"])).toEqual({
    source: "cli", x: -120, y: 0, width: 500, height: 400,
    filename: "panel.png", runId: "run-1",
  });
});
test("still regions reject incomplete, nonfinite and empty rectangles", () => {
  for (const args of [
    [], ["--x", "0", "--y", "0", "--width", "0", "--height", "10"],
    ["--x", "NaN", "--y", "0", "--width", "10", "--height", "10"],
    ["--x", "0", "--y", "0", "--width", "10", "--height", "-1"],
  ]) expect(() => parseCaptureRegionArgs(args)).toThrow();
});

test("map includes raw on-screen panel inventory by geometry without Space IDs", () => {
  const result = createWorkspaceMapSnapshot([{
    displayIndex: 0, displayId: "main", currentSpaceId: 7,
    frame: { x: 0, y: 0, w: 3440, h: 1440 },
  }], [{
    wid: 134, app: "Scout", title: "", cgLayer: 3,
    frame: { x: 0, y: 0, w: 3440, h: 1440 }, spaceIds: [], isOnScreen: true,
  }]);
  expect(result.displays[0]?.windows[0]?.wid).toBe(134);
  expect(result.displays[0]?.windows[0]?.cgLayer).toBe(3);
});

// Use the same caller-injected search surface as the CLI and MCP; no live daemon.
test("panel search matches untitled apps and titles without replacing unified search", async () => {
  const { searchWithClient } = await import("../bin/cli/search.ts");
  const calls: string[] = [];
  const client = {
    daemonCall: async (method: string, params?: any) => {
      calls.push(method);
      if (method === "windows.list") {
        expect(params).toEqual({ includePanels: true });
        return [
          { wid: 134, app: "Scout", title: "", cgLayer: 3 },
          { wid: 123, app: "Scout", title: "Scout" },
          { wid: 456, app: "Ghostty", title: "scout debugger" },
          { wid: 789, app: "Other", title: "" },
        ];
      }
      expect(method).toBe("search.query");
      expect(params).toEqual({ query: "scout", sources: ["all"] });
      return [{ wid: 123, app: "Scout", title: "Scout", score: 4, matchSources: ["app"] }];
    },
  };
  const panels = await searchWithClient(client, "sCoUt", { includePanels: true });
  expect(panels.map(result => result.window.wid)).toEqual([134, 123, 456]);
  const normal = await searchWithClient(client, "scout", { sources: ["all"] });
  expect(normal[0]?.reasons).toEqual(["app"]);
  expect(calls).toEqual(["windows.list", "search.query"]);
});
