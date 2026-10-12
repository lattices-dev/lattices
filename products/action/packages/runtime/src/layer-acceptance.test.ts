import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { displayConfigurationDigest, layerAcceptance, type LayerAcceptanceBinding, type LayerAcceptanceRecord } from "./layer-acceptance.js";

const digest = (value: string) => createHash("sha256").update(value).digest("hex");
const binding: LayerAcceptanceBinding = {
  executableSha256: digest("executable"), nativeSourceDigest: digest("native"), orchestrationSourceDigest: digest("orchestration"),
  hostFingerprint: digest("host"), osBuild: "25A123", displayConfigurationDigest: digest("displays"),
};

test("acceptance binds verified artifact references to every build, host and display dimension", () => {
  const directory = mkdtempSync(join(tmpdir(), "action-acceptance-"));
  const path = join(directory, "acceptance.json");
  const evidencePath = join(directory, "observation.json");
  const now = Date.parse("2026-10-11T12:00:00Z");
  const options = { path, now };
  try {
    assert.equal(layerAcceptance(binding, options).state, "missing");
    writeFileSync(path, "{");
    assert.equal(layerAcceptance(binding, options).state, "invalid");
    writeFileSync(evidencePath, "fixture evidence");
    const record: LayerAcceptanceRecord = {
      schemaVersion: 1, outcome: "passed", acceptedAt: "2026-10-11T11:00:00Z", expiresAt: "2026-10-12T11:00:00Z", reviewer: "test operator",
      binding, phases: ["open", "interaction", "close"],
      checks: { physicalDisplayMode: "unchanged-throughout", scale: "unchanged-throughout", arrangement: "unchanged-throughout", frontmostApp: "unchanged-throughout", pointer: "unchanged-throughout", unrelatedWindowFrames: "unchanged-throughout" },
      evidence: [{ path: evidencePath, sha256: digest("fixture evidence") }],
    };
    const save = (value: unknown) => writeFileSync(path, JSON.stringify(value));
    save(record);
    const accepted = layerAcceptance(binding, options);
    assert.equal(accepted.state, "accepted");
    assert.equal(accepted.runningProcessVerified, false);
    for (const key of Object.keys(binding) as (keyof LayerAcceptanceBinding)[]) {
      assert.equal(layerAcceptance({ ...binding, [key]: digest("changed") }, options).state, "stale", key);
    }
    assert.equal(layerAcceptance(binding, { ...options, now: Date.parse(record.expiresAt) }).state, "stale");
    assert.equal(layerAcceptance(binding, { ...options, now: now - 7200000 }).state, "invalid");
    assert.equal(layerAcceptance({ ...binding, hostFingerprint: undefined }, options).state, "unverified");
    assert.equal(layerAcceptance(binding, { ...options, contextError: "Custom native host is unverified." }).state, "unverified");
    save({ ...record, phases: ["open", "close"] });
    assert.equal(layerAcceptance(binding, options).state, "invalid");
    save({ ...record, checks: { ...record.checks, pointer: "restored-after-close" } });
    assert.equal(layerAcceptance(binding, options).state, "invalid");
    save({ ...record, evidence: [] });
    assert.equal(layerAcceptance(binding, options).state, "invalid");
    save(record);
    writeFileSync(evidencePath, "changed evidence");
    assert.equal(layerAcceptance(binding, options).state, "invalid");
    rmSync(evidencePath);
    assert.equal(layerAcceptance(binding, options).state, "invalid");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("display topology hashing is key-order independent and sensitive to arrangement and scale", () => {
  const original = [{ bounds: { x: 0, y: 0 }, pixelWidth: 3024, width: 1512 }];
  assert.equal(displayConfigurationDigest(original), displayConfigurationDigest([{ width: 1512, pixelWidth: 3024, bounds: { y: 0, x: 0 } }]));
  assert.notEqual(displayConfigurationDigest(original), displayConfigurationDigest([{ ...original[0], bounds: { x: 1512, y: 0 } }]));
  assert.notEqual(displayConfigurationDigest(original), displayConfigurationDigest([{ ...original[0], width: 1890 }]));
});
