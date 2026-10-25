// WayVNC stays on loopback. Users explicitly choose their VNC client and
// transport (for example SSH); capture.live is not exposed by the gateway.
import { execFile, spawn, type ChildProcess } from "node:child_process";
import { connect } from "node:net";
import { promisify } from "node:util";

type Target = { host: string; port: number; output?: string };
type Probe = "vnc" | "occupied" | "closed";
type LiveDeps = {
  prepare?: (target: Target) => Promise<string[]>;
  spawn: (args: string[]) => ChildProcess;
  probe: (host: string, port: number) => Promise<Probe>;
  delay: () => Promise<void>;
  attempts: number;
};

export function probeVNC(host: string, port: number, timeoutMs = 300): Promise<Probe> {
  return new Promise((resolve) => {
    const socket = connect({ host, port });
    let connected = false;
    let banner = Buffer.alloc(0);
    const timer = setTimeout(() => done(connected ? "occupied" : "closed"), timeoutMs);
    const done = (result: Probe) => { clearTimeout(timer); socket.destroy(); resolve(result); };
    socket.once("connect", () => { connected = true; });
    socket.on("data", (data) => {
      const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data);
      banner = Buffer.concat([banner, bytes.subarray(0, 12 - banner.length)]);
      if (banner.length === 12) done(/^RFB \d{3}\.\d{3}\n$/.test(banner.toString("ascii")) ? "vnc" : "occupied");
    });
    socket.once("end", () => done("occupied"));
    socket.once("error", () => done(connected ? "occupied" : "closed"));
  });
}

export function wayvncArguments({ host, port, output }: Target, addressList = true): string[] {
  if (host !== "127.0.0.1" && host !== "::1") throw new Error("VNC must listen on loopback; connect through SSH");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("VNC port must be between 1 and 65535");
  // WayVNC 0.10 accepts address:port, not the old separate port positional.
  return [...(output ? ["-o", output] : []), ...(addressList
    ? [`${host.includes(":") ? `[${host}]` : host}:${port}`] : [host, String(port)])];
}

async function installedArguments(target: Target): Promise<string[]> {
  // Distribution packages still ship the older two-positional syntax. Inspect
  // the installed CLI rather than assuming a release from the host OS.
  const { stdout } = await promisify(execFile)("wayvnc", ["--help"], { timeout: 2000, maxBuffer: 64 * 1024 });
  return wayvncArguments(target, /\[address\.\.\.\]/.test(stdout));
}

export class LiveVNC {
  private child: ChildProcess | null = null;
  private current: Target | null = null;
  private ready = false;
  private generation = 0;
  private pending: { target: Target; result: Promise<ReturnType<LiveVNC["status"]>> } | null = null;

  constructor(private deps: LiveDeps = {
    prepare: installedArguments,
    spawn: (args) => spawn("wayvnc", args, { stdio: ["ignore", "ignore", "pipe"] }),
    probe: probeVNC, delay: () => new Promise((resolve) => setTimeout(resolve, 100)), attempts: 30,
  }) {}

  status() {
    return this.ready && this.current && this.child && this.child.exitCode === null && this.child.signalCode === null
      ? { running: true, ...this.current, url: this.url(this.current) }
      : { running: false };
  }

  start(host: string, port = 5900, output?: string) {
    const target = { host, port, output };
    const args = wayvncArguments(target);
    if (this.pending) {
      if (!this.same(this.pending.target, target)) return Promise.reject(new Error("VNC is starting for another display or port"));
      return this.pending.result;
    }
    if (this.status().running) {
      if (this.current!.host !== host || this.current!.port !== port || (output !== undefined && this.current!.output !== output)) {
        return Promise.reject(new Error("VNC is already running for another display or port. Stop it before changing the target."));
      }
      return Promise.resolve(this.status());
    }
    const result = this.startServer(target, args, this.generation);
    this.pending = { target, result };
    const clear = () => { if (this.pending?.result === result) this.pending = null; };
    result.then(clear, clear);
    return result;
  }

  private async startServer(target: Target, args: string[], generation: number) {
    const checkCancelled = () => { if (generation !== this.generation) throw new Error("VNC startup cancelled"); };
    const existing = await this.deps.probe(target.host, target.port);
    checkCancelled();
    if (existing === "vnc") {
      if (target.output) throw new Error("An external VNC server is already running. Connect without selecting a display, or configure that server's output.");
      return { running: true, ...target, external: true, url: this.url(target) };
    }
    if (existing === "occupied") throw new Error(`Port ${target.port} is occupied but is not answering as VNC`);
    const preparedArgs = this.deps.prepare ? await this.deps.prepare(target) : args;
    checkCancelled();
    const child = this.deps.spawn(preparedArgs);
    this.child = child; this.current = target; this.ready = false;
    let stderr = "";
    let spawnError: Error | undefined;
    child.once("error", (error) => { spawnError = error; });
    const checkSpawnError = () => { if (spawnError) throw new Error(`Could not start WayVNC: ${spawnError.message}`); };
    child.stderr?.on("data", (data) => { stderr = (stderr + String(data)).slice(-4096); });
    const clear = () => {
      if (this.child === child) { this.child = null; this.current = null; this.ready = false; }
    };
    child.once("exit", clear);
    try {
      for (let i = 0; i < this.deps.attempts; i++) {
        checkCancelled();
        checkSpawnError();
        if (child.exitCode !== null || child.signalCode !== null) throw new Error(`WayVNC exited: ${stderr.trim() || child.exitCode || child.signalCode}`);
        const probe = await this.deps.probe(target.host, target.port);
        checkCancelled();
        checkSpawnError();
        if (this.child !== child) throw new Error(`WayVNC exited: ${stderr.trim() || child.exitCode || child.signalCode}`);
        if (probe === "vnc") { this.ready = true; return this.status(); }
        await this.deps.delay();
      }
      throw new Error(`WayVNC did not answer in time${stderr.trim() ? `: ${stderr.trim()}` : ""}`);
    } catch (error) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
      clear();
      throw error;
    }
  }

  stop() {
    const was = this.status();
    this.generation += 1;
    this.child?.kill("SIGTERM");
    this.child = null; this.current = null; this.ready = false;
    return { ok: true, wasRunning: was.running };
  }

  private same(a: Target, b: Target) { return a.host === b.host && a.port === b.port && a.output === b.output; }
  private url(target: Target) { return `vnc://${target.host.includes(":") ? `[${target.host}]` : target.host}:${target.port}`; }
}

const live = new LiveVNC();
export const start = (host: string, port = 5900, output?: string) => live.start(host, port, output);
export const stop = () => live.stop();
export const status = () => live.status();
