import { expect, test } from "bun:test";
import { parseSpaceArgs, focusSpace, type Rpc } from "../bin/cli/spaces.ts";
import { diagnoseHost } from "../bin/cli/doctor.ts";

test("space CLI rejects malformed navigation and preserves dry-run receipts", async () => {
  for (const args of [["zero"], ["0"], ["-1"], ["2.5"], ["constructor"], ["__proto__"], ["toString"], ["2", "--wat"], ["next", "extra"]]) {
    expect(() => parseSpaceArgs(args)).toThrow();
  }
  const parsed = parseSpaceArgs(["prev", "--dry-run", "--json"]);
  expect(parsed).toEqual({ workspace: "e-1", dryRun: true, json: true });
  const calls: unknown[] = [];
  const rpc: Rpc = async (method, params) => { calls.push([method, params]); return { ok: true, status: "planned", target: "e-1", currentSpaceId: 4 }; };
  await focusSpace(rpc, parsed);
  expect(calls).toEqual([["spaces.focus", { workspace: "e-1", dryRun: true }]]);
});

test("doctor is read-only and fails when the desktop cannot place windows", async () => {
  const calls: string[] = [];
  const report = await diagnoseHost(async method => {
    calls.push(method);
    if (method === "daemon.status") return { platform: "linux", version: "0.1.0" };
    return { platform: "linux", capabilities: ["windows.read", "spaces.read", "sessions.tmux"], capabilityHealth: { "windows.place": { available: false, reason: "Desktop unavailable" } }, eventStream: { state: "connected" } };
  });
  expect(report.ok).toBe(false);
  expect(report.checks.find(check => check.name === "Window placement")).toMatchObject({ state: "fail", detail: "Desktop unavailable" });
  expect(calls).toEqual(["daemon.status", "host.describe"]);
});

test("doctor returns structured failure when no host is reachable", async () => {
  const report = await diagnoseHost(async () => { throw new Error("ECONNREFUSED"); });
  expect(report.ok).toBe(false);
  expect(report.checks).toEqual([{ name: "Host connection", state: "fail", detail: "ECONNREFUSED" }]);
});

test("doctor distinguishes older hosts from authorization failures", async () => {
  for (const [message, ok, state] of [["Unknown method: host.describe", true, "unknown"], ["unauthorized", false, "fail"]] as const) {
    const report = await diagnoseHost(async method => { if (method === "daemon.status") return { version: "0.1.0" }; throw new Error(message); });
    expect(report.ok).toBe(ok);
    expect(report.checks.at(-1)?.state).toBe(state);
  }
});
