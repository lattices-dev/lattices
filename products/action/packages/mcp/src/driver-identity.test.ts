import assert from "node:assert/strict";
import { homedir } from "node:os";
import { describe, test } from "node:test";

import { clientLabel, DriverIdentityContext, inferDriverIdentity, inferProject } from "./driver-identity.js";

describe("driver identity", () => {
  test("prefers an explicit deployment label", () => {
    assert.equal(
      inferDriverIdentity({
        ACTION_DRIVER_LABEL: "Talkie Codex",
        OPENSCOUT_AGENT: "session-x",
      }).agent,
      "Talkie Codex",
    );
  });

  test("uses the stable Scout sender id when available", () => {
    assert.equal(
      inferDriverIdentity({
        OPENSCOUT_AGENT: "talkie.codex-recovery-talkie-stack-20260811.arachs-mac-mini-5-local",
      }).agent,
      "talkie.codex-recovery-talkie-stack-20260811.arachs-mac-mini-5-local",
    );
  });

  test("recognises Claude Code from its environment", () => {
    assert.equal(inferDriverIdentity({ CLAUDECODE: "1" }).agent, "Claude Code");
  });

  test("labels fallback honestly", () => {
    assert.deepEqual(inferDriverIdentity({}), {
      agent: "Unidentified MCP caller",
      source: "fallback",
    });
  });

  test("handshake overrides inference for subsequent implicit leases", () => {
    const context = new DriverIdentityContext({ OPENSCOUT_AGENT: "session-x" }, null);
    assert.deepEqual(context.identify("Codex · checkout audit", "stage website"), {
      agent: "Codex · checkout audit",
      task: "stage website",
      source: "handshake",
    });
    assert.deepEqual(context.get(), {
      agent: "Codex · checkout audit",
      task: "stage website",
      source: "handshake",
    });
  });

  test("the MCP client name replaces environment guesses but not a stated identity", () => {
    const guessed = new DriverIdentityContext({ CODEX_THREAD_ID: "0199abcdef" }, "talkie");
    assert.deepEqual(guessed.adoptClient({ name: "codex-mcp-client" }), {
      agent: "Codex",
      project: "talkie",
      source: "client",
    });

    const labelled = new DriverIdentityContext({ ACTION_DRIVER_LABEL: "Talkie Codex" }, null);
    assert.equal(labelled.adoptClient({ name: "claude-code" }).agent, "Talkie Codex");

    const stated = new DriverIdentityContext({}, null);
    stated.identify("Claude (talkie.to evidence)");
    assert.equal(stated.adoptClient({ name: "claude-code" }).agent, "Claude (talkie.to evidence)");
  });

  test("client labels prefer the title, then known names, then the raw name", () => {
    assert.equal(clientLabel({ name: "claude-code", title: "Claude Code" }), "Claude Code");
    assert.equal(clientLabel({ name: "claude-code" }), "Claude Code");
    assert.equal(clientLabel({ name: "cursor-vscode" }), "cursor-vscode");
    assert.equal(clientLabel(undefined), undefined);
  });

  test("project comes from the harness folder, never the home folder", () => {
    assert.equal(inferProject({}, () => "/Users/someone/dev/fab"), "fab");
    assert.equal(inferProject({}, () => homedir()), undefined);
    assert.equal(inferProject({}, () => undefined), undefined);
    assert.equal(inferProject({ ACTION_DRIVER_PROJECT: "scout" }, () => "/x/fab"), "scout");
  });
});
