import assert from "node:assert/strict";
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { daemonCall } from "../bin/daemon-client.ts";

// Launch the app with --screen-map before opting in. The daemon must inspect
// its own SwiftUI tree on main, even though the RPC arrives on a socket queue.
test("computer.windowState can repeatedly inspect the app's own Overview", {
  skip: process.env.LATTICES_CUA_SELF_SMOKE !== "1",
  timeout: 60_000,
}, async () => {
  const counts = [];
  let snapshot;
  for (let i = 0; i < 8; i++) {
    snapshot = await daemonCall("computer.windowState", {
      app: "Lattices", title: "Lattices", mode: i % 2 ? "both" : "ax",
      maxDepth: 5, maxElements: 180, source: "release-self-ax-regression",
    });
    assert.equal(snapshot.ok, true);
    assert.ok(snapshot.elementCount > 10, "Overview must expose its controls");
    counts.push(snapshot.elementCount);
    const status = await daemonCall("daemon.status");
    assert.ok(status.uptime > 0, "Daemon must remain responsive after self-inspection");
  }
  const output = process.env.LATTICES_CUA_SMOKE_OUTPUT;
  if (output) {
    mkdirSync(output, { recursive: true });
    writeFileSync(path.join(output, "computer-self-regression.json"), JSON.stringify({ counts }, null, 2));
    writeFileSync(path.join(output, "candidate-overview.json"), JSON.stringify(snapshot, null, 2));
    copyFileSync(snapshot.artifact.path, path.join(output, "candidate-overview.png"));
  }
});
