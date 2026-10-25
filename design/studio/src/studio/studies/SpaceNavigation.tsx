"use client";

import { useState } from "react";
import { ArrowUpRight, RotateCcw } from "lucide-react";
import { useStudioRouter } from "studio/router";
import type { LatticesPage } from "@/studio/studioRegistry";
import { SPACE_NAVIGATION_ASSETS, SPACE_NAVIGATION_HREF, spaceNavigationStudies } from "@/studio/lib/spaceNavigationStudies";

export function SpaceNavigationStudy({ entry, exhibit }: { entry: LatticesPage; exhibit?: string }) {
  const { Link } = useStudioRouter();
  const [revision, setRevision] = useState(0);
  const selected = spaceNavigationStudies.find((study) => study.slug === (exhibit ?? "opus-previews"));
  const groups = [...new Set(spaceNavigationStudies.map((study) => study.group))];
  return (
    <main className="w-full min-w-0 px-6 py-8 lg:px-7">
      <header className="border-b border-studio-rule pb-6">
        <h1 className="text-[32px] font-medium leading-tight text-studio-ink-strong">{entry.label}</h1>
        <p className="mt-3 max-w-[70ch] text-[14px] leading-relaxed text-studio-ink">Eight interactive studies, from the first rail treatments to the filmstrip and full canvas. Choose a treatment, then click into the preview to try its controls.</p>
      </header>
      <nav aria-label="Navigation studies" className="grid gap-x-6 gap-y-5 border-b border-studio-rule py-5 sm:grid-cols-2 xl:grid-cols-4">
        {groups.map((group) => <div key={group}>
          <h2 className="mb-2 text-[12px] font-medium text-studio-ink-faint">{group}</h2>
          <ul className="space-y-1">{spaceNavigationStudies.filter((study) => study.group === group).map((study) => <li key={study.slug}>
            <Link href={`${SPACE_NAVIGATION_HREF}/${study.slug}`} aria-current={selected?.slug === study.slug ? "page" : undefined}
              className={`flex items-baseline justify-between gap-3 rounded px-2 py-2 text-[13px] hover:bg-studio-chip-bg focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-current ${selected?.slug === study.slug ? "bg-studio-chip-bg text-studio-ink-strong" : "text-studio-ink"}`}>
              <span>{study.title}</span><span className="text-[11px] text-studio-ink-faint">{study.author}</span>
            </Link>
          </li>)}</ul>
        </div>)}
      </nav>
      {selected ? <section aria-label={selected.title} className="pt-6">
        <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div><h2 className="text-[20px] font-medium text-studio-ink-strong">{selected.title}</h2><p className="mt-2 max-w-[72ch] text-[13px] leading-relaxed text-studio-ink">{selected.description}</p></div>
          <div className="flex shrink-0 gap-4 text-[12px] text-studio-ink">
            <button onClick={() => setRevision((value) => value + 1)} className="inline-flex items-center gap-2 rounded py-2 hover:text-studio-ink-strong focus-visible:outline-2 focus-visible:outline-offset-2"><RotateCcw size={14} />Restart</button>
            <a href={`${SPACE_NAVIGATION_ASSETS}/${selected.file}`} target="_blank" rel="noreferrer" className="inline-flex items-center gap-2 rounded py-2 hover:text-studio-ink-strong focus-visible:outline-2 focus-visible:outline-offset-2">Open full size<ArrowUpRight size={14} /></a>
          </div>
        </div>
        <iframe key={`${selected.slug}-${revision}`} src={`${SPACE_NAVIGATION_ASSETS}/${selected.file}`} title={`${selected.title} — interactive study by ${selected.author}`} className="block h-[min(82vh,1000px)] min-h-[580px] w-full border border-studio-rule bg-studio-canvas" />
        <p className="mt-3 text-[12px] leading-relaxed text-studio-ink-faint">Illustrative browser prototypes. The baseline clip in Rail motion is a recording of the native app. These studies remain available for comparison as implementation evolves.</p>
      </section> : <p className="py-8 text-studio-ink">Study not found. Choose a treatment above.</p>}
    </main>
  );
}
