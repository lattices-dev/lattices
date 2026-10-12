import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { actionCapabilities, orchestrationDigest, refreshActionCapabilities } from "./capabilities.js";
import { displayConfigurationDigest } from "./layer-acceptance.js";

test("discovery distinguishes orchestration, missing native proof and transport routes", () => {
  const root = mkdtempSync(join(tmpdir(), "action-capabilities-"));
  try {
    writeFileSync(join(root, "package.json"), '{"version":"0.3.0"}');
    mkdirSync(join(root, "packages"));
    writeFileSync(join(root, "packages", "entry.ts"), "export const version = 1;");
    const digest = orchestrationDigest(root);
    const result = actionCapabilities(root, { mcpTools: ["capabilities", "layer_open"] });
    assert.equal(result.orchestration.version, "0.3.0");
    assert.equal(result.native.privateLayer, "unverified");
    assert.equal(result.native.runningProcessVerified, false);
    assert.equal(result.acceptance.privateLayer.runningProcessVerified, false);
    assert.equal(result.acceptance.privateLayer.currentBinding.orchestrationSourceDigest, digest);
    assert.equal(result.acceptance.privateLayer.path.endsWith("/Action/agent-layer/isolation-acceptance.json"), true);
    assert.equal(result.runtimeParity.state, "unverified");
    assert.equal(result.transports.mcp.verification, "this-server-tools-list");
    assert.equal(result.transports.rawActionWebSocket.privateLayerOrchestration, false);
    writeFileSync(join(root, "packages", "entry.ts"), "export const version = 2;");
    assert.notEqual(orchestrationDigest(root), digest);
    const resources = join(root, "native/dist/Action.app/Contents/Resources");
    mkdirSync(resources, { recursive: true });
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify({ features: { privateLayer: true } }));
    assert.equal(actionCapabilities(root).native.privateLayer, "declared-by-build");
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify({ features: { privateLayer: true }, build: { orchestrationSourceDigest: orchestrationDigest(root) } }));
    assert.equal(actionCapabilities(root).runtimeParity.state, "matched-source-digest");
    writeFileSync(join(root, "packages", "entry.ts"), "export const version = 3;");
    assert.equal(actionCapabilities(root).runtimeParity.state, "source-digest-mismatch");
    assert.equal(actionCapabilities(root, { nativeHostPath: "/different/host" }).runtimeParity.state, "unverified");
    assert.equal(actionCapabilities(root, { nativeHostPath: "/different/host" }).native.privateLayer, "unverified-override");
    const executableDirectory = join(root, "native/dist/Action.app/Contents/MacOS");
    mkdirSync(executableDirectory, { recursive: true });
    const executable = join(executableDirectory, "Action");
    const displayConfiguration = [{ id: 1, bounds: { x: 0, y: 0, width: 1512, height: 982 }, mode: { width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 60 } }];
    const hostFingerprint = "b".repeat(64);
    const nativeSourceDigest = "c".repeat(64);
    writeFileSync(executable, `#!/bin/sh\n[ "$1" = "isolation-context" ] || exit 1\nprintf '%s' '${JSON.stringify({ schemaVersion: 1, hostFingerprint, osBuild: "25A123", displayConfiguration })}'\n`);
    chmodSync(executable, 0o755);
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify({ features: { privateLayer: true, isolationContext: true }, build: { sourceDigest: nativeSourceDigest, orchestrationSourceDigest: orchestrationDigest(root) } }));
    const contextResult = actionCapabilities(root);
    assert.equal(contextResult.acceptance.privateLayer.context.state, "available");
    assert.equal(contextResult.acceptance.privateLayer.currentBinding.hostFingerprint, hostFingerprint);
    assert.equal(contextResult.acceptance.privateLayer.currentBinding.nativeSourceDigest, nativeSourceDigest);
    assert.equal(contextResult.acceptance.privateLayer.currentBinding.displayConfigurationDigest, displayConfigurationDigest(displayConfiguration));
    const overridden = actionCapabilities(root, { nativeHostPath: "/different/host" });
    assert.equal(overridden.acceptance.privateLayer.context.state, "unavailable");
    assert.equal(overridden.acceptance.privateLayer.currentBinding.hostFingerprint, undefined);
    writeFileSync(executable, "#!/bin/sh\nexit 1\n");
    assert.equal(actionCapabilities(root).acceptance.privateLayer.context.state, "unavailable");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("acceptance refresh observes topology, artifact and bundle changes while retaining loaded orchestration identity", () => {
  const root = mkdtempSync(join(tmpdir(), "action-acceptance-refresh-"));
  try {
    writeFileSync(join(root, "package.json"), '{"version":"0.3.0"}');
    mkdirSync(join(root, "packages"));
    const source = join(root, "packages/entry.ts");
    writeFileSync(source, "export const revision = 1;");
    const resources = join(root, "native/dist/Action.app/Contents/Resources");
    const binaries = join(root, "native/dist/Action.app/Contents/MacOS");
    mkdirSync(resources, { recursive: true });
    mkdirSync(binaries, { recursive: true });
    const nativeManifest = { features: { isolationContext: true }, build: { sourceDigest: "d".repeat(64), orchestrationSourceDigest: orchestrationDigest(root) } };
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify(nativeManifest));
    const contextPath = join(root, "context.json");
    const context = { schemaVersion: 1, hostFingerprint: "e".repeat(64), osBuild: "25A123", displayConfiguration: [{ id: 1, x: 0 }] };
    writeFileSync(contextPath, JSON.stringify(context));
    const executable = join(binaries, "Action");
    const script = `#!/bin/sh\n[ "$1" = "isolation-context" ] || exit 1\ncat '${contextPath}'\n`;
    writeFileSync(executable, script);
    chmodSync(executable, 0o755);
    const startup = actionCapabilities(root);
    const path = join(root, "acceptance.json");
    const evidence = join(root, "observations.json");
    writeFileSync(evidence, "fixture evidence");
    const now = Date.parse("2026-10-11T12:00:00Z");
    const record = {
      schemaVersion: 1, outcome: "passed", acceptedAt: "2026-10-11T11:00:00Z", expiresAt: "2026-10-12T11:00:00Z", reviewer: "test operator",
      binding: startup.acceptance.privateLayer.currentBinding, phases: ["open", "interaction", "close"],
      checks: { physicalDisplayMode: "unchanged-throughout", scale: "unchanged-throughout", arrangement: "unchanged-throughout", frontmostApp: "unchanged-throughout", pointer: "unchanged-throughout", unrelatedWindowFrames: "unchanged-throughout" },
      evidence: [{ path: evidence, sha256: createHash("sha256").update("fixture evidence").digest("hex") }],
    };
    const refresh = () => refreshActionCapabilities(startup, { path, now }).acceptance.privateLayer;
    writeFileSync(path, JSON.stringify(record));
    assert.equal(refresh().state, "accepted");
    writeFileSync(contextPath, JSON.stringify({ ...context, displayConfiguration: [{ id: 1, x: 1512 }] }));
    assert.equal(refresh().state, "stale");
    writeFileSync(contextPath, JSON.stringify(context));
    assert.equal(refresh().state, "accepted");
    writeFileSync(source, "export const revision = 2;");
    assert.equal(refresh().state, "accepted");
    assert.equal(refresh().currentBinding.orchestrationSourceDigest, startup.orchestration.sourceDigest);
    assert.notEqual(orchestrationDigest(root), startup.orchestration.sourceDigest);
    writeFileSync(executable, `${script}\n`);
    assert.equal(refresh().state, "stale");
    assert.notEqual(refreshActionCapabilities(startup).native.executableSha256, startup.native.executableSha256);
    writeFileSync(executable, script);
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify({ ...nativeManifest, build: { ...nativeManifest.build, sourceDigest: "f".repeat(64) } }));
    assert.equal(refresh().state, "stale");
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify(nativeManifest));
    assert.equal(refresh().state, "accepted");
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify({ ...nativeManifest, build: { ...nativeManifest.build, orchestrationSourceDigest: "f".repeat(64) } }));
    const refreshed = refreshActionCapabilities(startup);
    assert.equal(refreshed.runtimeParity.state, "source-digest-mismatch");
    assert.equal(startup.runtimeParity.state, "matched-source-digest");
    assert.equal(refreshed.orchestration.sourceDigest, startup.orchestration.sourceDigest);
    writeFileSync(join(resources, "build-provenance.json"), JSON.stringify(nativeManifest));
    writeFileSync(evidence, "changed artifact");
    assert.equal(refresh().state, "invalid");
    writeFileSync(evidence, "fixture evidence");
    assert.equal(refreshActionCapabilities(startup, { path, now: Date.parse(record.expiresAt) }).acceptance.privateLayer.state, "stale");
    writeFileSync(path, "{}");
    assert.equal(refresh().state, "invalid");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
