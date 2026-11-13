import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { BackendHost, type BackendHostOptions } from "./host.js";
import { cuaError, cuaHandlers, cuaTools } from "./tools.js";
import { BackendRefusal } from "./types.js";
import { readFileSync } from "node:fs";

/** The published package version; src/ and dist/ both sit one level below package.json. */
const VERSION = (JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version: string }).version;

export type ServeMcpOptions = {
  /** This server owns and disposes the supplied host when it shuts down. */
  host?: BackendHost;
  hostOptions?: BackendHostOptions;
};

/** Serve until stdin closes or a termination signal arrives. Stdout is MCP only. */
export async function serveMcp(opts: ServeMcpOptions = {}): Promise<void> {
  const log = (...args: unknown[]) => process.stderr.write(`[lattices-action] ${args.map(String).join(" ")}\n`);
  const host = opts.host ?? new BackendHost({ ...opts.hostOptions, log });
  const server = new Server({ name: "lattices-action", version: VERSION }, { capabilities: { tools: {} } });
  const handlers = cuaHandlers(host);
  const transport = new StdioServerTransport();
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: cuaTools(host) }));
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const name = request.params.name;
    if (!Object.hasOwn(handlers, name)) return cuaError(new BackendRefusal("unsupported", `Unknown tool ${JSON.stringify(name)}.`));
    return await handlers[name]!(request.params.arguments ?? {}, { signal: extra.signal, caller: "mcp" });
  });
  server.onerror = (error) => { log(error.message); };

  let finish!: () => void;
  const done = new Promise<void>((resolve) => { finish = resolve; });
  let closing: Promise<void> | undefined;
  const shutdown = (): Promise<void> => closing ??= Promise.resolve().then(async () => {
    process.stdin.off("end", stop);
    process.stdin.off("close", stop);
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    try {
      // Close transport first, so no new request can recreate a disposed backend.
      await server.close();
    } finally {
      try { await host.dispose(); } finally { finish(); }
    }
  });
  const stop = () => { void shutdown().catch((error: unknown) => { log(error); }); };
  server.onclose = stop;
  process.stdin.once("end", stop);
  process.stdin.once("close", stop);
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);

  try {
    await server.connect(transport);
    if (process.stdin.readableEnded || process.stdin.destroyed) stop();
    await done;
  } finally {
    await shutdown();
  }
}
