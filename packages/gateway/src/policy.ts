import { METHOD_ALIASES } from "../../host-linux/src/router.ts";

export const PRODUCTS = ["lattices", "action", "blink", "speech"] as const;
export type Product = typeof PRODUCTS[number];
export const SCOPES = ["read", "screen", "act", "drive", "shell"] as const;
export type Scope = typeof SCOPES[number];
/** Pairing shorthands. Each still carries everything it granted before
 * `screen` and `shell` were split out, except `read`, which no longer sees the screen. */
export type Shorthand = "read" | "act" | "drive";
const SHORTHANDS: Record<Shorthand, Scope[]> = {
  read: ["read"],
  act: ["read", "screen", "act"],
  drive: ["read", "screen", "act", "drive", "shell"],
};

/** Exact reviewed operations. Unknown additions remain local until reviewed.
 * `screen` returns what the display shows: pixels, OCR, terminal contents, files.
 * `shell` runs commands or types free text, which reaches terminals. */
const operations: Record<Product, Record<Scope, string[]>> = {
  lattices: {
    read: [
      "events.subscribe", "events.unsubscribe", "daemon.status", "host.describe", "api.schema",
      "windows.list", "windows.get", "windows.search", "windows.resolve", "spaces.list", "spaces.assignments", "desktop.snapshot",
      "tmux.list", "terminals.list", "terminals.search", "projects.list", "processes.list", "processes.tree",
      "layers.list", "layers.members", "solo.status", "stage.status", "tabs.list",
      "search.query", "history.list", "runs.list", "runs.get", "runs.artifacts", "display.input.get",
    ],
    screen: [
      "capture.screenshotDisplay", "capture.screenshotWindow", "capture.screenshotRegion", "capture.still", "computer.observe", "windows.preview",
      "capture.stream.start", "capture.stream.ack", "capture.stream.keyframe", "capture.stream.stop",
      "terminals.capture", "ocr.read", "ocr.find", "ocr.snapshot", "ocr.scan", "browser.getText", "files.read",
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
      "computer.pressKey", "computer.hotkey", "computer.prepare", "computer.windowState", "computer.elementAction", "computer.setValue",
      "computer.focusWindow", "computer.launchApp", "computer.verify", "layers.activate", "layers.switch",
      "display.input.set",
    ],
    shell: [
      "computer.typeText", "computer.typeWindowText", "computer.typeElement",
      // apps.open accepts an arbitrary command; sessions run their project's command.
      "apps.open", "sessions.launch", "sessions.restart",
    ],
  },
  // Connection-owned leases and workspace operations stay local until routing
  // preserves a dedicated product connection for each remote client.
  action: {
    read: ["ping", "status", "permissions.snapshot", "window.getFrame", "calculator.buttons", "calculator.displayValue", "drive.status"],
    screen: ["capture.screenshotAppWindow", "capture.screenshotRegion", "capture.screenshotScreen"],
    act: ["sessions.prune", "sessions.clear"],
    drive: ["app.launch", "app.activate", "permissions.request", "permissions.requestAccessibility", "settings.openAccessibility", "settings.openScreenRecording", "input.drag", "accessibility.pressElement", "accessibility.setValue", "window.setFrame", "calculator.clickButton", "capture.recordAppWindow", "capture.recordRegion"],
    shell: ["input.typeText"],
  },
  blink: { read: ["system.hello", "placements.list", "notes.list", "notes.get"], screen: [], act: ["notes.present", "desk.save", "desk.restore"], drive: [], shell: [] },
  speech: { read: ["speech.status", "speech.voices"], screen: [], act: ["speech.enqueue", "speech.pause", "speech.resume", "speech.seek", "speech.stop", "speech.next", "speech.preferredVoice.set"], drive: [], shell: [] },
};

export function isProduct(value: unknown): value is Product { return typeof value === "string" && (PRODUCTS as readonly string[]).includes(value); }
/** Public rename only: persisted permissions and local routing retain Blink's identity. */
export function canonicalProduct(value: unknown): Product | null {
  return value === "canvas" ? "blink" : isProduct(value) ? value : null;
}
export function canonicalMethod(product: Product, method: string): string { return product === "lattices" ? METHOD_ALIASES[method] ?? method : method; }
export function methodScope(product: Product, method: string): Scope | null {
  const name = canonicalMethod(product, method);
  for (const scope of SCOPES) if (operations[product][scope].includes(name)) return scope;
  return null;
}
export function grantName(product: Product, method: string): string { return `${product}:${canonicalMethod(product, method)}`; }
export function isShorthand(value: unknown): value is Shorthand { return value === "read" || value === "act" || value === "drive"; }
export function isScope(value: unknown): value is Scope { return typeof value === "string" && (SCOPES as readonly string[]).includes(value); }
/** The scopes a shorthand stands for, plus any named alongside it, in canonical order. */
export function expandScopes(shorthand: Shorthand, extra: readonly Scope[] = []): Scope[] {
  const wanted = new Set<Scope>([...SHORTHANDS[shorthand], ...extra]);
  return SCOPES.filter(s => wanted.has(s));
}
/** Exact grants for one scope alone. */
export function grantsInScope(product: Product, scope: Scope): string[] { return operations[product][scope].map(m => grantName(product, m)); }
/** Exact grants for a shorthand (read, act or drive) and every scope it carries. */
export function grantsForScope(product: Product, shorthand: Shorthand, extra: readonly Scope[] = []): string[] {
  return expandScopes(shorthand, extra).flatMap(s => grantsInScope(product, s));
}
/** Core scopes whose every Lattices operation is in these grants. */
export function scopesHeld(grants: readonly string[]): Scope[] {
  const held = new Set(grants);
  return SCOPES.filter(s => operations.lattices[s].length > 0 && grantsInScope("lattices", s).every(g => held.has(g)));
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
  if (!isShorthand(scope)) throw new Error("Invalid pairing scope");
  // Extra scopes ride along with the shorthand (pair --read-only --screen).
  // Older gateways ignore them and grant the shorthand alone.
  const extra = params.scopes ?? [];
  if (!Array.isArray(extra) || extra.length > SCOPES.length || !extra.every(isScope)) throw new Error("Invalid pairing scopes");
  // Old lats --host pair only grants core product operations. Other products
  // require explicit grants and an additional human approval.
  return grantsForScope("lattices", scope, extra).sort();
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
