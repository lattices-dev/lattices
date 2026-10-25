import source from "./keyboard.c" with { type: "text" };
import { createHash } from "node:crypto";
import { mkdir, chmod, rename, access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { run } from "./exec.ts";
import { waylandGlobals } from "./wayland.ts";

let prepared: Promise<string> | undefined;
/** The single-file host carries its helper source; no root or input-device access. */
export function prepareKeyboard(): Promise<string> {
  return prepared ??= (async () => {
    const directory = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "lattices", "input");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const digest = createHash("sha256").update(source).digest("hex").slice(0, 16);
    const binary = join(directory, `keyboard-${digest}`);
    try { await access(binary); return binary; } catch { /* Compile once per source revision. */ }
    const temporary = `${binary}.${process.pid}`;
    const flags = (await run("pkg-config", ["--cflags", "--libs", "wayland-client", "xkbcommon"])).trim().split(/\s+/);
    await run("cc", ["-x", "c", "-", "-O2", "-Wall", "-Wextra", "-o", temporary, ...flags], { input: Buffer.from(source) });
    await chmod(temporary, 0o700);
    await rename(temporary, binary);
    return binary;
  })();
}

let availability: Promise<boolean> | undefined;
export function physicalKeyboardAvailable(): Promise<boolean> {
  return availability ??= (async () => {
    try {
      if (!(await waylandGlobals()).includes("zwp_virtual_keyboard_manager_v1")) return false;
      await prepareKeyboard();
      return true;
    } catch { return false; }
  })();
}

export class PhysicalKeyboard {
  private pending?: { resolve: () => void; reject: (error: Error) => void };
  private failure?: Error;
  private stderr = "";
  private constructor(private process: ChildProcessWithoutNullStreams) {
    createInterface({ input: process.stdout }).on("line", line => {
      if (line === "ready" || line === "ok") { this.pending?.resolve(); this.pending = undefined; }
    });
    process.stderr.on("data", bytes => { this.stderr = (this.stderr + bytes).slice(-1024); });
    process.on("error", error => this.fail(error));
    process.stdin.on("error", error => this.fail(error));
    process.on("exit", () => this.fail(new Error(this.stderr.trim() || "Keyboard input disconnected")));
  }
  private fail(error: Error) { this.failure = error; this.pending?.reject(error); this.pending = undefined; }
  static async open() {
    const keyboard = new PhysicalKeyboard(spawn(await prepareKeyboard(), [], { stdio: "pipe" }));
    try { await keyboard.ack(); return keyboard; }
    catch (error) { keyboard.process.stdin.end(); throw error; }
  }
  private ack(command?: string): Promise<void> {
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.process.stdin.end(); reject(new Error("Keyboard input timed out")); }, 2000);
      this.pending = { resolve: () => { clearTimeout(timer); resolve(); }, reject: error => { clearTimeout(timer); reject(error); } };
      if (command) this.process.stdin.write(command + "\n");
    });
  }
  key(code: number, down: boolean) { return this.ack(`key ${code} ${down ? 1 : 0}`); }
  ping() { return this.ack("ping"); }
  async close() {
    try { await this.ack("reset"); } catch { /* EOF also releases every key. */ }
    finally { this.process.stdin.end(); }
  }
}
