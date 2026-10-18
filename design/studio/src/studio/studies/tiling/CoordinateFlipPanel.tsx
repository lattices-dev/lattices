"use client";

import { useRef, useState } from "react";
import { PanelHeading, ScreenMockup } from "./_shared";

const VIRTUAL_WIDTH = 1920;
const VIRTUAL_HEIGHT = 1200;
const MENU_BAR = 24;
const VISIBLE_HEIGHT = VIRTUAL_HEIGHT - MENU_BAR;

const INITIAL = { fx: 0.05, fy: 0.1, fw: 0.4, fh: 0.6 };

export function CoordinateFlipPanel() {
  const [rect, setRect] = useState(INITIAL);
  const mockupRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<{ originX: number; originY: number; startFx: number; startFy: number } | null>(null);

  function onPointerDown(event: React.PointerEvent) {
    if (!mockupRef.current) return;
    (event.target as HTMLElement).setPointerCapture(event.pointerId);
    dragRef.current = {
      originX: event.clientX,
      originY: event.clientY,
      startFx: rect.fx,
      startFy: rect.fy,
    };
    event.preventDefault();
  }

  function onPointerMove(event: React.PointerEvent) {
    const drag = dragRef.current;
    if (!drag || !mockupRef.current) return;
    const mockupRect = mockupRef.current.getBoundingClientRect();
    const dxFrac = (event.clientX - drag.originX) / mockupRect.width;
    const dyFrac = (event.clientY - drag.originY) / mockupRect.height;
    const nextFx = clamp(drag.startFx + dxFrac, 0, 1 - rect.fw);
    const nextFy = clamp(drag.startFy + dyFrac, 0.04, 1 - rect.fh);
    setRect((r) => ({ ...r, fx: nextFx, fy: nextFy }));
  }

  function onPointerUp(event: React.PointerEvent) {
    (event.target as HTMLElement).releasePointerCapture(event.pointerId);
    dragRef.current = null;
  }

  const visibleFy = (rect.fy - MENU_BAR / VIRTUAL_HEIGHT) / (VISIBLE_HEIGHT / VIRTUAL_HEIGHT);

  const cgX = Math.round(rect.fx * VIRTUAL_WIDTH);
  const cgY = Math.round(rect.fy * VIRTUAL_HEIGHT);
  const w = Math.round(rect.fw * VIRTUAL_WIDTH);
  const h = Math.round(rect.fh * VIRTUAL_HEIGHT);

  const nsScreenX = cgX;
  const nsScreenY = Math.round(VIRTUAL_HEIGHT - cgY - h);

  const axTop = MENU_BAR;
  const visibleFracY = clamp(visibleFy, 0, 1);
  const axY = Math.round(axTop + visibleFracY * VISIBLE_HEIGHT);
  const axX = Math.round(rect.fx * VIRTUAL_WIDTH);

  return (
    <section className="mt-14">
      <PanelHeading
        eyebrow="02 · coords"
        title="Three systems, two flips"
        caption="Drag the window — watch the same rect read out in NSScreen, CG, and AX coordinates."
      />

      <div className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div ref={mockupRef}>
          <ScreenMockup>
            <button
              type="button"
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerUp}
              onPointerCancel={onPointerUp}
              className="absolute cursor-grab touch-none rounded-[2px] active:cursor-grabbing"
              style={{
                left: `${rect.fx * 100}%`,
                top: `${rect.fy * 100}%`,
                width: `${rect.fw * 100}%`,
                height: `${rect.fh * 100}%`,
                background: "color-mix(in oklab, var(--scout-accent) 18%, transparent)",
                border: "1.5px solid var(--scout-accent)",
                boxShadow:
                  "0 0 0 1px color-mix(in oklab, var(--scout-accent) 25%, transparent), 0 6px 16px -8px rgba(0,0,0,0.5)",
              }}
              aria-label="Drag to reposition"
            >
              <span
                className="pointer-events-none absolute left-2 top-2 font-mono text-[9px] uppercase tracking-[0.18em]"
                style={{ color: "var(--scout-accent)" }}
              >
                window · drag me
              </span>
            </button>

            <div className="pointer-events-none absolute right-1.5 top-1.5 font-mono text-[8.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
              primary {VIRTUAL_WIDTH} × {VIRTUAL_HEIGHT}
            </div>
            <div className="pointer-events-none absolute left-1.5 top-[5%] font-mono text-[8.5px] text-studio-ink-faint">
              ⌐ menu bar {MENU_BAR}px
            </div>
          </ScreenMockup>
        </div>

        <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
          <CoordReadout
            label="NSScreen"
            hint="bottom-left origin · AppKit"
            x={nsScreenX}
            y={nsScreenY}
            w={w}
            h={h}
          />
          <Divider />
          <CoordReadout
            label="CG"
            hint="top-left origin · Quartz"
            x={cgX}
            y={cgY}
            w={w}
            h={h}
          />
          <Divider />
          <CoordReadout
            label="AX"
            hint="top-left · primary-screen anchor"
            x={axX}
            y={axY}
            w={w}
            h={h}
            highlight
          />
        </aside>
      </div>

      <div className="mt-6 rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          the flip
        </p>
        <pre className="mt-2 overflow-x-auto font-mono text-[12px] leading-[1.6] text-studio-ink">{`visible = screen.visibleFrame             // NSRect, bottom-left
primaryH = primary.frame.height
axTop   = primaryH - visible.maxY         // ← the flip
frame.y = axTop + visible.height × fy     // top-left AX y`}</pre>
        <p className="mt-3 font-mono text-[11px] text-studio-ink-faint">
          WindowTiler.swift:435 · WindowDragSnapController.swift:357
        </p>
      </div>
    </section>
  );
}

function CoordReadout({
  label,
  hint,
  x,
  y,
  w,
  h,
  highlight = false,
}: {
  label: string;
  hint: string;
  x: number;
  y: number;
  w: number;
  h: number;
  highlight?: boolean;
}) {
  return (
    <div>
      <div className="flex items-baseline justify-between">
        <span
          className="font-mono text-[11px] uppercase tracking-[0.18em]"
          style={{ color: highlight ? "var(--scout-accent)" : "var(--studio-ink-faint)" }}
        >
          {label}
        </span>
        <span className="font-mono text-[9.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
          {hint}
        </span>
      </div>
      <div className="mt-2 grid grid-cols-4 gap-2 font-mono text-[12px] tabular-nums text-studio-ink">
        <Cell label="x" value={x} />
        <Cell label="y" value={y} />
        <Cell label="w" value={w} />
        <Cell label="h" value={h} />
      </div>
    </div>
  );
}

function Cell({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
        {label}
      </span>
      <span>{value}</span>
    </div>
  );
}

function Divider() {
  return <div className="my-1 border-t border-studio-edge" />;
}

function clamp(n: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, n));
}
