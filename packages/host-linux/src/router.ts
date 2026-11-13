import { assertRequestActive } from "./request-context.ts";
// The Linux host speaks the Mac daemon's protocol (docs/api.md, "Wire
// protocol"): {id, method, params} in, {id, result, error} out, {event, data}
// pushed. Endpoints use the LAT-012 domain names; old names are accepted as
// aliases so older clients keep working against this host too.

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Params = Record<string, Json>;

export interface Param {
  name: string;
  type: string;
  required?: boolean;
  description: string;
}

export interface Endpoint {
  method: string;
  description: string;
  access: "read" | "mutate";
  /** Only loopback connections may call it (e.g. approving a pairing). */
  loopbackOnly?: boolean;
  /** Capability this endpoint needs; the endpoint is hidden when the host lacks it. */
  capability?: string;
  params?: Param[];
  returns: string;
  handler: (params: Params) => Json | Promise<Json>;
}

export interface Request {
  id: string;
  method: string;
  /** Absolute caller deadline; old clients may omit it. */
  deadline?: number;
  params?: Params | null;
}

export interface Response {
  id: string;
  result: Json;
  error: string | null;
}

export class RouterError extends Error {
  static unknownMethod(method: string) {
    return new RouterError(`Unknown method: ${method}`);
  }
  static missingParam(name: string) {
    return new RouterError(`Missing parameter: ${name}`);
  }
  static notFound(what: string) {
    return new RouterError(`Not found: ${what}`);
  }
}

/** Pre-LAT-012 names, matching apps/mac/Sources/Core/Daemon/MethodAliases.swift. */
export const METHOD_ALIASES: Record<string, string> = {
  "window.focus": "windows.focus",
  "window.move": "windows.move",
  "window.place": "windows.place",
  "window.present": "windows.present",
  "window.resolve": "windows.resolve",
  "window.pick.start": "windows.pick",
  "window.tile": "windows.place",
  "layer.activate": "layers.activate",
  "layer.switch": "layers.switch",
  "space.optimize": "spaces.optimize",
  "session.launch": "sessions.launch",
  "session.kill": "sessions.kill",
  "session.detach": "sessions.detach",
  "session.sync": "sessions.sync",
  "session.restart": "sessions.restart",
  "lattices.search": "search.query",
  "tmux.sessions": "tmux.list",
  "tmux.inventory": "tmux.list",
  "ocr.recent": "ocr.history",
};

/** Domain renames: `cua.*` is the computer-use domain's new name for `computer.*`. */
export const DOMAIN_ALIASES: ReadonlyArray<readonly [alias: string, target: string]> = [["cua.", "computer."]];

/** A method with any renamed domain prefix mapped to the name endpoints register under. */
export function domainResolved(method: string): string {
  for (const [alias, target] of DOMAIN_ALIASES) if (method.startsWith(alias)) return target + method.slice(alias.length);
  return method;
}

/** The registered name a method (or any alias of it) dispatches to. */
export function canonicalName(method: string): string {
  const resolved = domainResolved(method);
  return METHOD_ALIASES[resolved] ?? resolved;
}

export function resolveAlias(method: string, params: Params): { method: string; params: Params } {
  method = domainResolved(method);
  const target = METHOD_ALIASES[method];
  if (!target) return { method, params };
  if (method === "window.tile" && params.placement == null) {
    return { method: target, params: { ...params, placement: params.position ?? null } };
  }
  if (method === "tmux.inventory") return { method: target, params: { ...params, includeOrphans: true } };
  return { method: target, params };
}

export class Router {
  private endpoints = new Map<string, Endpoint>();

  constructor(private capabilities: () => Set<string>) {}

  register(endpoint: Endpoint) {
    this.endpoints.set(endpoint.method, endpoint);
  }

  /** The endpoint a method (or its alias) names, if any. */
  lookup(method: string): Endpoint | undefined {
    return this.endpoints.get(canonicalName(method));
  }

  /** Endpoints this host can serve right now. */
  available(): Endpoint[] {
    const caps = this.capabilities();
    return [...this.endpoints.values()].filter((e) => !e.capability || caps.has(e.capability));
  }

  async dispatch(method: string, params: Params | null | undefined): Promise<Json> {
    assertRequestActive();
    const resolved = resolveAlias(method, params ?? {});
    const endpoint = this.endpoints.get(resolved.method);
    if (!endpoint) throw RouterError.unknownMethod(method);
    if (endpoint.capability && !this.capabilities().has(endpoint.capability)) {
      throw new RouterError(
        `capability_unavailable: ${resolved.method} needs ${endpoint.capability}, which this host does not have`
      );
    }
    return endpoint.handler(resolved.params);
  }

  async handle(request: Request): Promise<Response> {
    try {
      const result = await this.dispatch(request.method, request.params);
      return { id: request.id, result: result ?? null, error: null };
    } catch (err) {
      return { id: request.id, result: null, error: (err as Error).message };
    }
  }

  schema(): Json {
    const methods = this.available().map((e) => ({
      method: e.method,
      description: e.description,
      access: e.access,
      ...(e.loopbackOnly ? { loopbackOnly: true } : {}),
      params: (e.params ?? []).map((p) => ({
        name: p.name,
        type: p.type,
        required: p.required ?? false,
        description: p.description,
      })),
      returns: { type: "custom", description: e.returns },
    }));
    const served = new Set(methods.map((m) => m.method));
    const aliases: Record<string, string> = Object.fromEntries(Object.entries(METHOD_ALIASES).filter(([, to]) => served.has(to)));
    for (const name of served) for (const [alias, target] of DOMAIN_ALIASES) {
      if (name.startsWith(target)) aliases[alias + name.slice(target.length)] = name;
    }
    return { version: "1.0", models: [], methods, aliases };
  }
}

// ── Param helpers ─────────────────────────────────────────────────────

export function str(params: Params, name: string): string | undefined {
  const v = params[name];
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

export function num(params: Params, name: string): number | undefined {
  const v = params[name];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return undefined;
}

export function bool(params: Params, name: string): boolean | undefined {
  const v = params[name];
  return typeof v === "boolean" ? v : undefined;
}

export function requireStr(params: Params, name: string): string {
  const v = str(params, name);
  if (v === undefined) throw RouterError.missingParam(name);
  return v;
}
