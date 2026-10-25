import { AsyncLocalStorage } from "node:async_hooks";

const scope = new AsyncLocalStorage<{ signal: AbortSignal; expiresAt: number; expire: () => void }>();
const IO_TIMEOUT_MS = 10_000;
type JsonObject = Record<string, unknown>;

export class BrowserTimeoutError extends Error {}

export function checkDeadline(): void {
  const current = scope.getStore();
  if (current && performance.now() >= current.expiresAt) current.expire();
  current?.signal.throwIfAborted();
}

export function remainingTimeout(maxMs = IO_TIMEOUT_MS): number {
  checkDeadline();
  const current = scope.getStore();
  return current ? Math.max(1, Math.ceil(Math.min(maxMs, current.expiresAt - performance.now()))) : maxMs;
}

export async function withDeadline<T>(ms: number, label: string, work: () => Promise<T>): Promise<T> {
  checkDeadline();
  const controller = new AbortController();
  const expired = new BrowserTimeoutError(`${label} timed out after ${ms}ms`);
  const timer = setTimeout(() => controller.abort(expired), ms);
  if (ms === 0) controller.abort(expired);
  try {
    return await scope.run({ signal: controller.signal, expiresAt: performance.now() + ms, expire: () => controller.abort(expired) }, async () => {
      checkDeadline();
      const result = await boundedWait(work(), label, undefined, ms);
      checkDeadline();
      return result;
    });
  } finally {
    clearTimeout(timer);
    controller.abort(expired);
  }
}

/** Bound every I/O call even outside browser_open; inherit its overall budget. */
export function boundedWait<T>(work: Promise<T>, label: string, cancel?: () => void, maxMs = IO_TIMEOUT_MS): Promise<T> {
  const signal = scope.getStore()?.signal;
  return new Promise((resolve, reject) => {
    let done = false;
    const finish = (error?: unknown, value?: T) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      if (error !== undefined) {
        try { cancel?.(); } catch { /* Preserve the original failure. */ }
        reject(error);
      } else resolve(value as T);
    };
    const abort = () => finish(signal?.reason ?? new Error(`${label} cancelled`));
    const timer = setTimeout(() => finish(new BrowserTimeoutError(`${label} timed out after ${maxMs}ms`)), maxMs);
    work.then(value => finish(undefined, value), error => finish(error));
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
  });
}

export async function deadlineSleep(ms: number): Promise<void> {
  checkDeadline();
  let timer: ReturnType<typeof setTimeout>;
  await boundedWait(new Promise<void>(resolve => { timer = setTimeout(resolve, ms); }), "Browser wait", () => clearTimeout(timer));
}

export async function deadlineFetchJson<T>(url: string, init?: RequestInit): Promise<T> {
  checkDeadline();
  const controller = new AbortController();
  const signals = [controller.signal, ...(init?.signal ? [init.signal] : [])];
  return boundedWait((async () => {
    const response = await fetch(url, { ...init, signal: AbortSignal.any(signals) });
    if (!response.ok) throw new Error(`Chrome endpoint ${url} returned ${response.status}.`);
    return await response.json() as T;
  })(), `HTTP ${url}`, () => controller.abort());
}

export class CDPSession {
  private nextId = 1;
  private pending = new Map<number, { resolve: (value: JsonObject) => void; reject: (error: Error) => void }>();
  private listeners = new Map<string, Set<(params: JsonObject) => void>>();

  get isOpen(): boolean { return this.socket.readyState === WebSocket.OPEN; }

  private constructor(private socket: WebSocket) {
    socket.addEventListener("message", event => {
      let message: { id?: number; method?: string; params?: JsonObject; result?: JsonObject; error?: { message?: string } };
      try { message = JSON.parse(String(event.data)); } catch { this.close(); return; }
      if (!message.id) {
        if (message.method) this.emit(message.method, message.params ?? {});
        return;
      }
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(message.error.message ?? "Chrome DevTools command failed."));
      else waiter.resolve(message.result ?? {});
    });
    socket.addEventListener("close", () => this.rejectPending());
    socket.addEventListener("error", () => this.close());
  }

  static async connect(url: string): Promise<CDPSession> {
    checkDeadline();
    const socket = new WebSocket(url);
    try {
      await boundedWait(new Promise<void>((resolve, reject) => {
        socket.addEventListener("open", () => resolve(), { once: true });
        socket.addEventListener("error", () => reject(new Error("Could not connect to Chrome DevTools.")), { once: true });
        socket.addEventListener("close", () => reject(new Error("Chrome DevTools connection closed.")), { once: true });
      }), "Connect to Chrome DevTools", () => socket.close());
      return new CDPSession(socket);
    } catch (error) { socket.close(); throw error; }
  }

  async call(method: string, params: JsonObject = {}): Promise<JsonObject> {
    checkDeadline();
    if (this.socket.readyState !== WebSocket.OPEN) throw new Error("Chrome DevTools connection closed.");
    const id = this.nextId++;
    try {
      return await boundedWait(new Promise<JsonObject>((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        this.socket.send(JSON.stringify({ id, method, params }));
      }), `Chrome DevTools ${method}`, () => this.close());
    } finally { this.pending.delete(id); }
  }

  /**
   * Subscribe to a CDP event, returning an unsubscribe. Events were previously
   * dropped on the floor; settle conditions and console capture both need them,
   * and both need to stop listening cleanly when their wait ends.
   */
  on(method: string, handler: (params: JsonObject) => void): () => void {
    let handlers = this.listeners.get(method);
    if (!handlers) {
      handlers = new Set();
      this.listeners.set(method, handlers);
    }
    handlers.add(handler);
    return () => {
      handlers!.delete(handler);
      if (handlers!.size === 0) this.listeners.delete(method);
    };
  }

  private emit(method: string, params: JsonObject): void {
    const handlers = this.listeners.get(method);
    if (!handlers) return;
    // Copy first: a handler is allowed to unsubscribe itself.
    for (const handler of [...handlers]) {
      try {
        handler(params);
      } catch {
        // An observer must never break the command channel it rides on.
      }
    }
  }

  private rejectPending(): void {
    for (const waiter of this.pending.values()) waiter.reject(new Error("Chrome DevTools connection closed."));
    this.pending.clear();
  }

  close(): void {
    this.rejectPending();
    this.listeners.clear();
    this.socket.close();
  }
}
