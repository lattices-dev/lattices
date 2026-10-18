import type { Op } from "./hyprland.ts";
import { Router, RouterError, type Params, type Json } from "./router.ts";

export type SpaceTarget = number | "e+1" | "e-1" | "previous";
export function spaceTarget(params: Params): SpaceTarget {
  const value = params.workspace;
  if (value === "e+1" || value === "e-1" || value === "previous") return value;
  if (typeof value === "number" && Number.isInteger(value) && value > 0 && value <= 2147483647) return value;
  throw new RouterError("workspace must be a positive id, e+1, e-1, or previous");
}

interface SpaceSnapshot {
  monitors: { name: string; focused?: boolean }[];
  displays: { displayId: string; displayIndex: number; currentSpaceId: number }[];
}
interface SpaceDependencies {
  snapshot: () => Promise<SpaceSnapshot>;
  apply: (ops: Op[]) => Promise<string[]>;
}

export function registerSpaceFocus(router: Router, deps: SpaceDependencies): void {
  router.register({
    method: "spaces.focus", description: "Switch the focused display to a workspace id, next/previous existing workspace, or former workspace",
    access: "mutate", capability: "spaces.read",
    params: [{ name: "workspace", type: "int|string", required: true, description: "Positive id, e+1, e-1, or previous" }, { name: "dryRun", type: "bool", description: "Plan without switching" }],
    returns: "Object with ok, status, target, displayIndex, currentSpaceId and trace",
    handler: async params => {
      const target = spaceTarget(params); // Validate before contacting the compositor.
      const before = await deps.snapshot();
      const display = before.displays.find(d => d.displayId === before.monitors.find(m => m.focused)?.name) ?? before.displays[0];
      if (!display) throw RouterError.notFound("focused display");
      if (params.dryRun === true) return { ok: true, status: "planned", target, displayIndex: display.displayIndex, currentSpaceId: display.currentSpaceId, trace: [] };
      const trace = await deps.apply([{ op: "focusWorkspace", workspace: target }]);
      const after = await deps.snapshot();
      const focused = after.displays.find(d => d.displayId === after.monitors.find(m => m.focused)?.name) ?? after.displays.find(d => d.displayId === display.displayId);
      return { ok: true, status: "ok", target, displayIndex: focused?.displayIndex ?? display.displayIndex, currentSpaceId: focused?.currentSpaceId ?? null, trace } as Json;
    },
  });
}
