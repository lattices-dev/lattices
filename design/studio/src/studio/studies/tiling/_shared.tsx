"use client";

import type { ReactNode } from "react";

export function PanelHeading({
  eyebrow,
  title,
  caption,
}: {
  eyebrow: string;
  title: string;
  caption?: string;
}) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-studio-edge pb-3">
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          {eyebrow}
        </span>
        <h2 className="font-mono text-base text-studio-ink">{title}</h2>
      </div>
      {caption ? (
        <p className="hidden max-w-md text-right text-xs text-studio-ink-faint sm:block">
          {caption}
        </p>
      ) : null}
    </div>
  );
}

export function MonoEyebrow({ children }: { children: ReactNode }) {
  return (
    <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
      {children}
    </p>
  );
}

export function ScreenMockup({
  children,
  aspect = "16 / 10",
  showMenuBar = true,
}: {
  children: ReactNode;
  aspect?: string;
  showMenuBar?: boolean;
}) {
  return (
    <div
      className="relative w-full overflow-hidden rounded-sm border border-studio-edge"
      style={{
        aspectRatio: aspect,
        background:
          "linear-gradient(135deg, color-mix(in oklab, var(--studio-canvas) 80%, white 4%), var(--studio-canvas))",
      }}
    >
      {showMenuBar ? (
        <div
          className="absolute inset-x-0 top-0 border-b border-studio-edge"
          style={{
            height: "4%",
            background:
              "linear-gradient(180deg, color-mix(in oklab, var(--studio-canvas) 88%, white 6%), transparent)",
          }}
        />
      ) : null}
      {children}
    </div>
  );
}

export function CodeReadout({ children }: { children: ReactNode }) {
  return (
    <pre className="overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11.5px] leading-[1.55] text-studio-ink">
      {children}
    </pre>
  );
}

export function hueFor(index: number, total: number): string {
  return `hsl(${Math.round(220 + (index / Math.max(total - 1, 1)) * 120)} 70% 65%)`;
}
