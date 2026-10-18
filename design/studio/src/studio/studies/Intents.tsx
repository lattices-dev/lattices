"use client";

import { useEffect, useMemo, useState } from "react";
import { daemonCall } from "@/studio/lib/daemon";
import type { LatticesPage } from "@/studio/studioRegistry";
import { DaemonConnection } from "@/studio/lib/DaemonConnection";

interface IntentSlot {
  name: string;
  type?: string;
  required?: boolean;
  description?: string;
}

interface IntentDef {
  name: string;
  description?: string;
  examples?: string[];
  slots?: IntentSlot[];
  category?: string;
}

interface SimulateResult {
  parsed: boolean;
  text: string;
  intent?: string | null;
  slots?: Record<string, unknown>;
  confidence?: number;
  executed?: boolean;
  result?: unknown;
  error?: string;
  message?: string;
}

interface ActiveProbe {
  phrase: string;
  status: "running" | "done" | "error";
  durationMs?: number;
  result?: SimulateResult;
  error?: string;
  executing?: boolean;
  execution?: SimulateResult;
  executionDurationMs?: number;
  executionError?: string;
}

interface IntentsStudyProps {
  entry: LatticesPage;
}

export function IntentsStudy({ entry }: IntentsStudyProps) {
  const [intents, setIntents] = useState<IntentDef[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [probe, setProbe] = useState<ActiveProbe | null>(null);

  useEffect(() => {
    let cancelled = false;
    daemonCall<IntentDef[]>("intents.list")
      .then((list) => {
        if (!cancelled) {
          setIntents(list);
          setLoadError(null);
        }
      })
      .catch((err: Error) => {
        if (!cancelled) setLoadError(err.message);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const filtered = useMemo(() => {
    if (!intents) return [];
    const f = filter.trim().toLowerCase();
    if (!f) return intents;
    return intents.filter((i) => {
      if (i.name.toLowerCase().includes(f)) return true;
      if (i.description?.toLowerCase().includes(f)) return true;
      if (i.examples?.some((e) => e.toLowerCase().includes(f))) return true;
      return false;
    });
  }, [intents, filter]);

  const totalPhrases = useMemo(
    () => intents?.reduce((acc, i) => acc + (i.examples?.length ?? 0), 0) ?? 0,
    [intents],
  );

  async function tryPhrase(phrase: string) {
    setProbe({ phrase, status: "running" });
    const t0 = performance.now();
    try {
      const result = await daemonCall<SimulateResult>("voice.simulate", {
        text: phrase,
        execute: false,
      });
      setProbe({
        phrase,
        status: "done",
        result,
        durationMs: Math.round(performance.now() - t0),
      });
    } catch (err) {
      setProbe({
        phrase,
        status: "error",
        error: err instanceof Error ? err.message : String(err),
        durationMs: Math.round(performance.now() - t0),
      });
    }
  }

  async function firePhrase() {
    if (!probe || probe.status !== "done" || !probe.result?.parsed) return;
    setProbe((p) => (p ? { ...p, executing: true } : p));
    const t0 = performance.now();
    try {
      const execution = await daemonCall<SimulateResult>("voice.simulate", {
        text: probe.phrase,
        execute: true,
      });
      setProbe((p) =>
        p
          ? {
              ...p,
              executing: false,
              execution,
              executionDurationMs: Math.round(performance.now() - t0),
            }
          : p,
      );
    } catch (err) {
      setProbe((p) =>
        p
          ? {
              ...p,
              executing: false,
              executionError: err instanceof Error ? err.message : String(err),
              executionDurationMs: Math.round(performance.now() - t0),
            }
          : p,
      );
    }
  }

  return (
    <main className="max-w-6xl px-6 py-8">
      <header>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          studio · intents
        </p>
        <h1 className="mt-2 font-sans text-4xl font-medium tracking-tight text-studio-ink sm:text-5xl">
          {entry.label}
        </h1>
        <p className="mt-4 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
          The closed set. Every phrase below is guaranteed to bind to an
          intent through Lattices' deterministic PhraseMatcher. Open-ended,
          messy, conversational language doesn't live here — that belongs to{" "}
          <a
            href="/studio/studies/handsoff"
            className="underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
          >
            Handsoff
          </a>
          .
        </p>
      </header>

      <section className="mt-8">
        <DaemonConnection />
      </section>

      <section className="mt-10">
        <Stats intents={intents} totalPhrases={totalPhrases} loadError={loadError} />
        <div className="mt-4">
          <input
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="filter by intent, phrase, or description…"
            spellCheck={false}
            className="w-full rounded-sm border border-studio-edge bg-transparent px-3 py-2 font-mono text-[12.5px] text-studio-ink outline-none focus:border-[color:var(--scout-accent)]"
          />
        </div>
      </section>

      <div className="mt-8 grid gap-6 lg:grid-cols-[minmax(0,1fr)_340px]">
        <Catalog
          intents={filtered}
          loadError={loadError}
          activePhrase={probe?.phrase ?? null}
          onPhrase={tryPhrase}
        />
        <div className="lg:sticky lg:top-6 lg:self-start">
          <Inspector probe={probe} onFire={firePhrase} />
        </div>
      </div>

      <footer className="mt-20 border-t border-studio-edge pt-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          source · IntentEngine.swift · PhraseMatcher.swift · LatticesApi.swift (intents.list / voice.simulate)
        </p>
      </footer>
    </main>
  );
}

function Stats({
  intents,
  totalPhrases,
  loadError,
}: {
  intents: IntentDef[] | null;
  totalPhrases: number;
  loadError: string | null;
}) {
  if (loadError) {
    return (
      <p className="font-mono text-[11px] text-[color:var(--status-error-fg)]">
        intents.list failed: {loadError}
      </p>
    );
  }
  if (!intents) {
    return (
      <p className="font-mono text-[11px] text-studio-ink-faint">
        loading intents…
      </p>
    );
  }
  return (
    <div className="flex flex-wrap items-baseline gap-6 border-b border-studio-edge pb-4">
      <Stat label="intents" value={String(intents.length).padStart(2, "0")} />
      <Stat label="example phrases" value={String(totalPhrases).padStart(2, "0")} />
      <span
        className="font-mono text-[10px] uppercase tracking-[0.22em]"
        style={{ color: "var(--scout-accent)" }}
      >
        guaranteed to bind
      </span>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {label}
      </span>
      <span className="font-mono text-2xl text-studio-ink tabular-nums">{value}</span>
    </div>
  );
}

function Catalog({
  intents,
  loadError,
  activePhrase,
  onPhrase,
}: {
  intents: IntentDef[];
  loadError: string | null;
  activePhrase: string | null;
  onPhrase: (p: string) => void;
}) {
  if (loadError) {
    return (
      <p className="font-mono text-[11px] text-studio-ink-faint">
        — connect to the daemon to load the intent catalog
      </p>
    );
  }
  if (!intents.length) {
    return (
      <p className="font-mono text-[11px] text-studio-ink-faint">
        no intents match the filter
      </p>
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {intents.map((intent) => (
        <IntentCard
          key={intent.name}
          intent={intent}
          activePhrase={activePhrase}
          onPhrase={onPhrase}
        />
      ))}
    </ul>
  );
}

function IntentCard({
  intent,
  activePhrase,
  onPhrase,
}: {
  intent: IntentDef;
  activePhrase: string | null;
  onPhrase: (p: string) => void;
}) {
  return (
    <li className="rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
      <div className="flex items-baseline justify-between gap-3">
        <h3
          className="font-mono text-[14px]"
          style={{ color: "var(--scout-accent)" }}
        >
          {intent.name}
        </h3>
        {intent.slots && intent.slots.length ? (
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            {intent.slots.length} slot{intent.slots.length === 1 ? "" : "s"}
          </span>
        ) : null}
      </div>
      {intent.description ? (
        <p className="mt-2 text-[13px] leading-relaxed text-studio-ink-faint">
          {intent.description}
        </p>
      ) : null}

      {intent.examples && intent.examples.length ? (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {intent.examples.map((example) => {
            const active = example === activePhrase;
            return (
              <button
                key={example}
                type="button"
                onClick={() => onPhrase(example)}
                className={[
                  "rounded-full border px-2.5 py-1 font-mono text-[10.5px] transition-colors",
                  active
                    ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-[color:var(--scout-accent)]"
                    : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                ].join(" ")}
              >
                {example}
              </button>
            );
          })}
        </div>
      ) : (
        <p className="mt-3 font-mono text-[10.5px] text-studio-ink-faint">
          — no example phrases registered
        </p>
      )}

      {intent.slots && intent.slots.length ? (
        <div className="mt-4 border-t border-studio-edge pt-3">
          <p className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
            slots
          </p>
          <dl className="mt-2 grid gap-1 sm:grid-cols-2">
            {intent.slots.map((slot) => (
              <div
                key={slot.name}
                className="flex items-baseline justify-between gap-2"
              >
                <dt className="font-mono text-[11.5px] text-studio-ink">
                  {slot.name}
                  {slot.required ? (
                    <span
                      className="ml-1 text-[9px]"
                      style={{ color: "var(--scout-accent)" }}
                    >
                      *
                    </span>
                  ) : null}
                </dt>
                <dd className="font-mono text-[10px] text-studio-ink-faint">
                  {slot.type ?? "—"}
                </dd>
              </div>
            ))}
          </dl>
        </div>
      ) : null}
    </li>
  );
}

function Inspector({
  probe,
  onFire,
}: {
  probe: ActiveProbe | null;
  onFire: () => void;
}) {
  if (!probe) {
    return (
      <aside className="rounded-sm border border-dashed border-studio-edge bg-transparent p-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          inspector
        </p>
        <p className="mt-3 font-mono text-[12px] text-studio-ink-faint leading-relaxed">
          Click any phrase to bind it through the matcher and see what it
          resolves to.
        </p>
      </aside>
    );
  }

  return (
    <aside className="flex flex-col gap-3 rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          phrase
        </p>
        <p className="mt-1 break-words font-mono text-[13px] text-studio-ink">
          "{probe.phrase}"
        </p>
        {probe.durationMs !== undefined ? (
          <p className="mt-1 font-mono text-[10px] text-studio-ink-faint">
            {probe.durationMs}ms · voice.simulate(execute:false)
          </p>
        ) : null}
      </div>

      <Divider />

      {probe.status === "running" ? (
        <p className="font-mono text-[11px] text-studio-ink-faint">probing…</p>
      ) : probe.status === "error" ? (
        <p className="font-mono text-[11.5px] text-[color:var(--status-error-fg)]">
          {probe.error}
        </p>
      ) : probe.result?.parsed ? (
        <>
          <div className="flex items-baseline justify-between gap-2">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              matched
            </p>
            <span
              className="rounded-[3px] px-1.5 py-0.5 font-mono text-[9px] font-semibold uppercase tracking-[0.18em]"
              style={{
                color: "var(--status-ok-fg)",
                background: "var(--status-ok-bg)",
              }}
            >
              bind
            </span>
          </div>
          <Row label="intent">
            <span
              className="font-mono text-[12px]"
              style={{ color: "var(--scout-accent)" }}
            >
              {probe.result.intent}
            </span>
          </Row>
          {probe.result.confidence !== undefined ? (
            <Row label="confidence">
              <span className="font-mono text-[12px] text-studio-ink tabular-nums">
                {Math.round(probe.result.confidence * 100)}%
              </span>
            </Row>
          ) : null}
          {probe.result.slots && Object.keys(probe.result.slots).length ? (
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                slots
              </p>
              <div className="mt-2 flex flex-col gap-1">
                {Object.entries(probe.result.slots).map(([k, v]) => (
                  <Row key={k} label={k}>
                    <span className="font-mono text-[11.5px] text-studio-ink">
                      {typeof v === "string" ? v : JSON.stringify(v)}
                    </span>
                  </Row>
                ))}
              </div>
            </div>
          ) : null}

          <Divider />

          <button
            type="button"
            onClick={onFire}
            disabled={probe.executing}
            className="rounded-sm border border-[color:var(--scout-accent)] bg-[color:var(--studio-canvas)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[color:var(--scout-accent)] transition-colors hover:bg-[color:var(--studio-edge)] disabled:opacity-50"
          >
            {probe.executing ? "firing…" : "↗ fire it"}
          </button>

          {probe.execution ? (
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                result ·{" "}
                <span
                  style={{
                    color: probe.execution.executed
                      ? "var(--status-ok-fg)"
                      : "var(--status-warn-fg)",
                  }}
                >
                  {probe.execution.executed ? "executed" : "not executed"}
                </span>
                {probe.executionDurationMs !== undefined
                  ? ` · ${probe.executionDurationMs}ms`
                  : ""}
              </p>
              <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-2 font-mono text-[11px] leading-[1.5] text-studio-ink">
                {JSON.stringify(probe.execution, null, 2)}
              </pre>
            </div>
          ) : probe.executionError ? (
            <p className="font-mono text-[11.5px] text-[color:var(--status-error-fg)]">
              {probe.executionError}
            </p>
          ) : null}
        </>
      ) : (
        <p className="font-mono text-[11.5px] text-studio-ink-faint">
          no match · {probe.result?.message ?? "the matcher didn't bind"}
        </p>
      )}
    </aside>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-studio-edge py-1.5 last:border-b-0">
      <span className="font-mono text-[9.5px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {label}
      </span>
      <span className="min-w-0 text-right">{children}</span>
    </div>
  );
}

function Divider() {
  return <div className="border-t border-studio-edge" />;
}
