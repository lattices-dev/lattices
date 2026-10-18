"use client";

import type { ReactElement, ReactNode } from "react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { ChangeLedger, MOCK_H, MOCK_W, MockCaption, Thumb, type Change } from "./shell/_shell";
import { HomePanel } from "./shell/HomePanel";
import { NavigatorPanel } from "./shell/NavigatorPanel";
import { SIDEBAR_NOTES, SidebarPanel } from "./shell/SidebarPanel";
import { WindowsPanel } from "./shell/WindowsPanel";

interface ShellStudyProps {
  entry: LatticesPage;
  exhibit?: string;
}

interface Exhibit {
  slug: string;
  eyebrow: string;
  title: string;
  hook: string;
  note: string;
  cite: string;
  Panel: () => ReactElement;
  changes: Change[];
  Extra?: () => ReactElement;
}

const EXHIBITS: Exhibit[] = [
  {
    slug: "home",
    eyebrow: "landing",
    title: "Home",
    hook: "Opens on work in progress instead of five cards that link to the sidebar.",
    note: "Click any row to select it. Hover the second row to see the action column.",
    cite: "HomeDashboardView.swift",
    Panel: HomePanel,
    changes: [
      {
        title: "Sessions lead, not a tile wall",
        body: "Home opens on the three things you'd actually resume — each with its repo path, pane count, and window count. The destinations those five cards linked to already live in the sidebar, one click away, permanently.",
        was: "Chat · Studio · Search · Runs · Activity cards over a gradient",
      },
      {
        title: "Active windows becomes a table",
        body: "Column headers name what each value is, so the trailing numbers stop reading as decoration. Rows hold one fixed height with a reserved action column — hover swaps the metadata for controls without moving anything.",
        was: "9px mono metadata crossfading with hover buttons",
      },
      {
        title: "One type scale; mono means data",
        body: "Chrome is 12–15px system text. The monospace stays for paths, frames, counts, and keys — the places where fixed width earns itself — instead of being the voice of the entire app.",
        was: "9–11px mono for titles, labels, status, and prose alike",
      },
      {
        title: "No explainer copy, no gradient",
        body: "\"Layout, search, chat, and screen context in one place\" described the UI back to itself. The header is now the page name and the actions available on it. Green is spent on one thing: running.",
        was: "subtitle plus a green-to-black gradient hero band",
      },
    ],
  },
  {
    slug: "windows",
    eyebrow: "inventory",
    title: "Windows",
    hook: "The same desktop inventory, laid out as a file browser rather than a HUD with a chord legend.",
    note: "Filter by display, select rows to drive the inspector, pick a placement in the 3×3 grid.",
    cite: "CommandModeView.swift",
    Panel: WindowsPanel,
    changes: [
      {
        title: "Filters live in a pane, not a pill strip",
        body: "Displays, spaces, and apps become a scannable list with counts, so you see the shape of the desktop before filtering it. Apps under four windows collapse into \"12 more\" rather than each earning a chip.",
        was: "preset pills with numeric key hints plus an inline stat trio",
      },
      {
        title: "An inspector instead of a chord footer",
        body: "Selecting a window shows what Lattices actually knows about it — frame, space, working directory, tmux session, pid — with the 3×3 placement grid right there. The keyboard chords still work; they're no longer the only way in.",
        was: "a footer strip of chord hints pinned under the columns",
      },
      {
        title: "Matches say where they came from",
        body: "The count separates title matches from screen-text matches, and an OCR hit renders as one indented line beneath its own window with the term highlighted — attached to the row instead of floating in a separate mode.",
        was: "\"11 matches (4 by content)\" with detached snippet rows",
      },
      {
        title: "Windows, not Desktop Inventory",
        body: "The sidebar and title use the word for the thing on screen. Inventory survives as a verb — Copy inventory — where it describes an export, which is what the term actually means here.",
        was: "Desktop Inventory · Grid Region · Browsing mode labels",
      },
    ],
  },
  {
    slug: "navigator",
    eyebrow: "palette",
    title: "Navigator",
    hook: "Four overlays that each owned a hotkey become one palette with typed results.",
    note: "Hover a result — the preview pane follows the highlight.",
    cite: "UnifiedCommandBarState.swift",
    Panel: NavigatorPanel,
    changes: [
      {
        title: "One ⌘K, four kinds of result",
        body: "Windows, sessions, pages, and commands share a single palette with typed groups. The scope chip narrows to one group with tab, for when you already know what you're after.",
        was: "command bar · unified command bar · omni search · browse menu",
      },
      {
        title: "Preview before you commit",
        body: "The highlighted result shows where that window sits on the display, plus its space and working directory — enough to know you've got the right Ghostty out of nine before pressing return.",
        was: "a scored list with no way to tell two identical titles apart",
      },
      {
        title: "The footer teaches three keys, not thirty",
        body: "Return focuses, shift-return tiles, tab narrows. Everything else stays reachable but stops competing for attention at the exact moment you're mid-search.",
        was: "a dense chord legend pinned under every mode",
      },
    ],
  },
  {
    slug: "sidebar",
    eyebrow: "rail",
    title: "Navigation",
    hook: "The rail that wraps every screen: where you are, what you can do here, what the machine is doing.",
    note: "Both rails are the live components — the same nav model, rendered two ways.",
    cite: "AppShellView.swift",
    Panel: SidebarPanel,
    Extra: SidebarComparison,
    changes: [
      {
        title: "Every page has a title bar",
        body: "A 46px toolbar with the page name at the left and that page's actions at the right, in the same position across Home, Windows, Studio, and Runs. You always know where you are and what's available.",
        was: "page identity carried only by a muted right-aligned status label",
      },
      {
        title: "The status bar holds still",
        body: "Three slots with the same meaning on every page: session health, desktop shape, last scan. Page-specific counts moved next to the things they count. Errors get one line and a click into Activity.",
        was: "per-page sets of five to seven items, plus OCR state and log tallies",
      },
      {
        title: "Plain nouns for pages",
        body: "Windows, Studio, Assistant, Runs, Activity. Screen Map, Desktop Inventory, and Command Mode were internal names that made the app read as a tool built for its author alone.",
        was: "Studio ← screenMap, Desktop Inventory ← commandMode",
      },
      {
        title: "Ordinary macOS metrics",
        body: "34px rows, 13px body, an 8pt spacing rhythm, 6–8px radii, and a drawn icon set at one stroke weight. The app still looks like it belongs beside a terminal — it just stops asking you to read 9px type to operate it.",
        was: "9–11px mono throughout, 4–5px radii, variable row heights",
      },
    ],
  },
];

const EXHIBIT_BY_SLUG = new Map(EXHIBITS.map((e) => [e.slug, e]));

const PRINCIPLES: [string, string][] = [
  ["Mono means fixed-width data", "Paths, frames, pids, counts, keys. Not headings, not prose, not buttons."],
  ["Green means running", "Sessions, daemon, live capture. Amber and red stay for degraded and failed; everything else is neutral text."],
  ["Chords are the second way in", "Every keyboard path keeps working, and each one gets a visible control that does the same thing."],
  ["Counts live beside their subject", "38 next to Windows, 4 next to Runs — never aggregated into a strip that changes shape per page."],
  ["Names come from the desktop", "The user's words: windows, spaces, displays, sessions, layouts. Not the model's: inventory, map, mode."],
  ["Geometry is fixed", "Rows, cards, and the action column hold their size across states, so hover and selection never reflow the page."],
];

export function ShellStudy({ entry, exhibit }: ShellStudyProps) {
  if (!exhibit) return <ShellIndex entry={entry} />;

  const ex = EXHIBIT_BY_SLUG.get(exhibit);
  if (!ex) return <ExhibitNotFound exhibit={exhibit} />;

  const index = EXHIBITS.findIndex((e) => e.slug === exhibit);
  const prev = index > 0 ? EXHIBITS[index - 1] : null;
  const next = index < EXHIBITS.length - 1 ? EXHIBITS[index + 1] : null;

  return (
    <main className="max-w-6xl px-6 py-8">
      <ExhibitCrumb entry={entry} ex={ex} />

      <div className="mt-7">
        <ex.Panel />
        <MockCaption note={ex.note} />
      </div>

      {ex.Extra ? <ex.Extra /> : null}

      <ChangeLedger changes={ex.changes} />

      <ExhibitPager prev={prev} next={next} />
    </main>
  );
}

function SidebarComparison() {
  return (
    <div className="mt-10 grid gap-x-12 gap-y-6 sm:grid-cols-2">
      <NoteColumn label="What the icon rail costs" notes={SIDEBAR_NOTES.old} />
      <NoteColumn label="What the labeled sidebar buys" notes={SIDEBAR_NOTES.now} accent />
    </div>
  );
}

function NoteColumn({
  label,
  notes,
  accent = false,
}: {
  label: string;
  notes: string[];
  accent?: boolean;
}) {
  return (
    <section>
      <h3
        className="font-mono text-[10px] uppercase tracking-[0.22em]"
        style={{ color: accent ? "var(--status-ok-fg)" : "var(--studio-ink-faint)" }}
      >
        {label}
      </h3>
      <ul className="mt-4 space-y-3">
        {notes.map((note) => (
          <li key={note} className="relative pl-4 text-[13.5px] leading-relaxed text-studio-ink-faint">
            <span
              className="absolute left-0 top-[0.72em] block h-px w-2"
              style={{ background: "var(--studio-ink-faint)", opacity: 0.6 }}
            />
            <Emphasized text={note} />
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Renders **bold** spans without pulling in a markdown dependency. */
function Emphasized({ text }: { text: string }): ReactNode {
  return text.split(/\*\*(.+?)\*\*/g).map((part, i) =>
    i % 2 === 1 ? (
      <strong key={i} className="font-medium text-studio-ink">
        {part}
      </strong>
    ) : (
      <span key={i}>{part}</span>
    ),
  );
}

function ShellIndex({ entry }: { entry: LatticesPage }) {
  return (
    <main className="max-w-6xl px-6 py-8">
      <header className="flex items-baseline justify-between gap-6">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            studio · shell
          </p>
          <h1 className="mt-2 max-w-[18ch] font-sans text-4xl font-medium leading-[1.05] tracking-tight text-studio-ink sm:text-5xl">
            Lattices stops looking like an IDE.
          </h1>
          <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
            A redesign pass on the app shell and the three screens that carry it. Every
            feature survives; what changes is that the app states where you are, names
            things the way the desktop does, and sets type you can read without leaning
            in. Each exhibit is the proposed screen, running, with the reasoning under it.
          </p>
        </div>
        <p className="shrink-0 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          {entry.status === "shipped" ? "live" : "draft"}
        </p>
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

        <ul className="mt-6 grid gap-4 sm:grid-cols-2">
          {EXHIBITS.map((ex, idx) => (
            <li key={ex.slug}>
              <a
                href={`/studio/studies/shell/${ex.slug}`}
                className="group flex h-full flex-col border border-studio-edge bg-[color:var(--studio-canvas)] transition-colors hover:border-studio-ink-faint"
              >
                <div
                  className="relative w-full overflow-hidden border-b border-studio-edge"
                  style={{ aspectRatio: `${MOCK_W} / ${MOCK_H}` }}
                >
                  <Thumb>
                    <ex.Panel />
                  </Thumb>
                </div>
                <div className="flex flex-1 flex-col gap-2 p-5">
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
                      {String(idx + 1).padStart(2, "0")} · {ex.eyebrow}
                    </p>
                    <p className="font-mono text-[9px] uppercase tracking-[0.18em] text-studio-ink-faint">
                      {ex.cite}
                    </p>
                  </div>
                  <h3 className="font-sans text-xl font-medium leading-snug text-studio-ink">
                    {ex.title}
                  </h3>
                  <p className="text-[13px] leading-relaxed text-studio-ink-faint">{ex.hook}</p>
                  <p className="mt-auto pt-3 font-mono text-[10px] uppercase tracking-[0.18em] text-studio-ink-faint transition-colors group-hover:text-studio-ink">
                    open exhibit →
                  </p>
                </div>
              </a>
            </li>
          ))}
        </ul>
      </section>

      <section className="mt-16">
        <div className="flex items-baseline justify-between border-b border-studio-edge pb-3">
          <h2 className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            The rule behind all four
          </h2>
        </div>
        <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
          The IDE feeling came from density and invented vocabulary, not from capability.
          Keeping the power while dropping the initiation cost meant deciding, element by
          element, whether it was expressing something real.
        </p>
        <dl className="mt-7 grid gap-x-12 gap-y-6 sm:grid-cols-2 lg:grid-cols-3">
          {PRINCIPLES.map(([term, gloss]) => (
            <div key={term}>
              <dt className="font-sans text-[14px] font-medium tracking-tight text-studio-ink">
                {term}
              </dt>
              <dd className="mt-1 text-[13px] leading-relaxed text-studio-ink-faint">{gloss}</dd>
            </div>
          ))}
        </dl>
      </section>

      <footer className="mt-16 border-t border-studio-edge pt-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          source · AppShellView.swift · HomeDashboardView.swift · CommandModeView.swift · UI/Theme.swift
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
            href="/studio/studies/shell"
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
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-studio-ink-faint">{ex.hook}</p>
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
          href={`/studio/studies/shell/${prev.slug}`}
          className="flex flex-col gap-1 border border-studio-edge p-4 transition-colors hover:border-studio-ink-faint"
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
          href={`/studio/studies/shell/${next.slug}`}
          className="flex flex-col gap-1 border border-studio-edge p-4 text-right transition-colors hover:border-studio-ink-faint"
        >
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            next · {next.eyebrow} →
          </span>
          <span className="font-sans text-[15px] text-studio-ink">{next.title}</span>
        </a>
      ) : (
        <a
          href="/studio/studies/shell"
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
        <a className="underline" href="/studio/studies/shell">
          ← back to shell index
        </a>
      </p>
    </main>
  );
}
