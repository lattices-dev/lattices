export type Rpc = (method: string, params?: Record<string, unknown> | null, timeout?: number) => Promise<unknown>;
export interface SpaceDisplay {
  displayIndex: number;
  name?: string;
  displayId?: string;
  currentSpaceId: number;
  spaces: { id: number; name?: string; isCurrent: boolean; windowCount?: number }[];
}

export const spaceUsage = `lats spaces [--json]                         List spaces on each display
lats space next|prev|previous|<id> [--dry-run] [--json]
  next/prev cycle existing spaces; previous returns to the last space.
  A positive numeric id opens that space, creating it if needed (Linux host).`;

export function parseSpaceArgs(args: string[]) {
  const flags = args.filter(arg => arg.startsWith("--"));
  if (flags.some(flag => !["--json", "--dry-run"].includes(flag))) throw new Error(spaceUsage);
  const values = args.filter(arg => !arg.startsWith("--"));
  if (values.length !== 1) throw new Error(spaceUsage);
  const value = values[0];
  const directions: Record<string, string> = { next: "e+1", prev: "e-1", previous: "previous" };
  let workspace: number | string = Object.hasOwn(directions, value) ? directions[value] : "";
  if (!workspace) {
    if (!/^[1-9]\d*$/.test(value) || Number(value) > 2147483647) throw new Error("Space must be next, prev, previous, or a positive workspace id.");
    workspace = Number(value);
  }
  return { workspace, dryRun: flags.includes("--dry-run"), json: flags.includes("--json") };
}

export async function listSpaces(rpc: Rpc, json = false): Promise<void> {
  const displays = await rpc("spaces.list") as SpaceDisplay[];
  if (json) { console.log(JSON.stringify(displays, null, 2)); return; }
  for (const display of displays) {
    console.log(`Display ${display.displayIndex} · ${display.name || display.displayId || "Display"}`);
    for (const space of display.spaces) {
      console.log(`  ${space.isCurrent ? "●" : "○"} ${space.id}  ${space.name && space.name !== String(space.id) ? space.name + "  " : ""}${space.windowCount === undefined ? "" : space.windowCount + " windows"}`);
    }
    console.log();
  }
}

export async function focusSpace(rpc: Rpc, args: ReturnType<typeof parseSpaceArgs>): Promise<void> {
  const result = await rpc("spaces.focus", { workspace: args.workspace, dryRun: args.dryRun }) as { ok: boolean; status: string; currentSpaceId?: number; target: number | string };
  if (result.ok === false) throw new Error("Space switch failed.");
  if (args.json) console.log(JSON.stringify(result, null, 2));
  else console.log(args.dryRun ? `Planned space switch: ${result.target}` : `Space ${result.currentSpaceId ?? result.target}`);
}
