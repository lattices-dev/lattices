import { withDaemon, type DaemonClient } from "./daemon.ts";

export async function layerCommand(sub?: string, ...rest: string[]): Promise<void> {
  // A digit names a pad slot; a bad one fails before the daemon is asked.
  const target = sub ? layerTarget(sub) : undefined;
  if (target && "error" in target) {
    console.error(target.error);
    process.exit(1);
  }
  await withDaemon(async (client) => {
    const { daemonCall } = client;

    if (sub === "create") {
      await layerCreateCommand(client, rest);
      return;
    }
    if (sub === "snap") {
      await layerSnapCommand(client, rest[0]);
      return;
    }
    if (sub === "add") {
      await layerAddCommand(client, rest);
      return;
    }
    if (sub === "remove") {
      const fromIdx = rest.indexOf("--from");
      const layer = fromIdx !== -1 ? rest[fromIdx + 1] : undefined;
      const wids = parseWids(rest.filter((_, i) => fromIdx === -1 || (i !== fromIdx && i !== fromIdx + 1)));
      if (!wids.length) { console.log("Usage: lats layer remove wid:123 [wid:456 ...] [--from <layer>]"); return; }
      const result = await daemonCall("layers.unassign", { windowIds: wids, ...(layer ? { layer } : {}) }) as any;
      console.log(`Removed ${result.removed.length} window(s).`);
      if (result.held.length) console.log(`  Still held by an entry that matches other windows: ${result.held.map((w: number) => `wid:${w}`).join(" ")}. Edit workspace.json to narrow it.`);
      return;
    }
    if (sub === "rename") {
      if (!rest[0] || !rest[1]) { console.log("Usage: lats layer rename <layer> <new name>"); return; }
      await daemonCall("layers.rename", { layer: rest[0], name: rest.slice(1).join(" ") });
      console.log(`Renamed layer "${rest[0]}" to "${rest.slice(1).join(" ")}".`);
      return;
    }
    if (sub === "classic") {
      const oneSpace = rest.includes("--one-space");
      const result = await daemonCall("layers.classic", oneSpace ? { oneSpace: true } : {}) as any;
      console.log(result.gathering
        ? "Classic · one space: carrying windows from other desktops (see the bezel)."
        : "Classic: every window back, as if Lattices weren't running.");
      return;
    }
    if (sub === "undo") {
      const result = await daemonCall("layers.undo") as any;
      console.log(result.undone ? `Undid ${result.undone}.` : "Nothing to undo.");
      return;
    }
    if (sub === "exit" || sub === "off" || sub === "reveal" || sub === "show-all") {
      const result = await daemonCall(sub === "reveal" || sub === "show-all" ? "layers.reveal" : "layers.exit") as any;
      const unhidden: string[] = result.unhidden ?? [];
      const rescued: number = result.rescued ?? 0;
      console.log(`Layers off. Put back ${result.unparked} parked window${result.unparked === 1 ? "" : "s"}` +
        (rescued ? `, rescued ${rescued} stranded in the corner` : "") +
        (unhidden.length ? `, unhid ${unhidden.join(", ")}` : "") + ".");
      if (result.stillParked > 0) {
        console.log(`${result.stillParked} still waiting to restore. Lattices will retry when their desktop is shown; use \`lats layer exit\` to retry now.`);
      }
      if (result.stillHidden?.length) console.log(`Still hidden: ${result.stillHidden.join(", ")}. Use \`lats layer exit\` to retry.`);
      return;
    }
    if (sub === "delete" || sub === "rm") {
      if (!rest[0]) { console.log("Usage: lats layer delete <layer>"); return; }
      const result = await daemonCall("layers.delete", { layer: rest[0] }) as any;
      console.log(`Deleted layer "${result.label ?? rest[0]}" from workspace.json.`);
      return;
    }

    if (sub === undefined || sub === null || sub === "") {
      const result = await daemonCall("layers.list") as any;
      if (!result.layers.length) {
        console.log("No layers configured.");
        return;
      }
      // Window counts as Studio and the bezel count them; entries without.
      const members = await daemonCall("layers.members").catch(() => null) as any;
      console.log("Layers:\n");
      if (result.focusActive === false) console.log("  Layer focus is off. Select a layer to enter.\n");
      for (const line of layerListLines(result.layers, result.active, members ? layerWindowCounts(members) : undefined)) {
        console.log(line);
      }
      const parked = result.stage?.parked?.length ?? 0;
      const hidden: string[] = result.stage?.hidden ?? [];
      if (parked || hidden.length) {
        const parts = [];
        if (parked) parts.push(`${parked} window${parked === 1 ? "" : "s"} parked`);
        if (hidden.length) parts.push(`${hidden.join(", ")} hidden`);
        console.log(`\n  ${parts.join(" · ")} — \`lats layer exit\` restores windows and turns layer focus off`);
      }
      return;
    }
    // As ⌘⌥ switches; --tile lays the windows out again, --launch starts
    // what isn't running first.
    const mode = rest.includes("--launch") ? "launch" : rest.includes("--tile") ? "tile" : "focus";
    if (!target || "error" in target) return;
    if ("index" in target) {
      const list = await daemonCall("layers.list") as any;
      if (target.index >= (list.layers?.length ?? 0)) {
        console.error(`No layer on ⌘⌥${target.slot}.`);
        process.exit(1);
      }
    }
    await daemonCall("layers.activate", "index" in target ? { index: target.index, mode } : { name: target.name, mode });
    const name = "index" in target ? `⌘⌥${target.slot}` : `"${target.name}"`;
    console.log(mode === "focus" ? `Switched to layer ${name}` : `Switched to layer ${name} (${mode})`);
  });
}

/** The ⌘⌥ pad's slots in layer order; 5 is the pad's centre. */
export const PAD_SLOTS = [1, 2, 3, 4, 6, 7, 8, 9];

/** Layer `index`'s pad slot digit, undefined past the eighth layer. */
export function padSlot(index: number): number | undefined {
  return PAD_SLOTS[index];
}

export type LayerTarget =
  | { index: number; slot: number }
  | { name: string }
  | { error: string };

/** What `lats layer <arg>` switches to: a digit is a pad slot, as ⌘⌥
 *  takes it; anything else is a layer id or label. */
export function layerTarget(arg: string): LayerTarget {
  if (!/^\d+$/.test(arg)) return { name: arg };
  const slot = Number(arg);
  const index = PAD_SLOTS.indexOf(slot);
  if (index !== -1) return { index, slot };
  return slot === 5
    ? { error: "5 is the pad's centre; layers sit on 1-4 and 6-9." }
    : { error: `No slot ${arg}; layers sit on 1-4 and 6-9.` };
}

/** Each layer's window count from a `layers.members` result, by index. */
export function layerWindowCounts(members: { layers?: Array<{ index: number; entries?: Array<{ windows?: unknown[] }> }> }): Map<number, number> {
  const counts = new Map<number, number>();
  for (const layer of members.layers ?? []) {
    counts.set(layer.index, (layer.entries ?? []).reduce((n, entry) => n + (entry.windows?.length ?? 0), 0));
  }
  return counts;
}

/** The `lats layer` list: each layer by its pad slot, with its window
 *  count, or its entry count when `counts` is missing. */
export function layerListLines(
  layers: Array<{ index: number; label: string; projectCount?: number }>,
  active: number | null,
  counts?: Map<number, number>,
): string[] {
  const width = Math.max(0, ...layers.map((layer) => layer.label.length));
  return layers.map((layer) => {
    const slot = padSlot(layer.index) ?? "·";
    const count = counts
      ? countNote(counts.get(layer.index) ?? 0, "window")
      : countNote(layer.projectCount ?? 0, "entry", "entries");
    const mark = layer.index === active ? "  \x1b[32m● active\x1b[0m" : "";
    return `  [${slot}] ${layer.label.padEnd(width)}  ${count}${mark}`;
  });
}

function countNote(count: number, one: string, many = `${one}s`): string {
  return `${count === 0 ? "No" : count} ${count === 1 ? one : many}`;
}

// ── Layer create: save windows as a new ⌘⌥ layer in workspace.json ──
// Usage: lats layer create <name> [wid:123 wid:456 ...]
//        lats layer create <name> --json '[{"app":"Chrome","tile":"left"},...]'
// With no windows named, it saves the windows on screen.
export async function layerCreateCommand(client: DaemonClient, args: string[]): Promise<void> {
  const { daemonCall } = client;
  const name = args[0];
  if (!name) {
    console.log("Usage: lats layer create <name> [wid:123 ...] [--json '<specs>']");
    return;
  }

  const jsonIdx = args.indexOf("--json");
  if (jsonIdx !== -1 && args[jsonIdx + 1]) {
    // JSON mode: window specs, each by wid or by app + title, with an optional tile
    const specs = JSON.parse(args[jsonIdx + 1]) as Array<{
      wid?: number; app?: string; title?: string; tile?: string;
    }>;
    const windows = await daemonCall("windows.list") as any[];
    const picked: Array<{ wid: number; tile?: string }> = [];
    for (const spec of specs) {
      const wid = spec.wid ?? windows.find((w: any) =>
        spec.app && w.app.toLowerCase().includes(spec.app.toLowerCase())
          && (!spec.title || w.title.toLowerCase().includes(spec.title.toLowerCase())))?.wid;
      if (wid) picked.push({ wid, tile: spec.tile });
      else console.log(`  No window for ${spec.app ?? "?"}${spec.title ? ` "${spec.title}"` : ""}; skipped.`);
    }
    if (!picked.length) { console.log("No windows matched; nothing saved."); return; }

    const result = await daemonCall("layers.create", { name, windows: picked }) as any;
    console.log(`Saved layer "${result.label}"${slotNote(result.index)} with ${result.count} window(s).`);

    const tiles = picked.filter(p => p.tile);
    for (const t of tiles) {
      try {
        await daemonCall("windows.place", { wid: t.wid, placement: t.tile });
      } catch { /* the window may have closed */ }
    }
    if (tiles.length) console.log(`Tiled ${tiles.length} window(s).`);
    return;
  }

  const wids = parseWids(args.slice(1));
  const result = await daemonCall("layers.create", {
    name,
    ...(wids.length ? { windowIds: wids } : { visible: true }),
  }) as any;
  console.log(`Saved layer "${result.label}"${slotNote(result.index)} with ${result.count} window(s).`);
}

function slotNote(index: number): string {
  const slot = padSlot(index);
  return slot ? ` on ⌘⌥${slot}` : "";
}

// ── Layer snap: save the windows on screen as a new layer ─────────────
export async function layerSnapCommand(client: DaemonClient, name?: string): Promise<void> {
  const { daemonCall } = client;
  const layerName = name || `snap-${new Date().toISOString().slice(11, 19).replace(/:/g, "")}`;
  const result = await daemonCall("layers.create", { name: layerName, visible: true }) as any;
  if (!result.count) {
    console.log(`Saved layer "${result.label}", but no windows were on screen.`);
    return;
  }
  console.log(`Snapped ${result.count} window(s) → layer "${result.label}"${slotNote(result.index)}.`);
}

// ── Layer add: put windows in a layer (default: the one you're on) ────
// Usage: lats layer add wid:123 [wid:456 ...] [--to <layer>]
export async function layerAddCommand(client: DaemonClient, args: string[]): Promise<void> {
  const { daemonCall } = client;
  const toIdx = args.indexOf("--to");
  const layer = toIdx !== -1 ? args[toIdx + 1] : undefined;
  const wids = parseWids(args.filter((_, i) => toIdx === -1 || (i !== toIdx && i !== toIdx + 1)));
  if (!wids.length) {
    console.log("Usage: lats layer add wid:123 [wid:456 ...] [--to <layer>]");
    return;
  }
  const result = await daemonCall("layers.assign", { windowIds: wids, ...(layer ? { layer } : {}) }) as any;
  const list = await daemonCall("layers.list") as any;
  const label = list.layers?.[result.index]?.label ?? `#${result.index}`;
  const skipped = wids.length - result.added;
  console.log(`Added ${result.added} window(s) to "${label}"${skipped ? ` (${skipped} already in it)` : ""}.`);
}

function parseWids(args: string[]): number[] {
  return args
    .map(a => parseInt(a.startsWith("wid:") ? a.slice(4) : a, 10))
    .filter(n => !isNaN(n));
}
