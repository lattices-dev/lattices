import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { daemonCallTo } from "../../packages/desktop-client/daemon-client.ts";
import { changeUnit, withUserBus } from "../../packages/host-linux/src/service-client.ts";
import type { Display, Window } from "../../packages/desktop-client/contracts.ts";
import { loadLinuxHintPack } from "../../packages/desktop-client/hints.ts";
import { diagnoseHost } from "../../packages/desktop-client/doctor.ts";
import { watchAppearance } from "./appearance.ts";

const port = Number(process.env.LATTICES_LINUX_PORT ?? 9399);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid local host port");
const endpoint = { host: "127.0.0.1", port };
process.env.LATTICES_CLIENT = "linux-app";
// daemonCallTo propagates this budget to the worker; timeout cancellation is
// acknowledged before reporting safe failure, otherwise outcome is uncertain.
const call = <T>(method: string, params?: Record<string, unknown>, timeout?: number) => daemonCallTo(endpoint, method, params, timeout ?? (method.startsWith("computer.virtual.") ? 20000 : 5000)) as Promise<T>;
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const emitHints = () => emit({ type: "hints", pack: loadLinuxHintPack() });
interface Describe {
  hostname: string; capabilities: string[]; methods: string[]; displays: Display[];
  build?: { version: string; commit: string | null; dirty: boolean | null };
  eventStream?: { state: string }; capabilityHealth?: Record<string, { available: boolean; reason: string | null }>;
}
interface Client { id: string; name: string; scope?: string; capabilities?: string[]; node?: string }
interface Pending { deviceID: string; deviceName: string; fingerprint: string; capabilities: string[] }
let events: WebSocket | undefined;
let refreshing = false;
let refreshAgain = false;
let debounce: ReturnType<typeof setTimeout> | undefined;

function watchEvents() {
  if (events && events.readyState < WebSocket.CLOSING) return;
  const socket = new WebSocket(`ws://${endpoint.host}:${port}`);
  events = socket;
  socket.onopen = () => socket.send(JSON.stringify({ id: "linux-app-events", method: "events.subscribe", params: { events: ["windows.changed", "spaces.changed", "host.healthChanged", "layers.changed", "virtual.changed"] } }));
  socket.onmessage = (event) => {
    try {
      if (!JSON.parse(String(event.data)).event || debounce) return;
      debounce = setTimeout(() => { debounce = undefined; void refresh(); }, 180);
    } catch { /* Ignore non-event frames. */ }
  };
  socket.onerror = () => {};
  socket.onclose = () => {
    if (events !== socket) return;
    events = undefined;
    emit({ type: "offline", message: "The local host disconnected. Refresh to reconnect." });
  };
}

async function refresh() {
  if (refreshing) { refreshAgain = true; return; }
  refreshing = true;
  try {
    const describe = await call<Describe>("host.describe");
    const methods = new Set(describe.methods);
    const [desktop, daemon, companion, layers, virtual] = await Promise.all([
      methods.has("desktop.snapshot") ? call<{ windows: Window[]; displays: Display[]; sessions: unknown[] }>("desktop.snapshot")
        : Promise.resolve({ windows: [], displays: describe.displays, sessions: methods.has("tmux.list") ? await call<unknown[]>("tmux.list") : [] }),
      methods.has("clients.list") ? call<{ clients: Client[]; pending: Pending[] }>("clients.list") : Promise.resolve({ clients: [], pending: [] }),
      methods.has("bridge.status") ? call<{ devices: Client[]; pending: Pending[] }>("bridge.status") : Promise.resolve({ devices: [], pending: [] }),
      methods.has("layers.members") ? call<{ layers: unknown[]; active: number; stage: unknown }>("layers.members").catch(error => ({ layers: [], active: -1, stage: { parked: [], hidden: [] }, layersError: (error as Error).message })) : Promise.resolve({ layers: [], active: -1, stage: { parked: [], hidden: [] } }),
      methods.has("computer.virtual.status") ? call("computer.virtual.status").catch(error => ({ available: false, running: false, reason: (error as Error).message })) : Promise.resolve({ available: false, running: false }),
    ]);
    desktop.windows = desktop.windows.filter(window => window.pid !== process.ppid);
    emit({ type: "state", online: true, describe, ...desktop, ...layers, virtual, layersSupported: methods.has("layers.members"), pairingSupported: methods.has("clients.list"),
      clients: [...daemon.clients.map((client) => ({ ...client, kind: "daemon" })), ...companion.devices.map((client) => ({ ...client, kind: "companion", scope: client.capabilities?.join(", ") }))],
      pending: [...daemon.pending.map((request) => ({ ...request, kind: "daemon" })), ...companion.pending.map((request) => ({ ...request, kind: "companion" }))],
    });
    watchEvents();
  } catch (error) { emit({ type: "offline", message: (error as Error).message }); }
  finally {
    refreshing = false;
    if (refreshAgain) { refreshAgain = false; void refresh(); }
  }
}

let previewPending = false;
const allowed = new Set(["computer.virtual.start", "computer.virtual.stop", "computer.virtual.launch", "computer.click", "computer.scroll", "computer.pressKey", "computer.typeText", "layers.create", "layers.assign", "layers.unassign", "layers.rename", "layers.delete", "layers.layout", "layers.activate", "layers.reveal", "windows.focus", "windows.place", "sessions.launch", "clients.approve", "clients.deny", "clients.revoke", "bridge.pairing.approve", "bridge.pairing.deny", "bridge.devices.revoke"]);
const input = createInterface({ input: process.stdin });
allowed.add("spaces.focus");
allowed.add("windows.resolve");
for (const method of ["windows.list", "windows.search", "spaces.list", "tmux.list", "layers.list"]) allowed.add(method);
let queue = Promise.resolve();
input.on("line", (line) => {
  let request: { method: string; params?: Record<string, unknown>; requestId?: string };
  try { request = JSON.parse(line); }
  catch { emit({ type: "error", message: "Invalid app request" }); return; }
  if (request.method === "virtual.preview") {
    if (previewPending) return;
    previewPending = true;
  }
  queue = queue.then(async () => {
    try {
      if (request.method === "virtual.preview") {
        try { const frame = await call<Record<string, unknown>>("computer.virtual.capture"); emit({ type: "virtual.frame", ...frame }); }
        catch (error) { emit({ type: "virtual.error", message: (error as Error).message }); }
        finally { previewPending = false; }
        return;
      }
      if (request.method === "refresh") { emitHints(); appearance.poll(true); await refresh(); return; }
      let result: unknown;
      if (request.method === "app.doctor") {
        result = { report: await diagnoseHost((method, params, timeout) => call(method, params ?? undefined, timeout)) };
      } else if (request.method === "host.start") {
        await withUserBus((bus) => changeUnit(bus, "lattices-host.service", "StartUnit"));
      } else {
        if (!allowed.has(request.method)) throw new Error("Unsupported app action");
        const params = request.params ?? {};
        if (request.method.startsWith("computer.") && !request.method.startsWith("computer.virtual.") && params.space !== "virtual") throw new Error("Preview controls require the virtual space");
        if (request.method === "sessions.launch" && typeof params.path === "string") {
          params.path = params.path === "~" ? homedir() : params.path.startsWith("~/") ? homedir() + params.path.slice(1) : params.path;
        }
        result = await call(request.method, params);
      }
      emit({ type: "done", result, requestId: request.requestId });
      await refresh();
    } catch (error) { emit({ type: "error", message: (error as Error).message, requestId: request.requestId }); }
  });
});
input.on("close", () => { events?.close(); process.exit(0); });
process.on("SIGTERM", () => { events?.close(); process.exit(0); });
emitHints();
// The desktop palette is read here, apart from the host, so the app follows a
// theme change while the host is offline.
const appearance = watchAppearance(value => emit({ type: "appearance", appearance: value }), { warn: message => console.error(message) });
void refresh();
