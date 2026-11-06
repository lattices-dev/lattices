import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js";
import {
  BackendHost,
  backendTiers,
  backendsConfigPath,
  defaultAllowTiers,
  parseAllowTiers,
  parseBackendAction,
  type BackendCallInput,
} from "./host.js";
import { askForBackend } from "./ask.js";
import { BackendRefusal } from "./types.js";

type JsonObject = Record<string, unknown>;
export type CuaHandler = (args: JsonObject, input?: BackendCallInput) => Promise<CallToolResult>;

const text = (description: string) => ({ type: "string", description });
const schema = (properties: Record<string, object>, required: string[]): Tool["inputSchema"] =>
  ({ type: "object", properties, required, additionalProperties: false });

/** Tool definitions and handlers share a host, but do not own its transport or lifetime. */
export function cuaTools(host: BackendHost): Tool[] {
  const ids = host.ids();
  const backend = {
    type: "string",
    enum: ids,
    description: `Backend to use: ${ids.join(", ")}. Required; no backend is picked for you and there is no fallback.`,
  };
  return [
    {
      name: "cua_status",
      title: "Backend Status",
      description: "Whether each computer-use backend (or the one named) is installed and ready, its version, permission/install/config needs and their setup commands, the tier it declares per action, and where its options live. Starts a backend's driver process the first time it is asked.",
      inputSchema: schema({ backend: { ...backend, description: "Optional: report only this backend." } }, []),
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    {
      name: "cua_setup",
      title: "Backend Setup",
      description: "Set up the named backend. May show macOS permission dialogs or open System Settings, and waits up to about 2 minutes for the user to enable permissions. Reports steps and any remaining needs; only the user can grant macOS access.",
      inputSchema: schema({ backend }, ["backend"]),
      annotations: { readOnlyHint: false, idempotentHint: false },
    },
    {
      name: "cua_ask",
      title: "Ask The Operator",
      description: "Ask the person at the Mac for the named backend's missing macOS permissions in an Action.app panel. Shows nothing when the backend is already ready. One panel per request across agents: a second caller waits on the first. The backend's own status check is the verdict; the panel ticks each permission as it lands and closes itself. Waits up to timeoutSeconds (default 300). outcome is satisfied, declined, cancelled, expired or unsupported (an Action.app without the panel: fall back to cua_status needs).",
      inputSchema: schema({
        backend,
        task: text("Optional: the task this is for, shown on the panel."),
        timeoutSeconds: { type: "number", minimum: 10, maximum: 900, description: "How long to wait for the operator. Default 300." },
      }, ["backend"]),
      annotations: { readOnlyHint: false, idempotentHint: true },
    },
    {
      name: "cua_targets",
      title: "Backend Targets",
      description: "List the windows or apps a backend can observe and act on. targetIds belong to this server process: list again after it restarts.",
      inputSchema: schema({ backend }, ["backend"]),
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    {
      name: "cua_observe",
      title: "Backend Observe",
      description: "Read a target's accessibility tree through a backend, and its screenshot when asked (saved to a file; the path is in the reply). Each node has a ref for cua_act. Only refs from the newest observation of a target can be acted on.",
      inputSchema: schema({
        backend,
        targetId: text("A targetId from cua_targets."),
        screenshot: { type: "boolean", description: "Also capture a screenshot. trycua-cua needs one before click or scroll at a point, whose coordinates are screenshot pixels." },
      }, ["backend", "targetId"]),
      annotations: { readOnlyHint: true, idempotentHint: false },
    },
    {
      name: "cua_act",
      title: "Backend Act",
      description: "Act on a target through a backend. action.kind is press {ref}, setValue {ref, value}, secondary {ref, name}, type {text, ref?}, key {combo, e.g. \"cmd+l\"}, click {point, button?, count?}, or scroll {ref | point, direction, amount?}. "
        + `allowTiers (default ${JSON.stringify(defaultAllowTiers)}) lists the tiers this act may use; an action whose declared tier is outside it is refused before anything is sent. attention means keys or pointer events, so allow it only when that is intended. `
        + "action-cua points use macOS screen coordinates, and its key/type actions use the current global keyboard focus. "
        + "A stale-ref refusal may carry a fresh observation: use its refs before trying again. Success carries delivery.status delivered_unverified; a BackendRefusal is not_delivered, and other errors are delivery_uncertain. Observe to verify the effect; do not blindly retry uncertain delivery.",
      inputSchema: schema({
        backend,
        targetId: text("A targetId from cua_targets."),
        observationId: text("The observation the action's refs (or click/scroll point) come from. It must be the target's newest."),
        action: { type: "object", description: "The backend action. See the tool description." },
        allowTiers: { type: "array", items: { type: "string", enum: backendTiers }, description: "Tiers this act may use. observe is always allowed." },
      }, ["backend", "targetId", "observationId", "action"]),
      annotations: { readOnlyHint: false, idempotentHint: false },
    },
  ];
}

function requireString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new BackendRefusal("invalid-action", `${name} is required.`);
  return value.trim();
}

function reply(body: JsonObject, isError = false): CallToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(body) }],
    structuredContent: body,
    ...(isError ? { isError: true } : {}),
  };
}

/** A refusal guarantees no delivery. An unclassified error makes no such promise. */
export function cuaError(error: unknown): CallToolResult {
  const refusal = error instanceof BackendRefusal;
  return reply({
    ok: false,
    code: refusal ? error.code : "backend-error",
    message: error instanceof Error ? error.message : String(error),
    delivery: { status: refusal ? "not_delivered" : "delivery_uncertain" },
    ...(refusal && error.observation ? { observation: error.observation } : {}),
  }, true);
}

export function cuaHandlers(host: BackendHost): Record<string, CuaHandler> {
  const handlers: Record<string, (args: JsonObject, input?: BackendCallInput) => Promise<JsonObject>> = {
    async cua_setup(args, input) {
      const id = requireString(args.backend, "backend");
      const result = await host.setup(id, input, { interactive: true });
      return { ok: result.ready, backend: id, ...result };
    },
    async cua_ask(args, input) {
      const id = requireString(args.backend, "backend");
      host.get(id);
      const seconds = args.timeoutSeconds === undefined ? 300 : Number(args.timeoutSeconds);
      if (!Number.isFinite(seconds) || seconds < 10 || seconds > 900) throw new BackendRefusal("invalid-action", "timeoutSeconds must be between 10 and 900.");
      const task = args.task === undefined ? `Set up ${id}` : requireString(args.task, "task");
      const result = await askForBackend(host, id, {
        timeoutMs: seconds * 1000, ...(input?.signal ? { signal: input.signal } : {}),
        call: { ...input, timeoutMs: 20_000 }, requester: { agent: input?.caller ?? "agent", task },
      });
      return { ok: result.outcome === "satisfied" || result.outcome === "confirmed", backend: id, ...result };
    },
    async cua_status(args, input) {
      const only = args.backend === undefined ? undefined : requireString(args.backend, "backend");
      const backends = await Promise.all((only ? [only] : host.ids()).map(async (id) => {
        try {
          const live = host.get(id);
          const availability = await host.availability(id, { ...input, timeoutMs: input?.timeoutMs ?? 20_000 });
          return { backend: id, summary: host.summary(id), ...availability, tiers: live.capabilities.actions };
        } catch (error) {
          return { backend: id, summary: host.summary(id), ready: false, reason: error instanceof Error ? error.message : String(error) };
        }
      }));
      return { ok: true, generation: host.generation, defaultConfigPath: backendsConfigPath(), defaultAllowTiers, backends };
    },
    async cua_targets(args, input) {
      const id = requireString(args.backend, "backend");
      return { ok: true, backend: id, targets: await host.targets(id, input) };
    },
    async cua_observe(args, input) {
      const id = requireString(args.backend, "backend");
      if (args.screenshot !== undefined && typeof args.screenshot !== "boolean") {
        throw new BackendRefusal("invalid-action", "screenshot must be a boolean.");
      }
      const observation = await host.observe(id, requireString(args.targetId, "targetId"), args.screenshot === true, input);
      return { ok: true, backend: id, observation };
    },
    async cua_act(args, input) {
      const id = requireString(args.backend, "backend");
      const targetId = requireString(args.targetId, "targetId");
      const observationId = requireString(args.observationId, "observationId");
      const action = parseBackendAction(args.action);
      const allowTiers = parseAllowTiers(args.allowTiers);
      const result = await host.act(id, targetId, action, { observationId, allowTiers }, input);
      return {
        ok: true,
        backend: id,
        result: {
          at: new Date().toISOString(),
          status: "succeeded",
          tierDeclared: result.declaredTier,
          tierUsed: result.tierUsed,
          ...(result.tierExceeded ? { tierExceeded: true } : {}),
          mechanism: result.mechanism,
          ...(result.message ? { message: result.message } : {}),
          delivery: { status: "delivered_unverified" },
        },
        ...(result.observation ? { observation: result.observation } : {}),
      };
    },
  };
  return Object.fromEntries(Object.entries(handlers).map(([name, handler]) => [name, async (args: JsonObject, input?: BackendCallInput) => {
    try {
      const body = await handler(args, input);
      return reply(body, body.ok === false);
    } catch (error) {
      return cuaError(error);
    }
  }]));
}
