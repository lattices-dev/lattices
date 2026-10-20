import { createPublicKey, createHash, randomUUID, type KeyObject } from "node:crypto";
import { join } from "node:path";
import {
  CAPABILITIES, HEADERS, STATE_DIR, canonicalRequest, deriveKeys, fingerprint, loadOrCreateBridgeKey,
  openVisitFrame, publicKeyFromBase64, rawPublicKey, sealVisitFrame, sign, type PairingResponse,
} from "./security.ts";
import type { VisitDown, VisitUp } from "./visit.ts";

export function visitHeaders(signing: Buffer, deviceID: string, nonce = randomUUID()): Record<string, string> {
  const timestamp = new Date().toISOString();
  return { [HEADERS.deviceID]: deviceID, [HEADERS.timestamp]: timestamp, [HEADERS.nonce]: nonce,
    [HEADERS.signature]: sign(signing, canonicalRequest("GET", "/visit", deviceID, timestamp, nonce, Buffer.alloc(0))) };
}

/** Bun accepts upgrade headers here; TypeScript's DOM constructor does not. */
export function openVisitSocket(url: string, headers: Record<string, string>): WebSocket {
  const Client = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
  return new Client(url, { headers });
}

export class VisitTestClient {
  readonly deviceID: string;
  readonly publicKey: string;
  private keys: ReturnType<typeof deriveKeys> | null = null;
  constructor(readonly base: string, private privateKey: KeyObject, readonly name = "visit-test") {
    this.publicKey = rawPublicKey(createPublicKey(privateKey)).toString("base64");
    this.deviceID = `visit-test-${createHash("sha256").update(this.publicKey).digest("hex").slice(0, 20)}`;
  }

  async pair(log: (line: string) => void = console.log) {
    const health = await (await fetch(`${this.base}/health`, { signal: AbortSignal.timeout(5000) })).json() as { bridgePublicKey: string; bridgeFingerprint: string };
    log(`Pair ${this.name} (${this.deviceID}), code ${fingerprint(this.publicKey)}; approve on the host or with bridge.pairing.approve.`);
    const response = await fetch(`${this.base}/pairing/request`, { method: "POST", signal: AbortSignal.timeout(125_000),
      body: JSON.stringify({ deviceID: this.deviceID, deviceName: this.name, devicePublicKey: this.publicKey,
        platform: "Linux", requestedCapabilities: [CAPABILITIES.inputTrackpad] }) });
    const pairing = await response.json() as PairingResponse;
    if (!response.ok || pairing.disposition === "denied") throw new Error(pairing.detail ?? "Pairing denied");
    if (pairing.bridgePublicKey !== health.bridgePublicKey || pairing.bridgeFingerprint !== fingerprint(pairing.bridgePublicKey)) throw new Error("Bridge identity changed during pairing");
    if (!pairing.grantedCapabilities.includes(CAPABILITIES.inputTrackpad)) throw new Error("Pairing did not grant input.trackpad");
    const peer = publicKeyFromBase64(pairing.bridgePublicKey);
    if (!peer) throw new Error("Invalid bridge key");
    this.keys = deriveKeys(this.privateKey, peer);
    return pairing;
  }

  async connect(): Promise<VisitTestConnection> {
    if (!this.keys) throw new Error("Pair first");
    const nonce = randomUUID();
    const ws = openVisitSocket(`${this.base.replace(/^http/, "ws")}/visit`, visitHeaders(this.keys.signing, this.deviceID, nonce));
    const connection = new VisitTestConnection(ws, this.keys.encryption, this.deviceID, nonce);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { ws.close(); reject(new Error("Visit upgrade timed out")); }, 5000);
      ws.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
      ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("Visit upgrade failed")); }, { once: true });
      ws.addEventListener("close", () => { clearTimeout(timer); reject(new Error("Visit closed during upgrade")); }, { once: true });
    });
    return connection;
  }
}

export class VisitTestConnection {
  private upSeq = 0;
  private downSeq = 0;
  private ping: ReturnType<typeof setInterval> | null = null;
  private silence: ReturnType<typeof setTimeout> | null = null;
  private messages: VisitDown[] = [];
  private waiters = new Set<{ type: VisitDown["t"]; resolve(value: VisitDown): void; reject(error: Error): void }>();
  private closed: Error | null = null;
  private pingSent: number[] = [];
  readonly roundTrips: number[] = [];
  constructor(readonly ws: WebSocket, private key: Buffer, private deviceID: string, private nonce: string) {
    ws.binaryType = "arraybuffer";
    ws.addEventListener("open", () => {
      this.arm();
      this.ping = setInterval(() => { if (ws.readyState === WebSocket.OPEN) this.send({ t: "ping" }); }, 2000);
    });
    ws.addEventListener("message", (event) => {
      try {
        if (!(event.data instanceof ArrayBuffer)) throw new Error("Non-binary visit response");
        const message = JSON.parse(openVisitFrame(this.key, Buffer.from(event.data), "down", this.deviceID, this.nonce, this.downSeq++).toString("utf8")) as VisitDown;
        this.arm();
        if (message.t === "pong") {
          const sent = this.pingSent.shift();
          if (sent !== undefined) this.roundTrips.push(performance.now() - sent);
        }
        const waiter = [...this.waiters].find((w) => w.type === message.t || message.t === "error");
        if (waiter) {
          this.waiters.delete(waiter);
          if (message.t === "error") waiter.reject(new Error(message.message)); else waiter.resolve(message);
        } else if (message.t !== "pong") this.messages.push(message);
      } catch (error) { this.fail(error as Error); ws.close(1008, "Invalid visit response"); }
    });
    ws.addEventListener("close", (event) => this.fail(new Error(`Visit closed (${event.code}: ${event.reason})`)));
    ws.addEventListener("error", () => this.fail(new Error("Visit socket failed")));
  }
  private arm() {
    if (this.silence) clearTimeout(this.silence);
    this.silence = setTimeout(() => { this.fail(new Error("Host silent for six seconds")); this.ws.close(); }, 6000);
  }
  private fail(error: Error) {
    this.closed = error;
    if (this.ping) clearInterval(this.ping);
    if (this.silence) clearTimeout(this.silence);
    for (const waiter of this.waiters) waiter.reject(error);
    this.waiters.clear();
  }
  send(message: VisitUp) {
    if (this.ws.readyState !== WebSocket.OPEN) throw this.closed ?? new Error("Visit is not open");
    if (message.t === "ping") this.pingSent.push(performance.now());
    this.ws.send(sealVisitFrame(this.key, Buffer.from(JSON.stringify(message)), "up", this.deviceID, this.nonce, this.upSeq++));
  }
  waitFor(type: VisitDown["t"], timeoutMs = 6000): Promise<VisitDown> {
    const at = this.messages.findIndex((m) => m.t === type || m.t === "error");
    if (at >= 0) {
      const message = this.messages.splice(at, 1)[0];
      return message.t === "error" ? Promise.reject(new Error(message.message)) : Promise.resolve(message);
    }
    if (this.closed) return Promise.reject(this.closed);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiters.delete(waiter); reject(new Error(`No ${type} response`)); }, timeoutMs);
      const waiter = { type, resolve: (v: VisitDown) => { clearTimeout(timer); resolve(v); },
        reject: (e: Error) => { clearTimeout(timer); reject(e); } };
      this.waiters.add(waiter);
    });
  }
  close() { this.fail(new Error("Visit test ended")); this.ws.close(1000, "Test ended"); }
}

export async function runVisitTest(argv: string[]) {
  let host: string | undefined, name = "visit-test", identity = join(STATE_DIR, "visit-test-key.json");
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i], value = argv[++i];
    if (!value) throw new Error(`${arg} needs a value`);
    if (arg === "--host") host = value;
    else if (arg === "--name") name = value;
    else if (arg === "--identity") identity = value;
    else throw new Error(`Unknown visit-test argument: ${arg}`);
  }
  if (!host) throw new Error("Usage: lattices-host visit-test --host TAILNET_HOST:9399 [--name NAME] [--identity PATH]");
  if (!host.includes(":")) host += ":9399";
  const client = new VisitTestClient(`http://${host}`, loadOrCreateBridgeKey(identity), name);
  await client.pair();
  const visit = await client.connect();
  const stop = () => visit.close();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    visit.send({ t: "enter", name, edge: "left", at: 0.5 });
    console.log(JSON.stringify(await visit.waitFor("ready")));
    for (const [dx, dy] of [[5, 0], [0, 5], [-5, 0], [0, -5]]) {
      for (let i = 0; i < 40; i++) {
        visit.send({ t: "move", dx, dy });
        await Bun.sleep(25);
      }
    }
    visit.send({ t: "leave" });
    const timings = visit.roundTrips;
    if (timings.length) console.log(`Encrypted ping RTT: ${Math.min(...timings).toFixed(2)}–${Math.max(...timings).toFixed(2)} ms (${timings.length} samples)`);
  } finally {
    visit.close();
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}
