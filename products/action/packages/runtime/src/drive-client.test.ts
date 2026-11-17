import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  inferAxTier,
  isActionAgentCommand,
  isDriveLeaseInactiveError,
  parseElapsed,
  readAgentOwner,
} from "./drive-client.js";

describe("drive client", () => {
  test("recognizes the native terminal-lease response", () => {
    assert.equal(
      isDriveLeaseInactiveError(new Error("Drive lease drive_123 is not active")),
      true,
    );
  });

  test("does not hide transport or ownership failures", () => {
    assert.equal(isDriveLeaseInactiveError(new Error("Action agent connection closed")), false);
    assert.equal(
      isDriveLeaseInactiveError(new Error("Drive lease drive_123 belongs to another connection")),
      false,
    );
  });

  test("infers blink for acts routed onto the agent layer", () => {
    assert.equal(inferAxTier({ actionKind: "click", channel: "hid", targetMode: "coordinate" }), "attention");
    assert.equal(inferAxTier({ actionKind: "click", channel: "blink", targetMode: "coordinate", blink: true }), "blink");
    assert.equal(inferAxTier({ actionKind: "type", blink: true }), "blink");
    assert.equal(inferAxTier({ actionKind: "press-key", blink: true }), "blink");
    // A drag or scroll held on the layer blinks; anywhere else a drag needs attention.
    assert.equal(inferAxTier({ actionKind: "drag", blink: true }), "blink");
    assert.equal(inferAxTier({ actionKind: "scroll", blink: true }), "blink");
    assert.equal(inferAxTier({ actionKind: "drag" }), "attention");
  });

  test("parses ps elapsed times", () => {
    assert.equal(parseElapsed("00:07"), 7);
    assert.equal(parseElapsed("12:34"), 754);
    assert.equal(parseElapsed("23:07:59"), 83_279);
    assert.equal(parseElapsed("03-01:30:44"), 264_644);
    assert.equal(parseElapsed("bogus"), undefined);
  });

  test("only treats the Action agent command as a socket owner", () => {
    assert.equal(isActionAgentCommand("/x/dist/Action.app/Contents/MacOS/Action agent --port 4319 --idle-exit-seconds 5"), true);
    assert.equal(isActionAgentCommand("/x/dist/Action.app/Contents/MacOS/Action"), false);
    assert.equal(isActionAgentCommand("/Users/me/.bun/bin/bun packages/mcp/src/index.ts agent"), false);
  });

  test("ignores lock files that name no live agent", () => {
    const dir = mkdtempSync(join(tmpdir(), "action-lock-"));
    const lock = join(dir, "action.sock.lock");
    assert.equal(readAgentOwner(lock), undefined);
    writeFileSync(lock, "");
    assert.equal(readAgentOwner(lock), undefined);
    writeFileSync(lock, `${process.pid}\n`);
    assert.equal(readAgentOwner(lock), undefined);
  });
});
