import { METHOD_ALIASES } from "../../host-linux/src/router.ts";

export const PRODUCTS = ["lattices", "action", "blink", "speech"] as const;
export type Product = typeof PRODUCTS[number];
export type Scope = "read" | "act" | "drive";
const rank = { read: 0, act: 1, drive: 2 };

/** Exact reviewed operations. Unknown additions remain local until reviewed. */
const operations: Record<Product, Record<Scope, string[]>> = {
  lattices: {
    read: [
      "events.subscribe", "events.unsubscribe", "daemon.status", "host.describe", "api.schema",
      "windows.list", "windows.get", "windows.preview", "windows.search", "windows.resolve", "spaces.list", "spaces.assignments", "desktop.snapshot",
      "capture.screenshotDisplay", "capture.screenshotWindow", "capture.screenshotRegion", "capture.still", "computer.observe",
      "capture.stream.start", "capture.stream.ack", "capture.stream.keyframe", "capture.stream.stop",
      "tmux.list", "terminals.list", "terminals.search", "terminals.capture", "projects.list", "processes.list", "processes.tree",
      "ocr.read", "ocr.find", "ocr.snapshot", "ocr.scan", "layers.list", "layers.members", "solo.status", "stage.status", "tabs.list",
      "search.query", "history.list", "runs.list", "runs.get", "runs.artifacts", "browser.getText", "files.read", "display.input.get",
    ],
    act: [
      "windows.focus", "windows.place", "windows.move", "windows.moveBack", "windows.present", "windows.pick",
      "spaces.focus", "spaces.optimize", "displays.create", "displays.remove", "layout.distribute",
      "layers.create", "layers.rename", "layers.delete", "layers.assign", "layers.unassign", "layers.exit", "layers.reveal", "layers.classic", "layers.undo",
      "solo.enter", "solo.exit", "solo.toggle", "stage.enter", "stage.exit", "stage.toggle", "stage.cycle",
      "tabs.stack", "tabs.add", "tabs.select", "tabs.layout", "tabs.unstack", "mouse.home", "mouse.find", "sessions.kill", "sessions.detach",
      "capture.record", "capture.recordWindow", "capture.recordRegion", "capture.stopRecording",
    ],
    drive: [
      "computer.click", "computer.doubleClick", "computer.rightClick", "computer.drag", "computer.scroll", "computer.aim",
      "computer.typeText", "computer.pressKey", "computer.hotkey", "computer.prepare", "computer.windowState", "computer.elementAction", "computer.typeElement", "computer.setValue",
      "computer.focusWindow", "computer.launchApp", "computer.typeWindowText", "computer.verify", "apps.open", "sessions.launch", "sessions.restart", "layers.activate", "layers.switch",
      "display.input.set",
    ],
  },
  // Connection-owned leases and workspace operations stay local until routing
  // preserves a dedicated product connection for each remote client.
  action: {
    read: ["ping", "status", "permissions.snapshot", "window.getFrame", "calculator.buttons", "calculator.displayValue", "drive.status", "capture.screenshotAppWindow", "capture.screenshotRegion", "capture.screenshotScreen"],
    act: ["sessions.prune", "sessions.clear"],
    drive: ["app.launch", "app.activate", "permissions.request", "permissions.requestAccessibility", "settings.openAccessibility", "settings.openScreenRecording", "input.typeText", "input.drag", "accessibility.pressElement", "accessibility.setValue", "window.setFrame", "calculator.clickButton", "capture.recordAppWindow", "capture.recordRegion"],
  },
  blink: { read: ["system.hello", "placements.list", "notes.list", "notes.get"], act: ["notes.present", "desk.save", "desk.restore"], drive: [] },
  speech: { read: ["speech.status", "speech.voices"], act: ["speech.enqueue", "speech.pause", "speech.resume", "speech.seek", "speech.stop", "speech.next", "speech.preferredVoice.set"], drive: [] },
};

export function isProduct(value: unknown): value is Product { return typeof value === "string" && (PRODUCTS as readonly string[]).includes(value); }
/** Public rename only: persisted permissions and local routing retain Blink's identity. */
export function canonicalProduct(value: unknown): Product | null {
  return value === "canvas" ? "blink" : isProduct(value) ? value : null;
}
export function canonicalMethod(product: Product, method: string): string { return product === "lattices" ? METHOD_ALIASES[method] ?? method : method; }
export function methodScope(product: Product, method: string): Scope | null {
  const name = canonicalMethod(product, method);
  for (const scope of ["read", "act", "drive"] as const) if (operations[product][scope].includes(name)) return scope;
  return null;
}
export function grantName(product: Product, method: string): string { return `${product}:${canonicalMethod(product, method)}`; }
export function grantsForScope(product: Product, scope: Scope): string[] {
  return (["read", "act", "drive"] as const).filter(s => rank[s] <= rank[scope]).flatMap(s => operations[product][s].map(m => grantName(product, m)));
}
function canonicalGrant(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const parts = value.split(":");
  if (parts.length !== 2) return null;
  const product = canonicalProduct(parts[0]), method = parts[1];
  return product && method && canonicalMethod(product, method) === method && methodScope(product, method) !== null
    ? grantName(product, method) : null;
}
export function validGrant(value: unknown): value is string {
  // Stored grants must use the canonical identity; aliases normalize before approval.
  return typeof value === "string" && canonicalGrant(value) === value;
}
export function authorizeMethod(grants: string[], product: Product, method: string): string | null {
  if (!methodScope(product, method)) return `method_denied: ${product}:${method} is not exposed by this gateway`;
  return grants.includes(grantName(product, method)) ? null : `scope_denied: missing ${grantName(product, method)}`;
}
export function requestedGrants(params: Record<string, unknown>): string[] {
  if (params.grants !== undefined) {
    if (!Array.isArray(params.grants) || params.grants.length === 0 || params.grants.length > 128) throw new Error("Invalid exact product:method grants");
    const grants = params.grants.map(canonicalGrant);
    if (grants.some(grant => grant === null)) throw new Error("Invalid exact product:method grants");
    return [...new Set(grants as string[])].sort();
  }
  const scope = params.scope ?? "read";
  if (scope !== "read" && scope !== "act" && scope !== "drive") throw new Error("Invalid pairing scope");
  // Old lats --host pair only grants core product operations. Other products
  // require explicit grants and an additional human approval.
  return grantsForScope("lattices", scope).sort();
}

export function validateRemoteRequest(req: Request, allowedHosts: Set<string>): string | null {
  if (req.headers.has("origin")) return "Browser origins are not allowed";
  if (req.method !== "GET" && req.method !== "POST") return "Method not allowed";
  const host = req.headers.get("host")?.toLowerCase();
  if (!host || !allowedHosts.has(host)) return "Host is not allowed";
  const url = new URL(req.url);
  if (url.search || url.hash || url.username || url.password) return "Unexpected URL components";
  for (const name of ["x-lattices-device-id", "x-lattices-timestamp", "x-lattices-nonce", "x-lattices-signature"]) if ((req.headers.get(name)?.length ?? 0) > 256) return "Authentication header too long";
  return null;
}

export function isTailnetAddress(address: string): boolean {
  if (address.startsWith("fd7a:115c:a1e0:")) return /^[a-f0-9:]+$/i.test(address);
  const parts = address.split(".").map(Number);
  return parts.length === 4 && parts.every(p => Number.isInteger(p) && p >= 0 && p < 256) && parts[0] === 100 && parts[1]! >= 64 && parts[1]! <= 127;
}
