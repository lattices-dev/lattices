"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export const DAEMON_WS_URL = "ws://127.0.0.1:9399";

export type DaemonStatus = "checking" | "connected" | "disconnected";

interface RpcResult<T = unknown> {
  id: string;
  result?: T;
  error?: string | null;
}

function nextId(): string {
  return Math.random().toString(36).slice(2, 10);
}

/**
 * One-shot RPC. Opens a fresh WS, sends the request, resolves with `result`
 * or rejects with the daemon error. Matches the Node client semantics.
 */
export function daemonCall<T = unknown>(
  method: string,
  params: Record<string, unknown> | null = null,
  timeoutMs = 4000,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const id = nextId();
    const socket = new WebSocket(DAEMON_WS_URL);

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try {
        socket.close();
      } catch {}
      reject(new Error(`Daemon ${method} timed out`));
    }, timeoutMs);

    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ id, method, params }));
    });

    socket.addEventListener("message", (event) => {
      if (settled) return;
      try {
        const data: RpcResult<T> = JSON.parse(event.data as string);
        if (data.id !== id) return;
        settled = true;
        clearTimeout(timer);
        socket.close();
        if (data.error) reject(new Error(data.error));
        else resolve(data.result as T);
      } catch (err) {
        settled = true;
        clearTimeout(timer);
        socket.close();
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });

    socket.addEventListener("error", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error("WebSocket error"));
    });

    socket.addEventListener("close", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error("Daemon connection closed before reply"));
    });
  });
}

/**
 * Lightweight liveness probe — opens a WS, resolves true on open, false on
 * error/timeout. Closes immediately. Cheaper than a real RPC.
 */
export function probeDaemon(timeoutMs = 1500): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    let settled = false;
    let socket: WebSocket;
    try {
      socket = new WebSocket(DAEMON_WS_URL);
    } catch {
      resolve(false);
      return;
    }
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try {
        socket.close();
      } catch {}
      resolve(false);
    }, timeoutMs);
    socket.addEventListener("open", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.close();
      resolve(true);
    });
    socket.addEventListener("error", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(false);
    });
  });
}

export interface DaemonMonitor {
  status: DaemonStatus;
  /** ms timestamp of the most recent status transition. */
  lastChangeAt: number;
  /**
   * Switch to fast polling for `burstMs` (default 30s). Calls this after the
   * user requested a start — the daemon usually shows up within ~1–2s, and
   * we want the UI to catch it on the next probe, not on the lazy cycle.
   */
  burst: (burstMs?: number) => void;
}

const SLOW_POLL_MS = 5000;
const LAZY_POLL_MS = 1500;
const BURST_POLL_MS = 350;
const DEFAULT_BURST_DURATION_MS = 30_000;

/**
 * React hook that polls the daemon. Returns status, the last-change
 * timestamp, and a `burst()` to temporarily tighten the cadence.
 */
export function useDaemonStatus(): DaemonMonitor {
  const [status, setStatus] = useState<DaemonStatus>("checking");
  const [lastChangeAt, setLastChangeAt] = useState<number>(() => Date.now());
  const cancelled = useRef(false);
  const burstUntil = useRef(0);
  const tickRef = useRef<() => void>(() => {});

  useEffect(() => {
    cancelled.current = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let lastStatus: DaemonStatus = "checking";

    async function tick() {
      const alive = await probeDaemon();
      if (cancelled.current) return;
      const next: DaemonStatus = alive ? "connected" : "disconnected";
      if (next !== lastStatus) {
        lastStatus = next;
        setStatus(next);
        setLastChangeAt(Date.now());
      }
      const inBurst = Date.now() < burstUntil.current;
      const delay = alive
        ? SLOW_POLL_MS
        : inBurst
          ? BURST_POLL_MS
          : LAZY_POLL_MS;
      timer = setTimeout(tick, delay);
    }

    tickRef.current = () => {
      if (timer) clearTimeout(timer);
      tick();
    };

    tick();

    return () => {
      cancelled.current = true;
      if (timer) clearTimeout(timer);
    };
  }, []);

  const burst = useCallback((burstMs = DEFAULT_BURST_DURATION_MS) => {
    burstUntil.current = Date.now() + burstMs;
    tickRef.current();
  }, []);

  return { status, lastChangeAt, burst };
}
