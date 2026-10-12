import { withDaemon } from "./daemon.ts";

/** A display argument: its index, or part of its name. */
function displayArg(value: string): number | string {
  return /^\d+$/.test(value) ? Number(value) : value;
}

export async function displayCommand(sub?: string, ...rest: string[]): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    if (!sub || sub === "list" || sub === "ls") {
      const result = await daemonCall("displays.list", {}).catch(async error => {
        if (!(error as Error).message.includes("Unknown method")) throw error;
        const displays = await daemonCall("spaces.list") as any[];
        return {displays: displays.map(d => ({index: d.displayIndex, name: d.name ?? d.displayId,
          main: d.isMain, width: d.frame?.w, height: d.frame?.h, windows: d.spaces?.reduce((n: number, s: any) => n + (s.windowCount ?? s.windows?.length ?? 0), 0)}))};
      }) as any;
      for (const d of result.displays) {
        const main = d.main ? " (main)" : "";
        console.log(`  ${d.index}  ${d.name}${main}  ${d.width}×${d.height}  ${d.windows} window(s)`);
      }
      for (const g of result.gathered ?? []) {
        console.log(`  Gathered ${g.windows} window(s) off ${g.display}${g.here ? "" : " (not here)"} — lats display restore`);
      }
      return;
    }
    if (sub === "gather") {
      const toIdx = rest.indexOf("--to");
      const to = toIdx !== -1 ? rest[toIdx + 1] : undefined;
      const from = rest.find((_, i) => toIdx === -1 || (i !== toIdx && i !== toIdx + 1));
      if (!from) { console.log("Usage: lats display gather <display> [--to <display>]"); return; }
      const result = await daemonCall("display.gather", { display: displayArg(from), ...(to ? { to: displayArg(to) } : {}) }) as any;
      console.log(`Gathered ${result.moved} window(s) from ${result.from} onto ${result.to}.`);
      return;
    }
    if (sub === "restore") {
      const result = await daemonCall("display.restore", rest[0] ? { display: displayArg(rest[0]) } : {}) as any;
      if (!result.restored.length) { console.log("Nothing to put back."); return; }
      for (const r of result.restored) console.log(`Put ${r.moved} window(s) back on ${r.display}.`);
      return;
    }
    if (sub === "lend") {
      if (!rest[0]) { console.log("Usage: lats display lend <display>"); return; }
      const result = await daemonCall("display.lend", { display: displayArg(rest[0]) }) as any;
      console.log(result.asking ? `Asking where to gather ${result.name}'s windows.` : `Nothing on ${result.name} to gather.`);
      return;
    }
    console.log("Usage: lats display [list|gather <display> [--to <display>]|restore [display]|lend <display>]");
  });
}
