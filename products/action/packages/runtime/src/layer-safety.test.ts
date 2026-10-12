import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { assertLayerSafety, layerSafety } from "./layer-safety.js";

describe("host private-layer safety quarantine", () => {
  function fixture(run: (path: string) => void) {
    const root = mkdtempSync(join(tmpdir(), "action-layer-safety-"));
    try { run(join(root, "isolation-block.json")); } finally { rmSync(root, { recursive: true, force: true }); }
  }
  it("absent record is not represented as verified acceptance", () => fixture(path => {
    assert.equal(layerSafety(path).state, "not-quarantined");
    assert.match(layerSafety(path).reason, /not proof/);
    assert.doesNotThrow(() => assertLayerSafety(path));
  }));
  it("known failed preservation blocks before opening", () => fixture(path => {
    writeFileSync(path, JSON.stringify({ blocked: true, reason: "Physical mode changes", evidence: "/report" }));
    assert.equal(layerSafety(path).evidence, "/report");
    assert.throws(() => assertLayerSafety(path), /Physical mode changes.*No virtual display was created/);
  }));
  it("invalid records fail closed", () => fixture(path => {
    for (const contents of ["{", "{}", '{"blocked":"false"}', "null"]) {
      writeFileSync(path, contents); assert.equal(layerSafety(path).blocked, true);
    }
  }));
  it("an explicitly cleared record is allowed without claiming acceptance", () => fixture(path => {
    writeFileSync(path, JSON.stringify({ blocked: false, reason: "Controlled retest cleared" }));
    assert.equal(layerSafety(path).state, "not-quarantined");
    assert.doesNotThrow(() => assertLayerSafety(path));
  }));
});
