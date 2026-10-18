"use client";

import { useMemo, useRef, useState } from "react";
import { PanelHeading, ScreenMockup } from "./_shared";

interface Zone {
  id: string;
  label: string;
  placement: string;
  trigger: { x: number; y: number; w: number; h: number };
  priority: number;
}

const ZONES: Zone[] = [
  {
    id: "left-edge",
    label: "Left",
    placement: "left",
    trigger: { x: 0.0, y: 0.18, w: 0.12, h: 0.64 },
    priority: 10,
  },
  {
    id: "top-left-corner",
    label: "Top-left",
    placement: "top-left",
    trigger: { x: 0.0, y: 0.04, w: 0.12, h: 0.18 },
    priority: 20,
  },
  {
    id: "top-edge",
    label: "Top",
    placement: "top",
    trigger: { x: 0.0, y: 0.04, w: 1.0, h: 0.08 },
    priority: 5,
  },
  {
    id: "notes-rail",
    label: "Notes",
    placement: "fractions(0.68, 0, 0.32, 1)",
    trigger: { x: 0.88, y: 0.18, w: 0.12, h: 0.64 },
    priority: 30,
  },
];

function area(z: Zone) {
  return z.trigger.w * z.trigger.h;
}

function contains(z: Zone, fx: number, fy: number) {
  return (
    fx >= z.trigger.x &&
    fx <= z.trigger.x + z.trigger.w &&
    fy >= z.trigger.y &&
    fy <= z.trigger.y + z.trigger.h
  );
}

export function SnapZonePanel() {
  const [cursor, setCursor] = useState<{ fx: number; fy: number } | null>({
    fx: 0.06,
    fy: 0.1,
  });
  const mockupRef = useRef<HTMLDivElement | null>(null);

  function onMove(event: React.PointerEvent) {
    if (!mockupRef.current) return;
    const rect = mockupRef.current.getBoundingClientRect();
    const fx = (event.clientX - rect.left) / rect.width;
    const fy = (event.clientY - rect.top) / rect.height;
    setCursor({ fx: clamp01(fx), fy: clamp01(fy) });
  }

  function onLeave() {
    setCursor(null);
  }

  const containing = useMemo(() => {
    if (!cursor) return [];
    return ZONES.filter((z) => contains(z, cursor.fx, cursor.fy));
  }, [cursor]);

  const winner = useMemo(() => {
    if (containing.length === 0) return null;
    const sorted = [...containing].sort((a, b) => {
      if (a.priority !== b.priority) return b.priority - a.priority;
      const aA = area(a);
      const bA = area(b);
      if (aA !== bA) return aA - bA;
      return a.id.localeCompare(b.id);
    });
    return sorted[0];
  }, [containing]);

  return (
    <section className="mt-14">
      <PanelHeading
        eyebrow="04 · snap"
        title="Zone resolver"
        caption="priority desc → area asc → id asc"
      />

      <div className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div ref={mockupRef}>
          <ScreenMockup>
            <div
              className="absolute inset-0 touch-none"
              onPointerMove={onMove}
              onPointerLeave={onLeave}
            >
              {ZONES.map((zone) => {
                const inside = cursor && contains(zone, cursor.fx, cursor.fy);
                const isWinner = winner?.id === zone.id;
                const baseColor = isWinner
                  ? "var(--scout-accent)"
                  : "var(--studio-ink-faint)";
                const bgAlpha = isWinner ? 18 : inside ? 8 : 4;
                return (
                  <div
                    key={zone.id}
                    className="absolute transition-colors"
                    style={{
                      left: `${zone.trigger.x * 100}%`,
                      top: `${zone.trigger.y * 100}%`,
                      width: `${zone.trigger.w * 100}%`,
                      height: `${zone.trigger.h * 100}%`,
                      background: `color-mix(in oklab, ${baseColor} ${bgAlpha}%, transparent)`,
                      border: `1px ${isWinner ? "solid" : "dashed"} ${baseColor}`,
                      pointerEvents: "none",
                    }}
                  >
                    <span
                      className="absolute left-1.5 top-1.5 font-mono text-[9px] uppercase tracking-[0.18em]"
                      style={{
                        color: baseColor,
                        opacity: isWinner ? 1 : inside ? 0.8 : 0.45,
                      }}
                    >
                      {zone.label} · P{zone.priority}
                    </span>
                  </div>
                );
              })}

              {cursor ? (
                <div
                  className="pointer-events-none absolute"
                  style={{
                    left: `${cursor.fx * 100}%`,
                    top: `${cursor.fy * 100}%`,
                    transform: "translate(-50%, -50%)",
                    width: 12,
                    height: 12,
                    borderRadius: "50%",
                    border: "1.5px solid var(--scout-accent)",
                    background:
                      "color-mix(in oklab, var(--scout-accent) 35%, transparent)",
                    boxShadow: "0 0 0 3px color-mix(in oklab, var(--scout-accent) 15%, transparent)",
                  }}
                />
              ) : null}
            </div>
          </ScreenMockup>
        </div>

        <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              winner
            </p>
            {winner ? (
              <>
                <p
                  className="mt-1 font-mono text-[15px]"
                  style={{ color: "var(--scout-accent)" }}
                >
                  {winner.label}
                </p>
                <p className="mt-0.5 font-mono text-[11px] text-studio-ink-faint">
                  → {winner.placement}
                </p>
              </>
            ) : (
              <p className="mt-1 font-mono text-[12px] text-studio-ink-faint">
                — none (cursor outside all zones)
              </p>
            )}
          </div>

          <Divider />

          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              candidates
            </p>
            <ul className="mt-2 space-y-1">
              {ZONES.map((zone) => {
                const inside = cursor && contains(zone, cursor.fx, cursor.fy);
                const isWinner = winner?.id === zone.id;
                return (
                  <li
                    key={zone.id}
                    className="flex items-baseline justify-between gap-2 font-mono text-[11.5px]"
                    style={{
                      color: isWinner
                        ? "var(--scout-accent)"
                        : inside
                          ? "var(--studio-ink)"
                          : "var(--studio-ink-faint)",
                    }}
                  >
                    <span className="truncate">{zone.id}</span>
                    <span className="shrink-0 tabular-nums">
                      P{zone.priority} · A{(area(zone) * 100).toFixed(1)}%
                    </span>
                  </li>
                );
              })}
            </ul>
          </div>

          <Divider />

          <p className="font-mono text-[10.5px] leading-relaxed text-studio-ink-faint">
            Hover the canvas. When triggers overlap, higher priority wins; ties
            broken by smaller trigger area (corners beat edges), then lex id.
          </p>

          <p className="font-mono text-[11px] text-studio-ink-faint">
            WindowDragSnapController.swift:292
          </p>
        </aside>
      </div>
    </section>
  );
}

function Divider() {
  return <div className="my-1 border-t border-studio-edge" />;
}

function clamp01(n: number) {
  return Math.max(0, Math.min(1, n));
}
