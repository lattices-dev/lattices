"use client";

import type { ReactElement, ReactNode } from "react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { ChangeLedger, MOCK_H, MOCK_W, MockCaption, Thumb, type Change } from "./shell/_shell";
import { QUERIES } from "./shell-b/CommandBar";
import { DesktopPanelB } from "./shell-b/DesktopPanelB";
import { HomePanelB } from "./shell-b/HomePanelB";
import { NAV_NOTES, NavigationPanelB, STATUS_MOVES } from "./shell-b/NavigationPanelB";
import { BarStrip, NavigatorPanelB } from "./shell-b/NavigatorPanelB";

interface ShellBStudyProps {
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

const BASE = "/studio/studies/shell-b";

const EXHIBITS: Exhibit[] = [
  {
    slug: "home",
    eyebrow: "landing",
    title: "Home",
    hook: "The bar with nothing typed. What it shows is the page.",
    note: "Click a cell in the nine-grid to place the front window. Every row carries its own verb.",
    cite: "BrowseMenu.swift",
    Panel: HomePanelB,
    changes: [
      {
        title: "Home is the empty query",
        body: "OmniSearchState already answers an empty query with BrowseMenu: tile the front window, attach or launch each project, focus or launch each layer. Those three sections are the page, plus Recent — the last things the bar did, each with Again — which is the one section BrowseMenu doesn't build yet. Typing replaces them all with results in rows of the same height; esc brings them back. The first pass put a 38-row windows table here — that is the Desktop page's job, and Home stops previewing it.",
        was: "five cards linking to the sidebar, over a gradient, with a windows table beneath",
      },
      {
        title: "The front window comes first",
        body: "You summoned Lattices while looking at something. That window — Chrome, Docs, Space 1 — sits top-left with its nine placements, Maximize, and Send to the other display. BrowseMenu already captures frontmostWindow() at open; the card stops hiding it as three menu rows.",
        was: "Tile Chrome Left · Tile Chrome Right · Tile Chrome Maximize, as rows in the browse list",
      },
      {
        title: "One control, three phases",
        body: "A round control at the bar's trailing edge: a mic at rest, a return arrow once there's text, green only when the text resolves to something that will change the desktop. It replaces the mode badge, the mic, the send button, and the dismiss button, which said the same thing four ways.",
        was: "SEARCH / COMMAND / ASK badge at left, then mic · send · dismiss at right",
      },
      {
        title: "State is a dot, the verb is a button",
        body: "Session and layer rows are 44px with a reserved 72px column for the one verb that applies — Attach or Launch, Focus or Launch. Running is a 6px green dot; a stopped session's dot is white at 22%. Kill moves to the row's context menu, where a destructive action belongs.",
        was: "Attach · Kill · Launch as separate flat rows per project, each with an icon and a subtitle",
      },
    ],
  },
  {
    slug: "windows",
    eyebrow: "inventory",
    title: "Desktop",
    hook: "The inventory drawn to scale, not listed. Search dims what doesn't match.",
    note: "Click a window to inspect it in the bar below. Click a space chip to draw that space instead.",
    cite: "CommandModeState.swift",
    Panel: DesktopPanelB,
    changes: [
      {
        title: "Geometry is drawn, not described",
        body: "Both displays at one scale, the current space's windows at their real frames, stacked in z-order. The Space column, the Left / Center / Right region label, and the Size column existed because a table can't show where a window is. The map doesn't need them; the list survives as the second view control.",
        was: "per-display columns of rows with region · size · last-seen, plus Grid Region and Grid Preview modes",
      },
      {
        title: "Search dims; it doesn't sort",
        body: "Windows that match stay where they are. Windows that don't drop to 30%. An OCR hit gets the text glyph on its own window. The count reads \"7 of 14 · 2 by screen text\" so you know how many came from titles and how many from the screen. There are no preset chips — Terminals is the word ghostty, and Current Space is what the map shows by default.",
        was: "All · Terminals · Editors · Browsers · Lattices · Current Space pills, and \"11 matches (4 by content)\"",
      },
      {
        title: "Studio and Inventory are one page",
        body: "Both read DesktopModel; one arranged windows on a drawn screen, the other listed them. Desktop draws and arranges. The layers Studio owned move to Home, where they're launched from. The status items each page kept separately go away with the second page.",
        was: "Studio (screenMap) and Desktop Inventory (commandMode) as sibling tabs with separate status strips",
      },
      {
        title: "Detail is a bar, not a pane",
        body: "A 64px strip under the map with seven fixed slots: identity, frame, space, cwd, tmux, pid, and the actions with a nine-cell placement glyph. It holds its height whether or not a window is selected. The first pass spent 248px of width on a side inspector; the map wanted that width more.",
        was: "Overview · Spaces · Top Apps · Keys sidebar cards, swapping to Selection when something is chosen",
      },
    ],
  },
  {
    slug: "navigator",
    eyebrow: "bar",
    title: "Navigator",
    hook: "The bar reads a sentence — verb, target, place — and each row says what return will do to it.",
    note: "Hover a result. The verb column is what ↵ does; ⌘↵ applies it to every match.",
    cite: "UnifiedCommandBarState.swift",
    Panel: NavigatorPanelB,
    Extra: NavigatorGrammar,
    changes: [
      {
        title: "Verb · target · place",
        body: "UnifiedCommandBarState already resolves natural-language commands — nlMatch fills a position slot and nlSpec drives a ghost preview — but only shows it in a separate detail panel. Here the recognised words get an underline in the field: solid for the verb, dotted for the place. No verb means Focus for windows and Attach for sessions. The slash still works; it's no longer the only way to say a verb.",
        was: "search results, / command suggestions, and NL preview as three different expansion panels",
      },
      {
        title: "Results are objects; the verb rides the row",
        body: "Every row is a window, a session, or an app, with what ↵ does to it in a reserved column at the right — Focus, Tile left, Attach — and the place token as a nine-cell glyph with the target cells lit. The first pass answered \"which Ghostty\" with a preview pane; here the row's second line carries the space and the cwd, and the pane isn't needed.",
        was: "OmniResult rows with an icon and a subtitle, the action invisible until ↵",
      },
      {
        title: "Not an overlay",
        body: "The bar is the top of Home; ⌘K from any other page shows Home with the bar focused. Results replace the browse sections in place, in rows of the same height. Nothing dims, nothing floats, and esc clears the text rather than closing a window.",
        was: "UnifiedCommandBarWindow, a floating panel with a carbon texture and a cyan rim",
      },
      {
        title: "Four keys",
        body: "↵ does the verb to the highlighted row. ⌘↵ does it to every match — tile all three Chromes left. ⇥ moves to the next word, so you can change \"left\" without retyping. esc clears. The arrow keys work and aren't listed.",
        was: "↑/↓ navigate · ⇥ complete · ↵ run, plus a per-mode legend",
      },
    ],
  },
  {
    slug: "sidebar",
    eyebrow: "toolbar",
    title: "Navigation",
    hook: "Tabs in the toolbar, no sidebar, no status bar. One row of chrome above the content and nothing below it.",
    note: "The same toolbar at three widths. Tabs hold still; page actions fold first, then labels.",
    cite: "AppShellView.swift",
    Panel: NavigationPanelB,
    Extra: NavigationComparison,
    changes: [
      {
        title: "Tabs in the toolbar",
        body: "Five pages fit as a segmented control beside the traffic lights, in the 52px the unified toolbar already costs. The window gets 198px of width back. Below 640px the tabs drop to glyphs with tooltips — the shipping rail, kept as the narrow fallback rather than the thing you see first.",
        was: "an icon-only rail, expanded by tapping the logo, with six primary tabs and Settings in its footer",
      },
      {
        title: "Five pages, not nine",
        body: "Home, Desktop, Assistant, Runs, Log. Studio and Desktop Inventory merge into Desktop. Settings is a window on ⌘, and Docs is a Help menu item — neither is a place you're on, so neither needs to leave the tabs with nothing selected.",
        was: "home · assistant · screenMap · desktopInventory · runs · activity, plus settings, companionSettings, and docs, which deselected the rail",
      },
      {
        title: "The status bar is gone",
        body: "Its items each moved beside the thing they qualify: running counts to Sessions, window totals to the Desktop page, the scan time beside the search it dates, errors to a count on the Log tab. The daemon is a 6px dot next to Settings. The first pass kept the strip and made it hold still; this pass finds it had nothing left to say once the counts moved.",
        was: "a 26px strip: running · projects, or windows · monitors · spaces · selected · OCR state, then Logs · errors, then the page name",
      },
      {
        title: "Two hues",
        body: "Green for running and for the bar's control when ↵ will act. Red for the Log badge when there is an error. Selection, hover, the hot placement cell, the connected daemon, the current tab: white at an opacity. The first pass spent green on selected rows, the placement grid, the daemon pulse, and the active nav icon; this pass keeps it for state that changes.",
        was: "running green on the active rail icon, the daemon pulse, selected rows, and the placement grid",
      },
    ],
  },
];

const EXHIBIT_BY_SLUG = new Map(EXHIBITS.map((e) => [e.slug, e]));

const PRINCIPLES: [string, string][] = [
  ["Home is the empty query", "What the bar shows with nothing typed is the page. Typing swaps it for results in the same rows."],
  ["The front window goes first", "You summoned Lattices looking at something. That window and its nine placements come before any list."],
  ["Geometry is drawn", "Displays to scale, windows at their frames. A Space column and a region label are what a table does when it can't draw."],
  ["The verb rides the row", "Attach, Launch, Focus, Tile left — on the row, in a reserved column, visible before you press anything."],
  ["Two hues", "Green when something is running or ↵ will act. Red on the Log badge when there's an error. Everything else is white at an opacity."],
  ["Nothing below the content", "No status bar. Each fact moved beside the thing it qualifies, or became a dot."],
];

export function ShellBStudy({ entry, exhibit }: ShellBStudyProps) {
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

/** The bar at two more queries: a bare noun, and free text that hits sessions and screen text. */
function NavigatorGrammar() {
  return (
    <div className="mt-10 grid gap-6 lg:grid-cols-2">
      <div>
        <p className="mb-3 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          noun only · the verb defaults
        </p>
        <BarStrip query={QUERIES.chrome} />
      </div>
      <div>
        <p className="mb-3 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          free text · sessions, windows, screen text
        </p>
        <BarStrip query={QUERIES.lattices} />
      </div>
    </div>
  );
}

function NavigationComparison() {
  return (
    <>
      <div className="mt-10 grid gap-x-12 gap-y-6 sm:grid-cols-2">
        <NoteColumn label="What the labeled sidebar costs" notes={NAV_NOTES.sidebar} />
        <NoteColumn label="What the toolbar buys" notes={NAV_NOTES.toolbar} accent />
      </div>

      <section className="mt-10">
        <h3 className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          Where the status bar went
        </h3>
        <dl className="mt-4 divide-y divide-studio-edge border-y border-studio-edge">
          {STATUS_MOVES.map(([was, now]) => (
            <div key={was} className="grid gap-2 py-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)] sm:gap-8">
              <dt className="font-mono text-[11px] leading-relaxed text-studio-ink-faint">{was}</dt>
              <dd className="text-[13.5px] leading-relaxed text-studio-ink">{now}</dd>
            </div>
          ))}
        </dl>
      </section>
    </>
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
            studio · shell · second pass
          </p>
          <h1 className="mt-2 max-w-[18ch] font-sans text-4xl font-medium leading-[1.05] tracking-tight text-studio-ink sm:text-5xl">
            Lattices is a shortcut, not a dashboard.
          </h1>
          <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
            A second, independent pass on the same four surfaces, meant to be read beside{" "}
            <a
              href="/studio/studies/shell"
              className="underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
            >
              the first
            </a>
            . Where that one made the app read as a place — a sidebar, a title bar, tables — this
            one makes it read as a thing you summon: one line at the top that already knows what
            you were looking at, the desktop drawn instead of listed, and no chrome the page has
            to carry once the work is done. Same features; every call is defended in the ledger.
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
                href={`${BASE}/${ex.slug}`}
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
          The app is opened for a moment, to do one thing to the desktop, and then dismissed.
          Every surface is judged on how little stands between opening it and that one thing —
          and on whether what's left on screen afterwards was worth keeping.
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
          source · BrowseMenu.swift · UnifiedCommandBarState.swift · CommandModeState.swift · AppShellView.swift · UI/Theme.swift
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
            href={BASE}
            className="underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
          >
            ← {entry.label}
          </a>
          <span className="px-2 text-studio-edge">/</span>
          <span>{ex.eyebrow}</span>
          <span className="px-2 text-studio-edge">/</span>
          <a
            href={`/studio/studies/shell/${ex.slug}`}
            className="underline decoration-studio-edge underline-offset-4 hover:text-studio-ink hover:decoration-studio-ink"
          >
            first pass ↗
          </a>
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
          href={`${BASE}/${prev.slug}`}
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
          href={`${BASE}/${next.slug}`}
          className="flex flex-col gap-1 border border-studio-edge p-4 text-right transition-colors hover:border-studio-ink-faint"
        >
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            next · {next.eyebrow} →
          </span>
          <span className="font-sans text-[15px] text-studio-ink">{next.title}</span>
        </a>
      ) : (
        <a
          href={BASE}
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
        <a className="underline" href={BASE}>
          ← back to second-pass index
        </a>
      </p>
    </main>
  );
}
