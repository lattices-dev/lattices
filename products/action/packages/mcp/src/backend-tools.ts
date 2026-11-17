/**
 * action.backend.* — observe and act through a computer-use backend (LAT-013):
 * Codex Computer Use (codex-cua), trycua's Cua Driver (trycua-cua), Vercel Labs
 * agent-desktop or Action's own native host (action-cua).
 *
 * The backend only delivers. Action keeps policy: the caller names a backend
 * (no fallback), acts take a drive lease and pass the layer director's
 * refusal, a tier gate refuses anything above allowTiers before it is sent,
 * and every act reply carries the same delivery receipt as act.execute.
 */
import type { AxActionTier, DriveLease } from "@action/protocol";
import {
  BackendHost,
  BackendRefusal,
  backendTiers,
  defaultAllowTiers,
  parseAllowTiers,
  parseBackendAction,
  type BackendTier,
} from "@action/runtime";
import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { DeliveryError, delivery, withDelivery } from "./delivery.js";

type JsonObject = Record<string, unknown>;
type ToolHandler = (args: JsonObject) => Promise<JsonObject>;

export type BackendToolDeps = {
  host: BackendHost;
  ensureLease(input: { leaseId?: string; axTier: AxActionTier; actionKind: string; description: string; presentCursor?: boolean }): Promise<DriveLease>;
  /** The layer director's reason to refuse any act right now, or undefined. */
  actRefusal(): Promise<string | undefined | null>;
  /** Throws when Action points at a remote host: backends drive this Mac only. */
  assertLocal(tool: string): void;
};

const backendProperty = (ids: string[]) => ({
  type: "string",
  enum: ids,
  description: `Backend to use: ${ids.join(", ")}. Required; Action never picks one for you or falls back to another.`,
});

const text = (description: string) => ({ type: "string", description });

function schema(properties: Record<string, object>, required: string[]): Tool["inputSchema"] {
  return { type: "object", properties, required, additionalProperties: true };
}

export function backendTools(host: BackendHost): Tool[] {
  const ids = host.ids();
  const backend = backendProperty(ids);
  return [
    {
      name: "action.backend.status",
      title: "Backend Status",
      description: "Whether each computer-use backend (or the one named) is installed and ready, its version, the tier it declares per action, and where its options live. Starts a backend's driver process the first time it is asked.",
      inputSchema: schema({ backend: { ...backend, description: "Optional: report only this backend." } }, []),
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    {
      name: "action.backend.targets",
      title: "Backend Targets",
      description: "List the windows or apps a backend can observe and act on. targetIds belong to this Action process: list again after Action restarts.",
      inputSchema: schema({ backend }, ["backend"]),
      annotations: { readOnlyHint: true, idempotentHint: true },
    },
    {
      name: "action.backend.observe",
      title: "Backend Observe",
      description: "Read a target's accessibility tree through a backend, and its screenshot when asked (saved to a file; the path is in the reply). Each node has a ref for backend.act. Only refs from the newest observation of a target can be acted on.",
      inputSchema: schema({
        backend,
        targetId: text("A targetId from action.backend.targets."),
        screenshot: { type: "boolean", description: "Also capture a screenshot. trycua-cua needs one before click or scroll at a point, whose coordinates are screenshot pixels." },
      }, ["backend", "targetId"]),
      annotations: { readOnlyHint: true, idempotentHint: false },
    },
    {
      name: "action.backend.act",
      title: "Backend Act",
      description: "Act on a target through a backend. action.kind is press {ref}, setValue {ref, value}, secondary {ref, name}, type {text, ref?}, key {combo, e.g. \"cmd+l\"}, click {point, button?, count?}, or scroll {ref | point, direction, amount?}. "
        + `allowTiers (default ${JSON.stringify(defaultAllowTiers)}) lists the tiers this act may use; an action whose declared tier is outside it is refused before anything is sent. attention means keys or pointer events, so allow it only when that is intended. `
        + "agent-desktop type/scroll require refs; key requires the selected window already focused; coordinate clicks and secondary actions are unsupported. "
        + "A stale-ref refusal may carry a fresh observation; otherwise observe again. Every reply carries delivery { status, retrySafe, recovery } as action.act.execute does.",
      inputSchema: schema({
        backend,
        targetId: text("A targetId from action.backend.targets."),
        observationId: text("The observation the action's refs (or click/scroll point) come from. It must be the target's newest."),
        action: { type: "object", description: "The backend action. See the tool description." },
        allowTiers: { type: "array", items: { type: "string", enum: backendTiers }, description: "Tiers this act may use. observe is always allowed." },
        leaseId: text("Drive lease id. Required when this client has more than one active lease."),
      }, ["backend", "targetId", "observationId", "action"]),
      annotations: { readOnlyHint: false, idempotentHint: false },
    },
  ];
}

function requireString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new BackendRefusal("invalid-action", `${name} is required.`);
  return value.trim();
}

/** Refusal details for the error reply: what refused, and the fresh observation when there is one. */
export function backendRefusalMetadata(error: unknown): JsonObject | undefined {
  const refusal = error instanceof BackendRefusal ? error : error instanceof DeliveryError && error.cause instanceof BackendRefusal ? error.cause : undefined;
  if (!refusal) return undefined;
  return { refusal: { code: refusal.code, ...(refusal.observation ? { observation: refusal.observation } : {}) } };
}

export function backendHandlers(deps: BackendToolDeps): Record<string, ToolHandler> {
  const { host } = deps;
  return {
    async "action.backend.status"(args) {
      deps.assertLocal("action.backend.status");
      const only = typeof args.backend === "string" ? requireString(args.backend, "backend") : undefined;
      const ids = only ? [only] : host.ids();
      const backends = await Promise.all(ids.map(async (id) => {
        try {
          const live = host.get(id);
          const availability = await host.availability(id, { timeoutMs: 20_000 });
          return { backend: id, summary: host.summary(id), ...availability, tiers: live.capabilities.actions };
        } catch (error) {
          return { backend: id, summary: host.summary(id), ready: false, reason: error instanceof Error ? error.message : String(error) };
        }
      }));
      return { ok: true, generation: host.generation, defaultAllowTiers, backends };
    },

    async "action.backend.targets"(args) {
      deps.assertLocal("action.backend.targets");
      const id = requireString(args.backend, "backend");
      return { ok: true, backend: id, targets: await host.targets(id) };
    },

    async "action.backend.observe"(args) {
      deps.assertLocal("action.backend.observe");
      const id = requireString(args.backend, "backend");
      const observation = await host.observe(id, requireString(args.targetId, "targetId"), args.screenshot === true);
      return { ok: true, backend: id, observation };
    },

    async "action.backend.act"(args) {
      const kind = typeof (args.action as JsonObject | undefined)?.kind === "string" ? String((args.action as JsonObject).kind) : undefined;
      // Everything up to the backend call sends nothing.
      let declaredTier: BackendTier;
      let lease: DriveLease;
      let parsed: ReturnType<typeof parseBackendAction>;
      let allowTiers: BackendTier[];
      let id: string;
      let targetId: string;
      let observationId: string;
      try {
        id = requireString(args.backend, "backend");
        targetId = requireString(args.targetId, "targetId");
        observationId = requireString(args.observationId, "observationId");
        deps.assertLocal("action.backend.act");
        const refusal = await deps.actRefusal();
        if (refusal) throw new Error(refusal);
        parsed = parseBackendAction(args.action);
        allowTiers = parseAllowTiers(args.allowTiers);
        declaredTier = host.gate(id, parsed, allowTiers);
        lease = await deps.ensureLease({
          leaseId: typeof args.leaseId === "string" ? args.leaseId : undefined,
          axTier: declaredTier,
          actionKind: `backend:${parsed.kind}`,
          description: `${id} ${parsed.kind}`,
          // Semantic acts move nothing on screen; attention ones take keys or the pointer.
          presentCursor: declaredTier === "attention",
        });
      } catch (error) {
        throw withDelivery(error, "not_delivered", kind);
      }

      let result;
      try {
        result = await host.act(id, targetId, parsed, { observationId, allowTiers });
      } catch (error) {
        // A backend refusal promises nothing happened; anything else may have landed.
        throw withDelivery(error, error instanceof BackendRefusal ? "not_delivered" : "delivery_uncertain", kind);
      }
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
          delivery: delivery("delivered_unverified", kind),
        },
        ...(result.observation ? { observation: result.observation } : {}),
        drive: { leaseId: lease.leaseId, agent: lease.agent, task: lease.task, mode: lease.mode, implicit: lease.implicit === true },
      };
    },
  };
}
