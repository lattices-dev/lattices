"use client";

import { useState } from "react";
import { hueFor, PanelHeading, ScreenMockup } from "./_shared";

function gridShape(count: number): number[] {
  switch (count) {
    case 1: return [1];
    case 2: return [2];
    case 3: return [3];
    case 4: return [2, 2];
    case 5: return [3, 2];
    case 6: return [3, 3];
    case 7: return [4, 3];
    case 8: return [4, 4];
    case 9: return [3, 3, 3];
    case 10: return [5, 5];
    case 11: return [4, 4, 3];
    case 12: return [4, 4, 4];
    default: {
      const cols = Math.ceil(Math.sqrt(count * 1.5));
      const rows: number[] = [];
      let remaining = count;
      while (remaining > 0) {
        rows.push(Math.min(cols, remaining));
        remaining -= cols;
      }
      return rows;
    }
  }
}

const MAX_COUNT = 20;
const TABLE_COUNTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

export function AutoGridPanel() {
  const [count, setCount] = useState(5);
  const shape = gridShape(count);
  const isLookup = count >= 1 && count <= 12;
  const totalCells = shape.reduce((acc, n) => acc + n, 0);

  const fallbackCols = Math.ceil(Math.sqrt(count * 1.5));

  return (
    <section className="mt-14">
      <PanelHeading
        eyebrow="01 · distribute"
        title="Auto-grid distributor"
        caption="Pick the prettiest grid for N windows."
      />

      <div className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <div className="flex flex-col gap-4">
          <div className="flex items-baseline gap-4">
            <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              N · windows
            </span>
            <span
              className="font-mono text-2xl text-studio-ink tabular-nums"
              style={{ minWidth: "2.5ch" }}
            >
              {count}
            </span>
            <input
              type="range"
              min={1}
              max={MAX_COUNT}
              value={count}
              onChange={(e) => setCount(Number(e.target.value))}
              className="flex-1 accent-[color:var(--scout-accent)]"
              aria-label="Window count"
            />
          </div>

          <ScreenMockup>
            <GridLayout shape={shape} />
          </ScreenMockup>
        </div>

        <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              {isLookup ? "lookup table · cases 1–12" : "fallback · sqrt(N · 1.5)"}
            </p>
            <p className="mt-1 font-mono text-[14px] text-studio-ink">
              [{shape.join(", ")}]
            </p>
            <p className="mt-1 text-xs text-studio-ink-faint">
              {shape.length === 1
                ? `${shape[0]} × 1 row`
                : `${shape.length} rows · ${totalCells} cells`}
            </p>
          </div>

          {!isLookup ? (
            <>
              <Divider />
              <div>
                <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                  derivation
                </p>
                <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11px] leading-[1.55] text-studio-ink">{`cols = ⌈√(${count} × 1.5)⌉ = ${fallbackCols}
rows = chunk(${count}, ${fallbackCols})
     = [${shape.join(", ")}]`}</pre>
              </div>
            </>
          ) : null}

          <Divider />

          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              swift
            </p>
            <p className="mt-1 font-mono text-[11px] text-studio-ink-faint">
              WindowTiler.gridShape(for:)
            </p>
            <p className="mt-0.5 font-mono text-[11px] text-studio-ink-faint">
              :1700
            </p>
          </div>
        </aside>
      </div>

      <div className="mt-6 grid grid-cols-3 gap-2 sm:grid-cols-4 lg:grid-cols-6">
        {TABLE_COUNTS.map((n) => (
          <button
            key={n}
            type="button"
            onClick={() => setCount(n)}
            aria-pressed={count === n}
            className={[
              "group flex flex-col gap-2 rounded-sm border bg-transparent p-2 text-left transition-colors",
              count === n
                ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)]"
                : "border-studio-edge hover:border-studio-ink-faint",
            ].join(" ")}
          >
            <div
              className="relative w-full overflow-hidden rounded-[2px] border border-studio-edge bg-[color:var(--studio-canvas)]"
              style={{ aspectRatio: "16 / 10" }}
            >
              <GridLayout shape={gridShape(n)} mini />
            </div>
            <div className="flex items-baseline justify-between gap-2">
              <span className="font-mono text-[11px] text-studio-ink">N={n}</span>
              <span className="font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
                [{gridShape(n).join(",")}]
              </span>
            </div>
          </button>
        ))}
      </div>
    </section>
  );
}

function GridLayout({ shape, mini = false }: { shape: number[]; mini?: boolean }) {
  const totalCells = shape.reduce((acc, n) => acc + n, 0);
  let cellIndex = 0;
  return (
    <div className="absolute inset-0 flex flex-col">
      {shape.map((cols, rowIdx) => (
        <div
          key={rowIdx}
          className="flex flex-1 border-b border-studio-edge last:border-b-0"
        >
          {Array.from({ length: cols }).map((_, colIdx) => {
            const idx = cellIndex++;
            const hue = hueFor(idx, totalCells);
            return (
              <div
                key={colIdx}
                className="flex flex-1 items-center justify-center border-r border-studio-edge last:border-r-0"
                style={{
                  background: `color-mix(in oklab, ${hue} 14%, transparent)`,
                  boxShadow: `inset 0 0 0 1px ${hue}`,
                }}
              >
                {!mini ? (
                  <span
                    className="font-mono text-[10px] uppercase tracking-[0.18em]"
                    style={{ color: hue }}
                  >
                    {idx + 1}
                  </span>
                ) : null}
              </div>
            );
          })}
        </div>
      ))}
    </div>
  );
}

function Divider() {
  return <div className="my-1 border-t border-studio-edge" />;
}
