import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { withWorkspaceLock } from "./workspace-lock.js";

test("workspace locks exclude concurrent processes, release on failure, and preserve independent workspaces", async () => {
  const root = await mkdtemp(join(tmpdir(), "action-lock-"));
  const path = join(root, "transaction.lock");
  let entered = false;
  try {
    await assert.rejects(withWorkspaceLock(path, async () => {
      await assert.rejects(withWorkspaceLock(path, async () => { entered = true; }), /lock exited/);
      assert.equal(entered, false);
      assert.equal(await withWorkspaceLock(join(root, "other.lock"), async () => "independent"), "independent");
      throw new Error("test operation failed");
    }), /test operation failed/);
    assert.equal(await withWorkspaceLock(path, async () => "recovered"), "recovered");
  } finally { await rm(root, { recursive: true, force: true }); }
});
