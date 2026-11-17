import assert from "node:assert/strict";
import { test } from "node:test";
import { selectTarget } from "./cli.js";
import { BackendRefusal, type BackendTarget } from "./types.js";

const identity = (window: string, process: string) =>
  `agent-desktop:${Buffer.from(JSON.stringify([window, 42, process])).toString("base64url")}`;

test("agent-desktop CLI target IDs retain exact window and process identity across invocations", () => {
  const first = identity("101", "process-start-1");
  const second = identity("102", "process-start-1");
  const targets: BackendTarget[] = [
    { targetId: `0123abcd:${first}`, app: "Example", title: "First" },
    { targetId: `0123abcd:${second}`, app: "Example", title: "Second" },
  ];
  for (const selector of [second, `0123abcd:${second}`, `deadbeef:${second}`]) {
    assert.equal(selectTarget(targets, selector), targets[1]);
  }
});

test("an expired agent-desktop identity cannot select a reused window or a matching title", () => {
  const expired = identity("101", "process-start-1");
  const targets: BackendTarget[] = [{
    targetId: `0123abcd:${identity("101", "process-start-2")}`,
    app: "Example", title: expired,
  }];
  for (const selector of [expired, `deadbeef:${expired}`]) {
    assert.throws(() => selectTarget(targets, selector, { first: true }), (error: unknown) =>
      error instanceof BackendRefusal && error.code === "unknown-target");
  }
});
