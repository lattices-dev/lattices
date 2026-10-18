import { expect, test } from "bun:test";
import { mapWindows, nearbyWindow, spacesFor, nextSpace, parseEntry } from "../FlightDeckModel.mjs";

const makeWindow = (wid: number, x: number, y: number, space = 1, displayIndex = 0) => ({
  wid, app: "kitty", title: "Terminal " + wid, frame: { x, y, w: 400, h: 300 }, spaceIds: [space], displayIndex, isOnScreen: space === 1,
});
const windows = [makeWindow(11, 0, 0), makeWindow(12, 420, 0), makeWindow(13, 420, 320), makeWindow(14, 0, 0, 3), makeWindow(15, 0, 0, 1, 1)];
const display = { displayIndex: 0, currentSpaceId: 1, spaces: [{ id: 1 }, { id: 3 }, { id: 7 }] };

test("Flight Deck projects only this display/space and includes pinned on-screen windows", () => {
  const pinned = { ...makeWindow(16, 900, 0, 7), isOnScreen: true };
  expect(mapWindows([...windows, pinned], display, 1).map(w => w.wid)).toEqual([11, 12, 16, 13]);
  expect(mapWindows([...windows, pinned], display, 3).map(w => w.wid)).toEqual([14]);
  expect(mapWindows(windows, display, 1, "Terminal 12").map(w => w.wid)).toEqual([12]);
  expect(mapWindows(windows, null, 1)).toEqual([]);
});

test("arrow navigation follows geometry and stays put at an edge", () => {
  const local = mapWindows(windows, display, 1);
  expect(nearbyWindow(local, 11, "right")).toBe(12);
  expect(nearbyWindow(local, 12, "down")).toBe(13);
  expect(nearbyWindow(local, 13, "up")).toBe(12);
  expect(nearbyWindow(local, 11, "left")).toBe(11);
  expect(nearbyWindow(local, -1, "right")).toBe(11);
  expect(nearbyWindow([], -1, "right")).toBeNull();
});

test("space inspection wraps existing IDs without creating missing spaces or mutating the inventory", () => {
  const original = { ...display, currentSpaceId: 5 };
  const spaces = spacesFor(original);
  expect(spaces.map(s => s.id)).toEqual([1, 3, 5, 7]);
  expect(nextSpace(spaces, 7, 1)).toBe(1);
  expect(nextSpace(spaces, 1, -1)).toBe(7);
  expect(original.spaces).toHaveLength(3);
});

test("search text never becomes a mutation without an explicit command prefix", () => {
  expect(parseEntry("space next", windows, [])).toEqual({ kind: "search", query: "space next" });
  expect(parseEntry("lats space next", windows, [])).toEqual({ kind: "rpc", method: "spaces.focus", params: { workspace: "e+1", dryRun: false } });
  expect(parseEntry("> space 7 --dry-run", windows, [])).toEqual({ kind: "rpc", method: "spaces.focus", params: { workspace: 7, dryRun: true } });
  for (const input of ["> space 0", "> space constructor", "> space 0x10", "> space 2147483648", "> rm -rf /", "> focus 'unterminated"])
    expect(parseEntry(input, windows, []).kind).toBe("error");
});

test("commands resolve exact windows and refuse ambiguous, stale or hexadecimal IDs", () => {
  expect(parseEntry("> focus kitty", windows, []).kind).toBe("error");
  expect(parseEntry('> focus "Terminal 12"', windows, [])).toEqual({ kind: "rpc", method: "windows.focus", params: { wid: 12 } });
  expect(parseEntry("lats window focus 12 --dry-run", windows, [])).toEqual({ kind: "rpc", method: "windows.resolve", params: { wid: 12 } });
  expect(parseEntry("lats window place 12 right --dry-run", windows, [])).toEqual({ kind: "rpc", method: "windows.place", params: { wid: 12, placement: "right", dryRun: true } });
  for (const input of ["lats window focus 0xc", "lats window focus 999", "lats window place 12 bogus", "lats window focus 12 --wat"])
    expect(parseEntry(input, windows, []).kind).toBe("error");
});

test("layers use exact saved names and canonical tile/reveal actions", () => {
  const layers = [{ id: "build-123", label: "Build tools" }];
  expect(parseEntry('lats layer "Build tools" --tile', windows, layers)).toEqual({ kind: "rpc", method: "layers.activate", params: { layer: "build-123", mode: "tile" } });
  expect(parseEntry("> layer reveal", windows, layers)).toEqual({ kind: "rpc", method: "layers.reveal", params: {} });
  expect(parseEntry("> layer Build", windows, layers).kind).toBe("error");
  expect(parseEntry("> hints", windows, layers)).toEqual({ kind: "page", page: "Hints" });
});
