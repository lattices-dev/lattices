"use client";

import { useEffect, useRef, useState } from "react";
import { useDaemonStatus } from "@/studio/lib/daemon";

const IS_DEV = process.env.NODE_ENV !== "production";
const AFFIRMATION_MS = 3500;

export function DaemonConnection() {
  const { status, lastChangeAt, burst } = useDaemonStatus();
  const [launchedAt, setLaunchedAt] = useState<number | null>(null);
  const [now, setNow] = useState(() => Date.now());

  // Tick the elapsed display once per second. Calm — no animation frames.
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  // When the daemon comes up, clear the "launching" marker.
  const lastStatus = useRef(status);
  useEffect(() => {
    if (lastStatus.current !== status) {
      if (status === "connected") {
        // keep launchedAt so we can show a brief "just started" affirmation
      }
      if (status === "disconnected" && lastStatus.current === "connected") {
        setLaunchedAt(null);
      }
      lastStatus.current = status;
    }
  }, [status]);

  function onStartClick() {
    setLaunchedAt(Date.now());
    burst();
  }

  if (status === "connected") {
    const startedRecently =
      launchedAt !== null && now - lastChangeAt < AFFIRMATION_MS && lastChangeAt >= launchedAt;
    const uptime = now - lastChangeAt;
    return (
      <div
        className={[
          "flex items-center justify-between gap-3 rounded-sm border px-4 py-2.5 transition-colors duration-500",
          startedRecently
            ? "border-[color:var(--status-ok-fg)] bg-[color:var(--status-ok-bg)]"
            : "border-studio-edge bg-[color:var(--studio-canvas)]",
        ].join(" ")}
      >
        <div className="flex items-center gap-3">
          <Dot color="var(--status-ok-fg)" pulse />
          <div className="flex items-baseline gap-3">
            <span className="font-mono text-[11px] uppercase tracking-[0.22em] text-studio-ink">
              {startedRecently ? "daemon · started" : "daemon · live"}
            </span>
            <span className="font-mono text-[10px] text-studio-ink-faint">
              up {formatDuration(uptime)}
            </span>
          </div>
        </div>
        <span className="font-mono text-[10px] text-studio-ink-faint">
          ws://127.0.0.1:9399
        </span>
      </div>
    );
  }

  if (status === "checking") {
    return (
      <div className="flex items-center gap-3 rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] px-4 py-2.5">
        <Dot color="var(--status-neutral-fg)" pulse />
        <span className="font-mono text-[11px] uppercase tracking-[0.22em] text-studio-ink-faint">
          probing daemon…
        </span>
      </div>
    );
  }

  // disconnected — either fresh or after click
  const launching = launchedAt !== null && now - launchedAt < 45_000;

  if (launching) {
    const elapsed = now - launchedAt!;
    return (
      <div className="flex items-center justify-between gap-3 rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] px-4 py-2.5">
        <div className="flex items-center gap-3">
          <Dot color="var(--scout-accent)" pulse />
          <div className="flex items-baseline gap-3">
            <span className="font-mono text-[11px] uppercase tracking-[0.22em] text-studio-ink">
              starting lattices…
            </span>
            <span className="font-mono text-[10px] text-studio-ink-faint tabular-nums">
              waited {formatDuration(elapsed)}
            </span>
          </div>
        </div>
        <span className="font-mono text-[10px] text-studio-ink-faint">
          burst polling
        </span>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3 rounded-sm border border-[color:var(--status-warn-fg)] bg-[color:var(--status-warn-bg)] p-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-center gap-3">
        <Dot color="var(--status-warn-fg)" />
        <div>
          <p className="font-mono text-[11px] uppercase tracking-[0.22em] text-studio-ink">
            daemon offline
          </p>
          <p className="mt-1 text-[12.5px] text-studio-ink-faint">
            Lattices isn't running. The studio can't talk to a daemon that
            isn't there.
          </p>
        </div>
      </div>
      {IS_DEV ? (
        <a
          href="lattices://daemon/start"
          onClick={onStartClick}
          className="inline-flex shrink-0 items-center gap-2 rounded-sm border border-studio-ink-faint bg-[color:var(--studio-canvas)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-studio-ink transition-colors hover:border-[color:var(--scout-accent)] hover:text-[color:var(--scout-accent)]"
        >
          ↗ start lattices
        </a>
      ) : (
        <span className="shrink-0 font-mono text-[10.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
          run <code className="font-mono text-studio-ink">lattices app</code>
        </span>
      )}
    </div>
  );
}

function Dot({ color, pulse = false }: { color: string; pulse?: boolean }) {
  return (
    <span
      className="relative inline-block"
      style={{ width: 8, height: 8 }}
      aria-hidden
    >
      {pulse ? (
        <span
          className="absolute inset-0 animate-ping rounded-full"
          style={{ background: color, opacity: 0.45 }}
        />
      ) : null}
      <span
        className="absolute inset-0 rounded-full"
        style={{ background: color }}
      />
    </span>
  );
}

function formatDuration(ms: number): string {
  const secs = Math.max(0, Math.floor(ms / 1000));
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ${secs % 60}s`;
  const hours = Math.floor(mins / 60);
  return `${hours}h ${mins % 60}m`;
}
