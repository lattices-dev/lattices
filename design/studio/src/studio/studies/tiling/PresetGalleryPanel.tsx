"use client";

import { useMemo, useState } from "react";
import {
  COMPOSED_LAYOUTS,
  formatFraction,
  formatPct,
  parseGrid,
  SPECIAL_PRESETS,
  TILE_FAMILIES,
  findPreset,
  type ComposedLayout,
  type Rect,
  type TilePreset,
} from "@/studio/lib/tiling";
import { PanelHeading, ScreenMockup } from "./_shared";

type Selection =
  | { kind: "preset"; preset: TilePreset }
  | { kind: "composed"; layout: ComposedLayout }
  | { kind: "custom"; rect: Rect; cols: number; rows: number; col: number; row: number };

const DEFAULT_SELECTION: Selection = {
  kind: "preset",
  preset: findPreset("bottom-right")!,
};

export function PresetGalleryPanel() {
  const [selection, setSelection] = useState<Selection>(DEFAULT_SELECTION);
  const [customInput, setCustomInput] = useState("");
  const [customError, setCustomError] = useState<string | null>(null);

  const parsedCustom = useMemo(
    () => (customInput.trim() ? parseGrid(customInput) : null),
    [customInput],
  );

  function onCustomChange(value: string) {
    setCustomInput(value);
    if (!value.trim()) {
      setCustomError(null);
      return;
    }
    const parsed = parseGrid(value);
    if (!parsed) {
      setCustomError("Expected CxR:c,r (starts at 1) or grid:CxR:c,r (starts at 0) — e.g. 5x3:2,1");
      return;
    }
    setCustomError(null);
    setSelection({
      kind: "custom",
      rect: parsed.rect,
      cols: parsed.cols,
      rows: parsed.rows,
      col: parsed.col,
      row: parsed.row,
    });
  }

  return (
    <>
      <PanelHeading
        eyebrow="presets · catalog"
        title="Every named placement"
        caption="Each cell is a real preset. Click to see the math."
      />

      <section className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <ScreenPreview selection={selection} />
        <Inspector selection={selection} />
      </section>

      <section className="mt-12">
        <div className="flex items-baseline justify-between border-b border-studio-edge pb-3">
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            custom grid · CxR:c,r starts at 1
          </span>
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            daemon also accepts grid:CxR:c,r from 0
          </span>
        </div>
        <div className="mt-4 flex items-stretch gap-3">
          <input
            value={customInput}
            onChange={(event) => onCustomChange(event.target.value)}
            placeholder="5x3:1,2"
            spellCheck={false}
            className="flex-1 rounded-sm border border-studio-edge bg-transparent px-3 py-2 font-mono text-[13px] text-studio-ink outline-none focus:border-[color:var(--scout-accent)]"
          />
          {parsedCustom ? (
            <div className="flex items-center font-mono text-[11px] text-studio-ink-faint">
              {parsedCustom.cols} × {parsedCustom.rows} → ({parsedCustom.col},{" "}
              {parsedCustom.row})
            </div>
          ) : null}
        </div>
        {customError ? (
          <p className="mt-2 font-mono text-[11px] text-[color:var(--status-error-fg)]">
            {customError}
          </p>
        ) : null}
      </section>

      <section className="mt-14">
        <SectionHeading
          eyebrow="Specials"
          title="One-of-one placements"
          caption="Not grid cells — bespoke fractional rectangles."
        />
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          {SPECIAL_PRESETS.map((preset) => (
            <PresetCard
              key={preset.name}
              preset={preset}
              active={
                selection.kind === "preset" &&
                selection.preset.name === preset.name
              }
              onClick={() => setSelection({ kind: "preset", preset })}
            />
          ))}
        </div>
      </section>

      {TILE_FAMILIES.map((fam) => (
        <section key={fam.key} className="mt-14">
          <SectionHeading
            eyebrow={fam.caption}
            title={fam.label}
            caption={fam.blurb}
          />
          <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {fam.presets.map((preset) => (
              <PresetCard
                key={preset.name}
                preset={preset}
                active={
                  selection.kind === "preset" &&
                  selection.preset.name === preset.name
                }
                onClick={() => setSelection({ kind: "preset", preset })}
              />
            ))}
          </div>
        </section>
      ))}

      <section className="mt-14">
        <SectionHeading
          eyebrow="Composed"
          title="Multi-window layouts"
          caption="Each preview is multiple tile_window actions tiled together."
        />
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
          {COMPOSED_LAYOUTS.map((layout) => (
            <ComposedCard
              key={layout.key}
              layout={layout}
              active={
                selection.kind === "composed" && selection.layout.key === layout.key
              }
              onClick={() => setSelection({ kind: "composed", layout })}
            />
          ))}
        </div>
      </section>
    </>
  );
}

function SectionHeading({
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

function ScreenPreview({ selection }: { selection: Selection }) {
  return (
    <ScreenMockup>{renderHighlights(selection)}</ScreenMockup>
  );
}

function renderHighlights(selection: Selection) {
  if (selection.kind === "preset") {
    return <RectHighlight rect={selection.preset.rect} label={selection.preset.name} />;
  }
  if (selection.kind === "custom") {
    return (
      <RectHighlight
        rect={selection.rect}
        label={compactGridLabel(selection.cols, selection.rows, selection.col, selection.row)}
      />
    );
  }
  return (
    <>
      {selection.layout.members.map((name, idx) => {
        const preset = findPreset(name);
        if (!preset) return null;
        return (
          <RectHighlight
            key={name}
            rect={preset.rect}
            label={name}
            stacked
            index={idx}
            total={selection.layout.members.length}
          />
        );
      })}
    </>
  );
}

function compactGridLabel(cols: number, rows: number, col: number, row: number) {
  return `${cols}x${rows}:${col + 1},${row + 1}`;
}

function RectHighlight({
  rect,
  label,
  stacked = false,
  index = 0,
  total = 1,
}: {
  rect: Rect;
  label: string;
  stacked?: boolean;
  index?: number;
  total?: number;
}) {
  const hue = stacked
    ? `hsl(${Math.round(220 + (index / Math.max(total - 1, 1)) * 120)} 70% 65%)`
    : "var(--scout-accent)";
  return (
    <div
      className="absolute transition-[left,top,width,height] duration-300 ease-out"
      style={{
        left: `${rect.x * 100}%`,
        top: `${rect.y * 100}%`,
        width: `${rect.w * 100}%`,
        height: `${rect.h * 100}%`,
        background: `color-mix(in oklab, ${hue} 14%, transparent)`,
        border: `1.5px solid ${hue}`,
        boxShadow: stacked
          ? "none"
          : `0 0 0 1px color-mix(in oklab, ${hue} 25%, transparent)`,
      }}
    >
      <span
        className="absolute left-1.5 top-1.5 rounded-sm px-1 py-0.5 font-mono text-[9px] uppercase tracking-[0.18em]"
        style={{
          color: hue,
          background: "color-mix(in oklab, var(--studio-canvas) 80%, transparent)",
        }}
      >
        {label}
      </span>
    </div>
  );
}

function Inspector({ selection }: { selection: Selection }) {
  if (selection.kind === "composed") {
    return <ComposedInspector selection={selection} />;
  }
  return <SingleInspector selection={selection} />;
}

function SingleInspector({
  selection,
}: {
  selection: Extract<Selection, { kind: "preset" } | { kind: "custom" }>;
}) {
  const rect =
    selection.kind === "preset" ? selection.preset.rect : selection.rect;
  const name =
    selection.kind === "preset"
      ? selection.preset.name
      : compactGridLabel(selection.cols, selection.rows, selection.col, selection.row);
  const grid =
    selection.kind === "preset"
      ? selection.preset.grid
      : { cols: selection.cols, rows: selection.rows };
  const cell =
    selection.kind === "preset" ? selection.preset.cell : { col: selection.col, row: selection.row };
  const description =
    selection.kind === "preset" ? selection.preset.description : undefined;

  const placementJson =
    selection.kind === "preset" && selection.preset.family !== "special"
      ? JSON.stringify(
          { method: "window.place", params: { placement: name } },
          null,
          2,
        )
      : JSON.stringify(
          { method: "window.place", params: { placement: rect } },
          null,
          2,
        );

  return (
    <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          preset
        </p>
        <p className="mt-1 break-words font-mono text-[15px] text-studio-ink">
          {name}
        </p>
        {description ? (
          <p className="mt-1 text-xs leading-relaxed text-studio-ink-faint">
            {description}
          </p>
        ) : null}
      </div>

      <Divider />

      <DataRow label="Grid">
        <span className="font-mono text-[12px] text-studio-ink">
          {grid.cols} × {grid.rows}
        </span>
      </DataRow>
      {cell ? (
        <DataRow label="Cell">
          <span className="font-mono text-[12px] text-studio-ink">
            ({cell.col}, {cell.row})
          </span>
        </DataRow>
      ) : null}
      <DataRow label="Fractions">
        <span className="font-mono text-[12px] text-studio-ink">
          {formatFraction(rect.x)}, {formatFraction(rect.y)}, {formatFraction(rect.w)}, {formatFraction(rect.h)}
        </span>
      </DataRow>
      <DataRow label="Pct">
        <span className="font-mono text-[12px] text-studio-ink-faint">
          {formatPct(rect.x)} · {formatPct(rect.y)} · {formatPct(rect.w)} · {formatPct(rect.h)}
        </span>
      </DataRow>

      <Divider />

      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          daemon call
        </p>
        <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11.5px] leading-[1.55] text-studio-ink">
          {placementJson}
        </pre>
      </div>
    </aside>
  );
}

function ComposedInspector({
  selection,
}: {
  selection: Extract<Selection, { kind: "composed" }>;
}) {
  const layout = selection.layout;
  const actionsJson = JSON.stringify(
    layout.members.map((name) => ({
      method: "window.place",
      params: { placement: name },
    })),
    null,
    2,
  );

  return (
    <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          layout
        </p>
        <p className="mt-1 font-mono text-[15px] text-studio-ink">{layout.label}</p>
        <p className="mt-1 text-xs leading-relaxed text-studio-ink-faint">
          {layout.caption}
        </p>
      </div>

      <Divider />

      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          members
        </p>
        <ul className="mt-2 space-y-1">
          {layout.members.map((name) => (
            <li
              key={name}
              className="font-mono text-[11.5px] text-studio-ink"
            >
              {name}
            </li>
          ))}
        </ul>
      </div>

      <Divider />

      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          actions
        </p>
        <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11.5px] leading-[1.55] text-studio-ink">
          {actionsJson}
        </pre>
      </div>
    </aside>
  );
}

function DataRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[88px_1fr] items-baseline gap-3">
      <span className="font-mono text-[9px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {label}
      </span>
      <span className="min-w-0">{children}</span>
    </div>
  );
}

function Divider() {
  return <div className="my-1 border-t border-studio-edge" />;
}

function PresetCard({
  preset,
  active,
  onClick,
}: {
  preset: TilePreset;
  active: boolean;
  onClick: () => void;
}) {
  const { grid, cell, rect, name, description } = preset;
  const isGridLike = preset.family !== "special" && !!cell;

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      title={description ?? name}
      className={[
        "group flex flex-col gap-2 rounded-sm border bg-transparent p-3 text-left transition-colors",
        active
          ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)]"
          : "border-studio-edge hover:border-studio-ink-faint",
      ].join(" ")}
    >
      <div
        className="relative w-full overflow-hidden rounded-[2px] border border-studio-edge bg-[color:var(--studio-canvas)]"
        style={{ aspectRatio: "16 / 10" }}
      >
        {isGridLike ? (
          <MiniGrid cols={grid.cols} rows={grid.rows} activeCell={cell ?? undefined} />
        ) : (
          <MiniFreeRect rect={rect} />
        )}
      </div>
      <div className="flex items-baseline justify-between gap-2">
        <span className="truncate font-mono text-[11.5px] text-studio-ink">
          {name}
        </span>
        <span className="shrink-0 font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
          {grid.cols}×{grid.rows}
        </span>
      </div>
    </button>
  );
}

function ComposedCard({
  layout,
  active,
  onClick,
}: {
  layout: ComposedLayout;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      title={layout.caption}
      className={[
        "group flex flex-col gap-2 rounded-sm border bg-transparent p-3 text-left transition-colors",
        active
          ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)]"
          : "border-studio-edge hover:border-studio-ink-faint",
      ].join(" ")}
    >
      <div
        className="relative w-full overflow-hidden rounded-[2px] border border-studio-edge bg-[color:var(--studio-canvas)]"
        style={{ aspectRatio: "16 / 10" }}
      >
        {layout.members.map((name, idx) => {
          const preset = findPreset(name);
          if (!preset) return null;
          const hue = `hsl(${Math.round(220 + (idx / Math.max(layout.members.length - 1, 1)) * 120)} 70% 65%)`;
          return (
            <div
              key={name}
              className="absolute"
              style={{
                left: `${preset.rect.x * 100}%`,
                top: `${preset.rect.y * 100}%`,
                width: `${preset.rect.w * 100}%`,
                height: `${preset.rect.h * 100}%`,
                background: `color-mix(in oklab, ${hue} 18%, transparent)`,
                border: `1px solid ${hue}`,
              }}
            />
          );
        })}
      </div>
      <div className="flex items-baseline justify-between gap-2">
        <span className="truncate font-mono text-[11.5px] text-studio-ink">
          {layout.label}
        </span>
        <span className="shrink-0 font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
          {layout.members.length}
        </span>
      </div>
    </button>
  );
}

function MiniGrid({
  cols,
  rows,
  activeCell,
}: {
  cols: number;
  rows: number;
  activeCell?: { col: number; row: number };
}) {
  const cells = [];
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const isActive = activeCell?.col === c && activeCell?.row === r;
      cells.push(
        <div
          key={`${c}-${r}`}
          className="border-[0.5px] border-studio-edge"
          style={{
            background: isActive
              ? "color-mix(in oklab, var(--scout-accent) 22%, transparent)"
              : "transparent",
            boxShadow: isActive
              ? "inset 0 0 0 1px var(--scout-accent)"
              : "none",
          }}
        />,
      );
    }
  }
  return (
    <div
      className="absolute inset-0 grid"
      style={{
        gridTemplateColumns: `repeat(${cols}, 1fr)`,
        gridTemplateRows: `repeat(${rows}, 1fr)`,
      }}
    >
      {cells}
    </div>
  );
}

function MiniFreeRect({ rect }: { rect: Rect }) {
  return (
    <div
      className="absolute"
      style={{
        left: `${rect.x * 100}%`,
        top: `${rect.y * 100}%`,
        width: `${rect.w * 100}%`,
        height: `${rect.h * 100}%`,
        background: "color-mix(in oklab, var(--scout-accent) 22%, transparent)",
        boxShadow: "inset 0 0 0 1px var(--scout-accent)",
      }}
    />
  );
}
