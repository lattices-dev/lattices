import { describe, expect, test } from "bun:test";
import { tideExtremes, tideHeight, tideNow, tideToday, tideTomorrowFirstHigh } from "./heroTide";

describe("hero tide chart", () => {
  test("every labelled extreme is a peak or trough of the curve", () => {
    for (const extreme of tideToday) {
      const here = tideHeight(extreme.minute);
      expect(here).toBeCloseTo(extreme.feet, 6);
      for (const offset of [-20, 20]) {
        const beside = tideHeight(extreme.minute + offset);
        if (extreme.kind === "High") expect(beside).toBeLessThan(here);
        else expect(beside).toBeGreaterThan(here);
      }
    }
  });

  test("highs and lows alternate", () => {
    tideExtremes.slice(1).forEach((extreme, index) => {
      expect(extreme.kind).not.toBe(tideExtremes[index].kind);
    });
  });

  test("the page's readings match the data", () => {
    expect(tideToday.map((extreme) => `${extreme.kind} ${extreme.time}`)).toEqual([
      "High 5:12 AM",
      "Low 11:24 AM",
      "High 5:36 PM",
      "Low 11:48 PM",
    ]);
    expect(tideNow.time).toBe("9:41 AM");
    expect(tideNow.feet.toFixed(1)).toBe("1.4");
    expect(tideNow.falling).toBe(true);
    expect(tideTomorrowFirstHigh).toBe("High 6:03 AM");
  });

  test("the chart stays inside its frame", () => {
    for (let minute = 0; minute <= 24 * 60; minute += 5) {
      const feet = tideHeight(minute);
      expect(feet).toBeGreaterThanOrEqual(0.4 - 1e-9);
      expect(feet).toBeLessThanOrEqual(6.1 + 1e-9);
    }
  });
});
