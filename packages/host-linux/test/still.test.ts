import { expect, test } from "bun:test";
import { stillScale } from "../src/endpoints.ts";

const displays = [
  { frame: { x: 0, y: 0, w: 3440, h: 1440 }, scale: 1 },
  { frame: { x: 3440, y: 0, w: 1920, h: 1080 }, scale: 2 },
];

test("a region takes the scale of the display under its centre", () => {
  expect(stillScale(displays, { x: 100, y: 100, w: 800, h: 600 })).toBe(1);
  expect(stillScale(displays, { x: 3500, y: 200, w: 400, h: 300 })).toBe(2);
});

test("a region off every display falls back to 1", () => {
  expect(stillScale(displays, { x: -900, y: -900, w: 10, h: 10 })).toBe(1);
});
