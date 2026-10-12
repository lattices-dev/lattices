import { withDaemon } from "./daemon.ts";

function when(iso: string): string {
  const d = new Date(iso);
  const ago = Math.round((Date.now() - d.getTime()) / 60000);
  const rel = ago < 60 ? `${ago}m ago` : ago < 2880 ? `${Math.round(ago / 60)}h ago` : `${Math.round(ago / 1440)}d ago`;
  return `${d.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}  ${rel.padStart(8)}`;
}

function flag(rest: string[], name: string): string | undefined {
  const i = rest.indexOf(name);
  return i !== -1 ? rest[i + 1] : undefined;
}

export async function stateCommand(sub?: string, ...rest: string[]): Promise<void> {
  await withDaemon(async ({ daemonCall }) => {
    if (!sub || sub === "list" || sub === "ls") {
      const since = flag(rest, "--since");
      const limit = flag(rest, "--limit");
      const result = await daemonCall("states.list", {
        ...(since ? { since } : {}),
        ...(limit ? { limit: Number(limit) } : {}),
        ...(rest.includes("--named") ? { named: true } : {}),
      }) as any;
      if (rest.includes("--json")) { console.log(JSON.stringify(result, null, 2)); return; }
      if (!result.states.length) { console.log("No states recorded."); return; }
      for (const s of result.states) {
        const name = s.name ? `  ${s.name}` : "";
        console.log(`  ${s.id.slice(0, 19)}  ${when(s.taken)}  ${s.displays}d ${String(s.desktops).padStart(2)} desktops ${String(s.windows).padStart(3)} windows${name}`);
      }
      if (result.total > result.states.length) console.log(`  … ${result.total} recorded`);
      return;
    }
    if (sub === "show") {
      const map = await daemonCall("states.get", rest[0] ? { id: rest[0] } : {}) as any;
      if (rest.includes("--json")) { console.log(JSON.stringify(map, null, 2)); return; }
      console.log(`${map.id}  ${when(map.taken)}${map.name ? `  ${map.name}` : ""}`);
      for (const d of map.displays) {
        const mine = map.windows.filter((w: any) => w.desktops.some((id: number) => d.desktops.includes(id)));
        console.log(`  ${d.name}${d.main ? " (main)" : ""}  ${d.frame.w}×${d.frame.h} at ${d.frame.x},${d.frame.y}  ${d.desktops.length} desktop(s), ${mine.length} window(s)`);
        d.desktops.forEach((id: number, i: number) => {
          const here = map.windows.filter((w: any) => w.desktops.includes(id));
          console.log(`    ${i + 1}${id === d.current ? "*" : " "} ${here.map((w: any) => w.app).join(", ") || "—"}`);
        });
      }
      return;
    }
    if (sub === "save") {
      const name = rest.join(" ").trim();
      if (!name) { console.log("Usage: lats state save <name>"); return; }
      const s = await daemonCall("states.save", { name }) as any;
      console.log(`Saved ${s.id}: ${s.windows} windows on ${s.desktops} desktops.`);
      return;
    }
    if (sub === "restore") {
      const ref = rest.find((a) => !a.startsWith("--"));
      if (!ref) { console.log("Usage: lats state restore <id|name> [--plan]"); return; }
      const plan = rest.includes("--plan");
      const r = await daemonCall("states.restore", { id: ref, plan }) as any;
      if (rest.includes("--json")) { console.log(JSON.stringify(r, null, 2)); return; }
      console.log(`${plan ? "Would restore" : "Restoring"} ${r.id}:`);
      if (!r.moves.length) console.log("  Everything is already where it was.");
      for (const m of r.moves) {
        const title = m.title ? ` — ${m.title.slice(0, 50)}` : "";
        console.log(`  ${m.app}${title}${m.carryTo ? "  (to another desktop)" : ""}`);
      }
      for (const m of r.missing) console.log(`  Not open: ${m}`);
      for (const n of r.notes) console.log(`  ${n}`);
      if (r.started) console.log("Undo with: lats state restore before-restore");
      return;
    }
    console.log("Usage: lats state [list [--since 2h] [--named] [--limit n] [--json]] | show [id] [--json] | save <name> | restore <id|name> [--plan]");
  });
}
