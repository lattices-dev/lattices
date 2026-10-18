import { describe, expect, test } from "bun:test";

globalThis.HTMLElement = class {};
globalThis.customElements = {
  get() { return true; },
  define() {}
};

const { normalizeDefinition, sampleDefinition } = await import("../index.mjs");

describe("Action Studio definition model", () => {
  test("normalizes text fields and isolates mutable outcomes", () => {
    const first = normalizeDefinition({
      name: "  Present  ",
      triggers: ["  Show this  "]
    });
    const second = normalizeDefinition({ name: "Present" });

    expect(first.name).toBe("Present");
    expect(first.triggers).toEqual(["Show this"]);
    first.outcomes[0].label = "Changed";
    expect(second.outcomes[0].label).toBe("Release page");
  });

  test("exports an isolated sample definition", () => {
    const normalized = normalizeDefinition(sampleDefinition);
    normalized.behavior.reuseOpenWindows = false;
    expect(sampleDefinition.behavior.reuseOpenWindows).toBe(true);
  });
});
