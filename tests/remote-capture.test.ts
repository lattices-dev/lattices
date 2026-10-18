import { test, expect } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseCaptureDisplayArgs, remoteCapturePath } from "../bin/cli/capture.ts";

const now = new Date("2026-10-10T23:55:37.180Z");

test("a remote capture lands under the host's folder on this Mac", () => {
  expect(remoteCapturePath("archie", "display-0", "png", { now })).toBe(
    join(homedir(), ".lattices/captures/archie/archie-display-0-2026-10-10T23-55-37-180.png"),
  );
  expect(remoteCapturePath("archie", "window-7", "jpeg", { now })).toEndWith("archie-window-7-2026-10-10T23-55-37-180.jpg");
});

test("--filename names the file in that folder, --out puts it anywhere", () => {
  expect(remoteCapturePath("archie", "display-0", "png", { filename: "../desk" })).toBe(
    join(homedir(), ".lattices/captures/archie/desk.png"),
  );
  expect(remoteCapturePath("archie", "display-0", "png", { out: "shots/a.png" })).toBe(resolve("shots/a.png"));
});

test("capture display takes --out", () => {
  expect(parseCaptureDisplayArgs(["1", "--out", "/tmp/a.png"])).toMatchObject({ display: 1, out: "/tmp/a.png" });
});

test("remote window output options preserve the requested target in every argument order", () => {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "lattices-remote-capture-")));
  const cases = [
    { args: ["--out", "before.png", "42"], output: "before.png", wid: 42 },
    { args: ["42", "--out", "after.png"], output: "after.png", wid: 42 },
    { args: ["--out=equals.png", "42"], output: "equals.png", wid: 42 },
    { args: ["--out", "123"], output: "123", wid: undefined },
    { args: ["--out", "app.png", "--app", "Terminal", "42"], output: "app.png", wid: 42, app: "Terminal" },
  ];
  // Isolate the module mock in a child so other tests retain the real daemon.
  // All output paths resolve under this temporary cwd; no live daemon is used.
  const script = `
    import { mock } from "bun:test";
    const requests = [];
    const receipts = [];
    console.log = (message) => receipts.push(JSON.parse(message));
    mock.module(${JSON.stringify(new URL("../bin/cli/daemon.ts", import.meta.url).pathname)}, () => ({
      remoteHostName: () => "archie",
      withDaemon: async (callback) => callback({ daemonCall: async (method, params) => {
        requests.push({ method, params });
        return { path: "/remote/capture.png", data: "c2NyZWVuc2hvdA==", format: "png", wid: params.wid };
      } }),
    }));
    const { captureCommand } = await import(${JSON.stringify(new URL("../bin/cli/capture.ts", import.meta.url).href)});
    for (const entry of ${JSON.stringify(cases)}) await captureCommand("window", ...entry.args, "--json");
    process.stdout.write(JSON.stringify({ requests, receipts }));
  `;
  try {
    const { requests, receipts } = JSON.parse(execFileSync(process.execPath, ["-e", script], {
      cwd: directory, encoding: "utf8",
    }));
    expect(requests).toHaveLength(cases.length);
    expect(receipts).toHaveLength(cases.length);
    for (const [index, entry] of cases.entries()) {
      expect(requests[index]).toEqual({
        method: "capture.screenshotWindow",
        params: { source: "cli", inline: true, ...(entry.wid === undefined ? {} : { wid: entry.wid }), ...(entry.app ? { app: entry.app } : {}) },
      });
      expect(receipts[index]).toMatchObject({ host: "archie", path: join(directory, entry.output), remotePath: "/remote/capture.png" });
      expect(receipts[index]).not.toHaveProperty("data");
      expect(readFileSync(join(directory, entry.output), "utf8")).toBe("screenshot");
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
