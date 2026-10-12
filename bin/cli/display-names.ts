import { withDaemon } from "./daemon.ts";

/** Resolve name-bearing display flags before the existing numeric parsers. */
export async function resolveDisplayNames(args: string[]): Promise<void> {
  if (args.some(a => ["--help", "-h", "help"].includes(a))) return;
  const positions: {index: number; prefix: string}[] = [];
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--display" && args[i + 1] && !args[i + 1].startsWith("--")) positions.push({index: ++i, prefix: ""});
    else if (args[i].startsWith("--display=")) positions.push({index: i, prefix: "--display="});
  }
  if (args[0] === "capture" && args[1] === "display" && args[2] && !args[2].startsWith("--")) positions.push({index: 2, prefix: ""});
  const named = positions.filter(p => !/^\d+$/.test(args[p.index].slice(p.prefix.length)));
  if (!named.length) return;
  await withDaemon(async ({ daemonCall }) => {
    const result = await daemonCall("displays.list").catch(async error => {
      if (!(error as Error).message.includes("Unknown method")) throw error;
      return {displays: await daemonCall("spaces.list")};
    }) as any;
    for (const {index, prefix} of named) {
      const query = args[index].slice(prefix.length).toLowerCase();
      const display = query && result.displays.find((d: any) => String(d.name ?? d.displayId ?? "").toLowerCase().includes(query));
      if (!display) throw new Error(`No display ${query}`);
      args[index] = prefix + String(display.index ?? display.displayIndex);
    }
  });
}
