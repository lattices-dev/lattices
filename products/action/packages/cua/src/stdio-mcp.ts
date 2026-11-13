import { spawn, type ChildProcess } from "node:child_process";
import type { McpClient, McpToolResult, StdioMcpOptions } from "./types.js";

type Pending = { resolve: (value: any) => void; reject: (error: Error) => void; cleanup: () => void };

/**
 * A small MCP stdio client for backend drivers. It answers ping, and answers
 * elicitation/create only when the caller supplies a handler; every other
 * server request is refused. The child stays in Action's process group, so it
 * goes away with the MCP server.
 */
export class StdioMcpClient implements McpClient {
  serverInfo: { name?: string; version?: string } | null = null;
  private child: ChildProcess;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private closed: Error | null = null;
  private label: string;

  constructor(private options: StdioMcpOptions, private log: (...args: unknown[]) => void = () => {}) {
    this.label = options.command.split("/").pop() ?? options.command;
    this.child = spawn(options.command, options.args ?? [], {
      env: { ...process.env, ...(options.env ?? {}) } as Record<string, string>,
      cwd: options.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout!.setEncoding("utf8");
    this.child.stdout!.on("data", (chunk: string) => this.onData(chunk));
    this.child.stderr!.setEncoding("utf8");
    this.child.stderr!.on("data", (chunk: string) => this.log(`${this.label} stderr:`, chunk.trim().slice(0, 500)));
    this.child.on("exit", (code, signal) => this.failAll(new Error(`${this.label} exited (${code ?? signal})`)));
    this.child.on("error", (error) => this.failAll(error));
  }

  async initialize(): Promise<this> {
    const result = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: this.options.onElicitation ? { elicitation: { form: {} } } : {},
      clientInfo: { name: "action-computer-backend", version: "1" },
    }, this.options.timeoutMs ?? 120_000, this.options.signal);
    this.serverInfo = result?.serverInfo ?? null;
    this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    return this;
  }

  async listTools(opts: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<Array<{ name: string; description?: string }>> {
    const result = await this.request("tools/list", {}, opts.timeoutMs ?? this.options.timeoutMs ?? 30_000, opts.signal);
    return Array.isArray(result?.tools) ? result.tools : [];
  }

  async callTool(name: string, args: Record<string, unknown> = {}, opts: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<McpToolResult> {
    return await this.request("tools/call", { name, arguments: args }, opts.timeoutMs ?? this.options.timeoutMs ?? 30_000, opts.signal);
  }

  close(): void {
    this.failAll(new Error("closed"));
    try { this.child.stdin?.end(); } catch {}
    this.child.kill("SIGTERM");
    const child = this.child;
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 2_000).unref?.();
  }

  private send(message: unknown) {
    if (this.closed) throw this.closed;
    this.child.stdin!.write(`${JSON.stringify(message)}\n`);
  }

  private failAll(error: Error) {
    this.closed ??= error;
    for (const [id, entry] of this.pending) {
      entry.cleanup();
      entry.reject(error);
      this.pending.delete(id);
    }
  }

  private onData(chunk: string) {
    this.buffer += chunk;
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message: any;
      try { message = JSON.parse(line); } catch { continue; }
      if (typeof message.method === "string" && message.id !== undefined) {
        this.onServerRequest(message);
        continue;
      }
      if (typeof message.method === "string") continue; // notifications
      const entry = this.pending.get(message.id);
      if (!entry) continue;
      this.pending.delete(message.id);
      entry.cleanup();
      if (message.error) entry.reject(new Error(message.error.message ?? "MCP error"));
      else entry.resolve(message.result);
    }
  }

  private onServerRequest(message: { id: number | string; method: string; params?: any }) {
    if (message.method === "ping") return this.send({ jsonrpc: "2.0", id: message.id, result: {} });
    if (message.method === "elicitation/create" && this.options.onElicitation) {
      const answer = this.options.onElicitation(message.params ?? {});
      this.log(`elicitation ${answer ? "accepted" : "declined"}: ${String(message.params?.message ?? "").slice(0, 120)}`);
      return this.send({
        jsonrpc: "2.0",
        id: message.id,
        result: answer ? { action: "accept", content: answer.content ?? {}, ...(answer._meta ? { _meta: answer._meta } : {}) } : { action: "decline" },
      });
    }
    this.send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `unsupported: ${message.method}` } });
  }

  private request(method: string, params: unknown, timeoutMs: number, signal?: AbortSignal): Promise<any> {
    if (this.closed) return Promise.reject(this.closed);
    if (signal?.aborted) return Promise.reject(new Error(`${this.label} ${method} aborted`));
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        cleanup();
        reject(new Error(`${this.label} ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      const onAbort = () => {
        if (!this.pending.delete(id)) return;
        cleanup();
        reject(new Error(`${this.label} ${method} aborted`));
      };
      const cleanup = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
      };
      this.pending.set(id, { resolve, reject, cleanup });
      signal?.addEventListener("abort", onAbort, { once: true });
      try {
        this.send({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        this.pending.delete(id);
        cleanup();
        reject(error as Error);
      }
    });
  }
}

export async function stdioMcp(options: StdioMcpOptions, log?: (...args: unknown[]) => void): Promise<McpClient> {
  options.signal?.throwIfAborted();
  const client = new StdioMcpClient(options, log);
  try {
    return await client.initialize();
  } catch (error) {
    client.close();
    throw error;
  }
}
