"use client";

import type { StudioStatus } from "@/studio/lib/engDocs";

type StatusTone = "info" | "ok" | "warn" | "neutral";

const palette: Record<StudioStatus, { tone: StatusTone; label: string }> = {
  proposed: { tone: "info", label: "PROPOSED" },
  accepted: { tone: "ok", label: "ACCEPTED" },
  "in-flight": { tone: "warn", label: "IN-FLIGHT" },
  shipped: { tone: "neutral", label: "SHIPPED" },
};

export function statusToColor(status: StudioStatus): string {
  return `var(--status-${palette[status].tone}-fg)`;
}

export function StatusPill({
  status,
  variant = "pill",
}: {
  status: StudioStatus;
  variant?: "pill" | "text";
}) {
  const item = palette[status];
  if (variant === "text") {
    return <span style={{ color: statusToColor(status) }}>{item.label}</span>;
  }
  return (
    <span
      className="inline-flex items-center rounded-sm border px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em]"
      style={{
        borderColor: `var(--status-${item.tone}-fg)`,
        background: `var(--status-${item.tone}-bg)`,
        color: `var(--status-${item.tone}-fg)`,
      }}
    >
      {item.label}
    </span>
  );
}
