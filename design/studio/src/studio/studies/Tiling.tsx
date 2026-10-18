"use client";

import type { ReactElement } from "react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { AutoGridPanel } from "./tiling/AutoGridPanel";
import { CoordinateFlipPanel } from "./tiling/CoordinateFlipPanel";
import { PlacementSpecPanel } from "./tiling/PlacementSpecPanel";
import { PresetGalleryPanel } from "./tiling/PresetGalleryPanel";
import { SnapZonePanel } from "./tiling/SnapZonePanel";

interface TilingStudyProps {
  entry: LatticesPage;
  exhibit?: string;
}

interface Exhibit {
  slug: string;
  eyebrow: string;
  title: string;
  hook: string;
  Component: () => ReactElement;
  Thumb: () => ReactElement;
  cite: string;
}

const EXHIBITS: Exhibit[] = [
  {
    slug: "presets",
    eyebrow: "catalog",
    title: "Preset gallery",
    hook: "Every named placement Lattices accepts, on a real screen.",
    Component: PresetGalleryPanel,
    Thumb: PresetThumb,
    cite: "PlacementSpec.swift",
  },
  {
    slug: "auto-grid",
    eyebrow: "distribute",
    title: "Auto-grid distributor",
    hook: "Pick the prettiest grid for N windows. 5 → [3, 2].",
    Component: AutoGridPanel,
    Thumb: AutoGridThumb,
    cite: "WindowTiler.swift:1700",
  },
  {
    slug: "coords",
    eyebrow: "coordinates",
    title: "Three systems, two flips",
    hook: "Drag a window — watch NSScreen / CG / AX coordinates resolve.",
    Component: CoordinateFlipPanel,
    Thumb: CoordsThumb,
    cite: "WindowTiler.swift:435",
  },
  {
    slug: "spec",
    eyebrow: "type",
    title: "PlacementSpec union",
    hook: "Named / grid / fractions — three formats, one fractional rect.",
    Component: PlacementSpecPanel,
    Thumb: SpecThumb,
    cite: "PlacementSpec.swift:64",
  },
  {
    slug: "snap",
    eyebrow: "resolver",
    title: "Snap-zone overlap",
    hook: "When triggers overlap: priority desc → area asc → id.",
    Component: SnapZonePanel,
    Thumb: SnapThumb,
    cite: "WindowDragSnapController.swift:292",
  },
];

const EXHIBIT_BY_SLUG = new Map(EXHIBITS.map((e) => [e.slug, e]));

export function TilingStudy({ entry, exhibit }: TilingStudyProps) {
  if (!exhibit) return <TilingIndex entry={entry} />;

  const ex = EXHIBIT_BY_SLUG.get(exhibit);
  if (!ex) return <ExhibitNotFound exhibit={exhibit} />;

  const index = EXHIBITS.findIndex((e) => e.slug === exhibit);
  const prev = index > 0 ? EXHIBITS[index - 1] : null;
  const next = index < EXHIBITS.length - 1 ? EXHIBITS[index + 1] : null;

  return (
    <main className="max-w-6xl px-6 py-8">
      <ExhibitCrumb entry={entry} ex={ex} />
      <div className="mt-6">
        <ex.Component />
      </div>
      <ExhibitPager prev={prev} next={next} />
    </main>
  );
}

function TilingIndex({ entry }: { entry: LatticesPage }) {
  return (
    <main className="max-w-6xl px-6 py-8">
      <header className="flex items-baseline justify-between gap-6">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            studio · tiling
          </p>
          <h1 className="mt-2 font-sans text-4xl font-medium tracking-tight text-studio-ink sm:text-5xl">
            {entry.label}
          </h1>
          <p className="mt-4 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
            A workshop for the mechanics behind Lattices window placement.
            Every named tile, the distributor's grid choices, the coordinate
            flips, the typed placement union, and the snap-zone resolver —
            each one an exhibit you can poke at.
          </p>
        </div>
        <a
          href="/studio/eng/tiling-reference"
          className="shrink-0 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
        >
          Reference
        </a>
      </header>

      <section className="mt-12">
        <div className="flex items-baseline justify-between border-b border-studio-edge pb-3">
          <h2 className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            Exhibits
          </h2>
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            {String(EXHIBITS.length).padStart(2, "0")}
          </span>
        </div>

        <ul className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {EXHIBITS.map((ex, idx) => (
            <li key={ex.slug}>
              <a
                href={`/studio/studies/tiling/${ex.slug}`}
                className="group flex h-full flex-col border border-studio-edge bg-[color:var(--studio-canvas)] transition-colors hover:border-studio-ink-faint"
              >
                <div
                  className="relative w-full overflow-hidden border-b border-studio-edge"
                  style={{ aspectRatio: "16 / 10" }}
                >
                  <ex.Thumb />
                </div>
                <div className="flex flex-1 flex-col gap-2 p-5">
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                      {String(idx + 1).padStart(2, "0")} · {ex.eyebrow}
                    </p>
                    <p className="font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
                      {ex.cite.split(":")[0]}
                    </p>
                  </div>
                  <h3 className="font-sans text-xl font-medium leading-snug text-studio-ink">
                    {ex.title}
                  </h3>
                  <p className="text-[13px] leading-relaxed text-studio-ink-faint">
                    {ex.hook}
                  </p>
                  <p className="mt-auto pt-3 font-mono text-[10px] uppercase tracking-[0.18em] text-studio-ink-faint transition-colors group-hover:text-studio-ink">
                    open exhibit →
                  </p>
                </div>
              </a>
            </li>
          ))}
        </ul>
      </section>

      <footer className="mt-16 border-t border-studio-edge pt-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          source · WindowTiler.swift · PlacementSpec.swift · WindowDragSnapController.swift · IntentEngine.swift
        </p>
      </footer>
    </main>
  );
}

function ExhibitCrumb({ entry, ex }: { entry: LatticesPage; ex: Exhibit }) {
  return (
    <div className="flex items-baseline justify-between gap-6">
      <div>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          <a
            href="/studio/studies/tiling"
            className="underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
          >
            ← {entry.label}
          </a>
          <span className="px-2 text-studio-edge">/</span>
          <span>{ex.eyebrow}</span>
        </p>
        <h1 className="mt-2 font-sans text-3xl font-medium tracking-tight text-studio-ink sm:text-4xl">
          {ex.title}
        </h1>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-studio-ink-faint">
          {ex.hook}
        </p>
      </div>
      <p className="shrink-0 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {ex.cite}
      </p>
    </div>
  );
}

function ExhibitPager({ prev, next }: { prev: Exhibit | null; next: Exhibit | null }) {
  return (
    <nav className="mt-16 grid gap-3 border-t border-studio-edge pt-5 sm:grid-cols-2">
      {prev ? (
        <a
          href={`/studio/studies/tiling/${prev.slug}`}
          className="group flex flex-col gap-1 border border-studio-edge p-4 transition-colors hover:border-studio-ink-faint"
        >
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            ← previous · {prev.eyebrow}
          </span>
          <span className="font-sans text-[15px] text-studio-ink">{prev.title}</span>
        </a>
      ) : (
        <span />
      )}
      {next ? (
        <a
          href={`/studio/studies/tiling/${next.slug}`}
          className="group flex flex-col gap-1 border border-studio-edge p-4 text-right transition-colors hover:border-studio-ink-faint"
        >
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            next · {next.eyebrow} →
          </span>
          <span className="font-sans text-[15px] text-studio-ink">{next.title}</span>
        </a>
      ) : (
        <a
          href="/studio/studies/tiling"
          className="flex flex-col gap-1 border border-studio-edge p-4 text-right transition-colors hover:border-studio-ink-faint"
        >
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            back to index ↩
          </span>
          <span className="font-sans text-[15px] text-studio-ink">All exhibits</span>
        </a>
      )}
    </nav>
  );
}

function ExhibitNotFound({ exhibit }: { exhibit: string }) {
  return (
    <main className="max-w-6xl px-6 py-12">
      <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
        no exhibit named "{exhibit}"
      </p>
      <p className="mt-3 font-mono text-[12px] text-studio-ink-faint">
        <a className="underline" href="/studio/studies/tiling">
          ← back to tiling index
        </a>
      </p>
    </main>
  );
}

function PresetThumb() {
  return (
    <div className="absolute inset-0 grid grid-cols-4 grid-rows-2 gap-px bg-[color:var(--studio-edge)]">
      {Array.from({ length: 8 }).map((_, i) => (
        <div
          key={i}
          className="bg-[color:var(--studio-canvas)]"
          style={
            i === 5
              ? {
                  background:
                    "color-mix(in oklab, var(--scout-accent) 24%, var(--studio-canvas))",
                  boxShadow: "inset 0 0 0 1px var(--scout-accent)",
                }
              : undefined
          }
        />
      ))}
    </div>
  );
}

function AutoGridThumb() {
  return (
    <div className="absolute inset-0 flex flex-col gap-px bg-[color:var(--studio-edge)]">
      <div className="grid flex-1 grid-cols-3 gap-px">
        {Array.from({ length: 3 }).map((_, i) => (
          <div
            key={i}
            className="bg-[color:var(--studio-canvas)]"
            style={{
              boxShadow: "inset 0 0 0 1px color-mix(in oklab, var(--scout-accent) 50%, transparent)",
              background: "color-mix(in oklab, var(--scout-accent) 14%, var(--studio-canvas))",
            }}
          />
        ))}
      </div>
      <div className="grid flex-1 grid-cols-2 gap-px">
        {Array.from({ length: 2 }).map((_, i) => (
          <div
            key={i}
            className="bg-[color:var(--studio-canvas)]"
            style={{
              boxShadow: "inset 0 0 0 1px color-mix(in oklab, var(--scout-accent) 50%, transparent)",
              background: "color-mix(in oklab, var(--scout-accent) 14%, var(--studio-canvas))",
            }}
          />
        ))}
      </div>
      <span className="absolute right-2 top-2 font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
        N=5 · [3,2]
      </span>
    </div>
  );
}

function CoordsThumb() {
  return (
    <div className="absolute inset-0 bg-[color:var(--studio-canvas)]">
      <div
        className="absolute"
        style={{
          left: "20%",
          top: "20%",
          width: "45%",
          height: "55%",
          background: "color-mix(in oklab, var(--scout-accent) 14%, transparent)",
          border: "1px solid var(--scout-accent)",
        }}
      />
      <span className="absolute left-2 top-2 font-mono text-[8.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
        ↑ NSScreen
      </span>
      <span className="absolute right-2 top-2 font-mono text-[8.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
        ↓ CG
      </span>
      <span
        className="absolute right-2 bottom-2 font-mono text-[8.5px] uppercase tracking-[0.18em]"
        style={{ color: "var(--scout-accent)" }}
      >
        ↓ AX
      </span>
    </div>
  );
}

function SpecThumb() {
  return (
    <div className="absolute inset-0 flex flex-col justify-center gap-1.5 p-4">
      {[".tile(\"right\")", ".grid(2x1:1,0)", ".fractions(.5, 0, .5, 1)"].map(
        (line, i) => (
          <div
            key={i}
            className="rounded-sm border border-studio-edge bg-[color:var(--studio-canvas)] px-2 py-1 font-mono text-[10px] text-studio-ink-faint"
          >
            {line}
          </div>
        ),
      )}
      <p
        className="mt-1 text-center font-mono text-[9px] uppercase tracking-[0.18em]"
        style={{ color: "var(--scout-accent)" }}
      >
        ↓ (.5, 0, .5, 1)
      </p>
    </div>
  );
}

function SnapThumb() {
  return (
    <div className="absolute inset-0 bg-[color:var(--studio-canvas)]">
      <div
        className="absolute"
        style={{
          left: "8%",
          top: "20%",
          width: "26%",
          height: "60%",
          background: "color-mix(in oklab, var(--studio-ink-faint) 6%, transparent)",
          border: "1px dashed var(--studio-ink-faint)",
        }}
      />
      <div
        className="absolute"
        style={{
          left: "12%",
          top: "30%",
          width: "18%",
          height: "30%",
          background: "color-mix(in oklab, var(--scout-accent) 22%, transparent)",
          border: "1px solid var(--scout-accent)",
        }}
      />
      <span
        className="absolute right-2 top-2 font-mono text-[8.5px] uppercase tracking-[0.18em]"
        style={{ color: "var(--scout-accent)" }}
      >
        P20 wins
      </span>
    </div>
  );
}
