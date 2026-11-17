/** Shared shapes between the lattices MCP router and the toolsets it hosts. */

export type JsonObject = Record<string, unknown>;

export type JsonRpcRequest = {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: JsonObject;
};

export type ToolResult = {
  content: Array<
    | { type: "text"; text: string }
    | { type: "image"; data: string; mimeType: "image/png" | "image/jpeg" }
  >;
  structuredContent?: JsonObject;
  isError?: boolean;
};

/**
 * A failed tool call as a result the agent can read. A daemon or host error on
 * a mutation carries `delivery` (DaemonError), which says whether to resend.
 */
export function toolError(err: unknown): ToolResult {
  const message = err instanceof Error ? err.message : String(err);
  const delivery = (err as { delivery?: JsonObject } | null)?.delivery;
  if (!delivery) return { content: [{ type: "text", text: message }], isError: true };
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: false, error: message, delivery }, null, 2) }],
    structuredContent: { ok: false, error: message, delivery },
    isError: true,
  };
}

export type ToolDefinition = {
  name: string;
  title?: string;
  description: string;
  inputSchema: JsonObject;
  annotations?: JsonObject;
};

/**
 * A toolset is a domain that owns some tools and, usually, some resource whose
 * lifetime has to outlive a single call -- the browser toolset owns a Chrome
 * process. The router owns the protocol and the process; a toolset owns
 * everything below the framing.
 */
export type Toolset = {
  /** Registry key, e.g. `browser`. Selectable with `lats mcp --toolsets`. */
  name: string;
  title?: string;
  tools: readonly ToolDefinition[];
  /** Lines appended to the server's `initialize` instructions. */
  instructions?: readonly string[];
  /** Run once at startup, before the first request is served. */
  init?(): Promise<void>;
  /** Run before each of *this* toolset's calls -- not before another's. */
  onToolCall?(name: string): void;
  callTool(name: string, args: JsonObject): Promise<ToolResult>;
  /** Graceful release on shutdown. Must not exit the process. */
  shutdown?(reason: string): Promise<void>;
  /** Last-resort release from `process.on("exit")`, where nothing may await. */
  shutdownSync?(): void;
};
