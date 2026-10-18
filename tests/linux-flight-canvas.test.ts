import { expect, test } from "bun:test";
import { workspaceSheets, worldBounds, sheetBounds, fitCamera, zoomCamera, interpolateCamera, resizedCamera, reconcileCamera } from "../apps/linux/FlightCanvasModel.mjs";

const display = { displayIndex: 0, currentSpaceId: 3, frame: { x: 1920, y: 0, w: 1600, h: 900 }, spaces: [{ id: 1 }, { id: 3 }, { id: 7 }] };
const windows = [{ wid: 11, app: "kitty", title: "Editor", displayIndex: 0, spaceIds: [1], frame: { x: 1920, y: 0, w: 800, h: 900 } }, { wid: 12, app: "chromium", title: "Docs", displayIndex: 0, spaceIds: [3], frame: { x: 2720, y: 0, w: 800, h: 900 } }];

test("canvas places real, nonconsecutive space IDs in one continuous world without mutating inventory", () => {
  const sheets = workspaceSheets(display, windows, "");
  expect(sheets.map(s => s.id)).toEqual([1, 3, 7]);
  expect(sheets.map(s => s.windows.length)).toEqual([1, 1, 0]);
  expect(sheets[1].current).toBe(true);
  expect(sheets[1].x).toBeGreaterThan(sheets[0].x + sheets[0].w);
  expect(worldBounds(sheets).w).toBe(sheets[2].x + sheets[2].w);
  expect(workspaceSheets(display, windows, "Docs")[0].windows).toHaveLength(0);
  expect(workspaceSheets(null, windows, "")).toEqual([]);
  expect(windows[0].frame.x).toBe(1920);
});

test("fit all includes every workspace within the viewport and zooming keeps the cursor's world point fixed", () => {
  const sheets = workspaceSheets(display, windows, "");
  const bounds = worldBounds(sheets);
  const all = fitCamera(bounds, 1000, 600);
  expect(all.x).toBeGreaterThanOrEqual(27);
  expect(all.x + bounds.w * all.zoom).toBeLessThanOrEqual(973);
  const space = fitCamera(sheetBounds(sheets[1]), 1000, 600);
  expect(space.zoom).toBeGreaterThan(all.zoom);
  const x = 320, y = 250;
  const next = zoomCamera(space, 1.8, x, y, all.zoom * 0.45, space.zoom * 5);
  expect((x - next.x) / next.zoom).toBeCloseTo((x - space.x) / space.zoom, 8);
  expect((y - next.y) / next.zoom).toBeCloseTo((y - space.y) / space.zoom, 8);
  expect(zoomCamera(space, 1e6, x, y, 0.1, 2).zoom).toBe(2);
  expect(zoomCamera(space, 1e-6, x, y, 0.1, 2).zoom).toBe(0.1);
});

test("resize preserves the world point at the viewport center", () => {
  const camera = { zoom: 0.5, x: -400, y: 80 };
  const next = resizedCamera(camera, 1000, 600, 600, 400);
  expect((300 - next.x) / next.zoom).toBe((500 - camera.x) / camera.zoom);
  expect((200 - next.y) / next.zoom).toBe((300 - camera.y) / camera.zoom);
});

test("animated zoom preserves the pointer's world point throughout the motion", () => {
  const from = { zoom: 0.2, x: -80, y: 40 }, x = 420, y = 270;
  const to = zoomCamera(from, 4, x, y, 0.01, 5);
  for (const t of [0, 0.1, 0.25, 0.5, 0.8, 1]) {
    const frame = interpolateCamera(from, to, t, x, y);
    expect((x - frame.x) / frame.zoom).toBeCloseTo((x - from.x) / from.zoom, 8);
    expect((y - frame.y) / frame.zoom).toBeCloseTo((y - from.y) / from.zoom, 8);
    expect(frame.zoom).toBeGreaterThanOrEqual(from.zoom);
    expect(frame.zoom).toBeLessThanOrEqual(to.zoom);
  }
  expect(interpolateCamera(from, to, 0.5, x, y).zoom).toBeCloseTo(0.4, 8);
});

test("framing motion interpolates the visible world center without overshoot", () => {
  const from = { zoom: 0.1, x: -100, y: 30 }, to = { zoom: 0.8, x: -2400, y: 100 };
  const middle = interpolateCamera(from, to, 0.5, 500, 300);
  expect((500 - middle.x) / middle.zoom).toBeCloseTo(((500 - from.x) / from.zoom + (500 - to.x) / to.zoom) / 2, 8);
  expect(interpolateCamera(from, to, -1, 500, 300)).toBe(from);
  expect(interpolateCamera(from, to, 2, 500, 300)).toBe(to);
});

test("inserting and removing earlier spaces preserves the visible sheet's screen position", () => {
  const before = workspaceSheets(display, windows, "");
  const anchor = before.find(s => s.id === 3);
  const camera = fitCamera(sheetBounds(anchor), 1000, 600);
  const inserted = workspaceSheets({ ...display, spaces: [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 7 }] }, windows, "");
  const moved = reconcileCamera(camera, before, inserted, 1000, 3);
  expect(moved.x + inserted.find(s => s.id === 3).x * moved.zoom).toBeCloseTo(camera.x + anchor.x * camera.zoom, 8);
  const removed = workspaceSheets({ ...display, spaces: [{ id: 3 }, { id: 7 }] }, windows, "");
  const after = reconcileCamera(moved, inserted, removed, 1000, 3);
  expect(after.x + removed[0].x * after.zoom).toBeCloseTo(camera.x + anchor.x * camera.zoom, 8);
  expect(after.zoom).toBe(camera.zoom);
});
