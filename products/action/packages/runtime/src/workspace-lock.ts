import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";

export async function withWorkspaceLock<Result>(path: string, operation: () => Promise<Result>): Promise<Result> {
  await mkdir(dirname(path), { recursive: true });
  const holder = spawn("/usr/bin/lockf", ["-k", "-t", "0", path, "/bin/sh", "-c", "printf 'ready\\n'; exec /bin/cat >/dev/null"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  let detail = "";
  let settled = false;
  let ready = false;
  let failed: Error | undefined;
  let resolveReady!: () => void;
  let rejectReady!: (error: Error) => void;
  const readiness = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const exited = new Promise<void>((resolve) => {
    holder.once("close", () => {
      settled = true;
      failed = new Error(`Workspace transaction lock exited${detail ? `: ${detail.trim()}` : ""}`);
      if (!ready) rejectReady(failed);
      resolve();
    });
  });
  holder.once("error", (error) => { failed = error; rejectReady(error); });
  holder.stdin.on("error", (error) => { failed = error; });
  holder.stderr.on("data", (chunk) => { detail = (detail + chunk).slice(-4096); });
  holder.stdout.on("data", (chunk) => {
    output += chunk;
    if (output.includes("ready\n")) { ready = true; resolveReady(); }
  });
  const timeout = setTimeout(() => rejectReady(new Error("Workspace transaction lock timed out")), 3000);
  try {
    await readiness;
    clearTimeout(timeout);
    if (failed || settled) throw failed ?? new Error("Workspace transaction lock was lost");
    const result = await operation();
    if (failed || settled) throw failed ?? new Error("Workspace transaction lock was lost");
    return result;
  } finally {
    clearTimeout(timeout);
    holder.stdin.end();
    await exited;
  }
}
