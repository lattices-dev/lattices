"use client";

import { useMemo, useState } from "react";
import {
  findPreset,
  parseGrid,
  TILE_FAMILIES,
  type Rect,
} from "@/studio/lib/tiling";
import { PanelHeading, ScreenMockup } from "./_shared";

type Source = "name" | "grid" | "fractions";

interface Resolved {
  rect: Rect;
  source: Source;
}

const DEFAULT_RECT: Rect = { x: 0.5, y: 0, w: 0.5, h: 1 };
const DEFAULT_NAME = "right";

const NAMED_OPTIONS = TILE_FAMILIES.flatMap((fam) =>
  fam.presets.map((p) => ({ value: p.name, family: fam.label })),
);

export function PlacementSpecPanel() {
  const [nameInput, setNameInput] = useState(DEFAULT_NAME);
  const [gridInput, setGridInput] = useState("2x1:2,1");
  const [fractionsInput, setFractionsInput] = useState(
    JSON.stringify({ x: 0.5, y: 0, w: 0.5, h: 1 }),
  );
  const [resolved, setResolved] = useState<Resolved>({
    rect: DEFAULT_RECT,
    source: "name",
  });
  const [errors, setErrors] = useState<Partial<Record<Source, string>>>({});

  function commitFromName(value: string) {
    setNameInput(value);
    const preset = findPreset(value.trim());
    if (!preset) {
      setErrors((e) => ({ ...e, name: "unknown placement name" }));
      return;
    }
    setErrors((e) => ({ ...e, name: undefined }));
    setResolved({ rect: preset.rect, source: "name" });
    setGridInput(deriveGridString(preset.rect) ?? "—");
    setFractionsInput(JSON.stringify(roundRect(preset.rect)));
  }

  function commitFromGrid(value: string) {
    setGridInput(value);
    if (!value.trim()) {
      setErrors((e) => ({ ...e, grid: "" }));
      return;
    }
    const parsed = parseGrid(value.trim());
    if (!parsed) {
      setErrors((e) => ({ ...e, grid: "expected CxR:c,r from 1 or grid:CxR:c,r from 0" }));
      return;
    }
    setErrors((e) => ({ ...e, grid: undefined }));
    setResolved({ rect: parsed.rect, source: "grid" });
    setNameInput(matchNamed(parsed.rect) ?? "—");
    setFractionsInput(JSON.stringify(roundRect(parsed.rect)));
  }

  function commitFromFractions(value: string) {
    setFractionsInput(value);
    try {
      const parsed = JSON.parse(value);
      const x = Number(parsed.x);
      const y = Number(parsed.y);
      const w = Number(parsed.w);
      const h = Number(parsed.h);
      if (![x, y, w, h].every(Number.isFinite)) throw new Error("non-numeric");
      if (x < 0 || y < 0 || w <= 0 || h <= 0) throw new Error("out of range");
      if (x + w > 1.0001 || y + h > 1.0001) throw new Error("exceeds bounds");
      const rect: Rect = { x, y, w, h };
      setErrors((e) => ({ ...e, fractions: undefined }));
      setResolved({ rect, source: "fractions" });
      setNameInput(matchNamed(rect) ?? "—");
      setGridInput(deriveGridString(rect) ?? "—");
    } catch (err) {
      setErrors((e) => ({
        ...e,
        fractions: err instanceof Error ? err.message : "invalid JSON",
      }));
    }
  }

  const wireValue = useMemo(() => {
    const r = resolved.rect;
    if (resolved.source === "name" && findPreset(nameInput))
      return nameInput;
    const grid = deriveGridString(r);
    if (grid) return grid;
    return `fractions:${r.x},${r.y},${r.w},${r.h}`;
  }, [resolved, nameInput]);

  return (
    <section className="mt-14">
      <PanelHeading
        eyebrow="03 · spec"
        title="Three formats, one shape"
        caption="Named / grid / fractions all reduce to the same fractional rect."
      />

      <div className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        <ScreenMockup>
          <div
            className="absolute transition-[left,top,width,height] duration-300 ease-out"
            style={{
              left: `${resolved.rect.x * 100}%`,
              top: `${resolved.rect.y * 100}%`,
              width: `${resolved.rect.w * 100}%`,
              height: `${resolved.rect.h * 100}%`,
              background: "color-mix(in oklab, var(--scout-accent) 14%, transparent)",
              border: "1.5px solid var(--scout-accent)",
            }}
          >
            <span
              className="absolute left-2 top-2 rounded-sm px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.18em]"
              style={{
                color: "var(--scout-accent)",
                background: "color-mix(in oklab, var(--studio-canvas) 80%, transparent)",
              }}
            >
              source · {resolved.source}
            </span>
          </div>
        </ScreenMockup>

        <aside className="flex flex-col gap-3 rounded-md border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
          <SpecInput
            label="Named"
            hint=".tile"
            active={resolved.source === "name"}
            value={nameInput}
            error={errors.name}
            onChange={commitFromName}
            datalist={NAMED_OPTIONS.map((o) => o.value)}
          />
          <Divider />
          <SpecInput
            label="Grid"
            hint="CxR:c,r from 1 · grid:CxR:c,r from 0"
            active={resolved.source === "grid"}
            value={gridInput}
            error={errors.grid}
            onChange={commitFromGrid}
          />
          <Divider />
          <SpecInput
            label="Fractions"
            hint=".fractions({x, y, w, h})"
            active={resolved.source === "fractions"}
            value={fractionsInput}
            error={errors.fractions}
            onChange={commitFromFractions}
            monospace
          />

          <Divider />

          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              wire value
            </p>
            <p
              className="mt-1 break-all font-mono text-[12px]"
              style={{ color: "var(--scout-accent)" }}
            >
              {wireValue}
            </p>
          </div>
        </aside>
      </div>

      <p className="mt-5 font-mono text-[11px] text-studio-ink-faint">
        PlacementSpec.swift:64–150 · all three init paths normalize to (x, y, w, h)
      </p>
    </section>
  );
}

function SpecInput({
  label,
  hint,
  active,
  value,
  error,
  onChange,
  monospace = false,
  datalist,
}: {
  label: string;
  hint: string;
  active: boolean;
  value: string;
  error?: string;
  onChange: (v: string) => void;
  monospace?: boolean;
  datalist?: string[];
}) {
  const listId = datalist ? `placement-${label.toLowerCase()}-list` : undefined;
  return (
    <div>
      <div className="flex items-baseline justify-between">
        <span
          className="font-mono text-[11px] uppercase tracking-[0.18em]"
          style={{ color: active ? "var(--scout-accent)" : "var(--studio-ink-faint)" }}
        >
          {label}
        </span>
        <span className="font-mono text-[9.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
          {hint}
        </span>
      </div>
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        list={listId}
        spellCheck={false}
        className={[
          "mt-2 w-full rounded-sm border bg-transparent px-2 py-1.5 text-[13px] text-studio-ink outline-none transition-colors",
          monospace ? "font-mono text-[12px]" : "font-mono text-[12.5px]",
          active
            ? "border-[color:var(--scout-accent)]"
            : "border-studio-edge focus:border-studio-ink-faint",
          error ? "border-[color:var(--status-error-fg)]" : "",
        ].join(" ")}
      />
      {datalist ? (
        <datalist id={listId}>
          {datalist.map((opt) => (
            <option key={opt} value={opt} />
          ))}
        </datalist>
      ) : null}
      {error ? (
        <p className="mt-1 font-mono text-[10px] text-[color:var(--status-error-fg)]">
          {error}
        </p>
      ) : null}
    </div>
  );
}

function Divider() {
  return <div className="my-1 border-t border-studio-edge" />;
}

function roundRect(r: Rect): Rect {
  return {
    x: round3(r.x),
    y: round3(r.y),
    w: round3(r.w),
    h: round3(r.h),
  };
}

function round3(n: number) {
  return Math.round(n * 1000) / 1000;
}

function deriveGridString(rect: Rect): string | null {
  for (let cols = 1; cols <= 6; cols++) {
    for (let rows = 1; rows <= 6; rows++) {
      const cellW = 1 / cols;
      const cellH = 1 / rows;
      if (!near(rect.w, cellW) || !near(rect.h, cellH)) continue;
      const col = Math.round(rect.x / cellW);
      const row = Math.round(rect.y / cellH);
      if (col < 0 || col >= cols || row < 0 || row >= rows) continue;
      if (!near(rect.x, col * cellW) || !near(rect.y, row * cellH)) continue;
      return `${cols}x${rows}:${col + 1},${row + 1}`;
    }
  }
  return null;
}

function matchNamed(rect: Rect): string | null {
  for (const fam of TILE_FAMILIES) {
    for (const preset of fam.presets) {
      if (
        near(preset.rect.x, rect.x) &&
        near(preset.rect.y, rect.y) &&
        near(preset.rect.w, rect.w) &&
        near(preset.rect.h, rect.h)
      ) {
        return preset.name;
      }
    }
  }
  return null;
}

function near(a: number, b: number) {
  return Math.abs(a - b) < 0.001;
}
