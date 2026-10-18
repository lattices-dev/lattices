"use client";

import { BAppIcon, BI, BKbd, PlaceGlyph, type BAppKey, type BIconName, type BPlace } from "./_b";

/* ============================================================
   The bar. One line at the top of Home that reads what you typed as a
   sentence — verb · target · place — and shows, on every result row, what
   ↵ will do to it. The app already resolves this (UnifiedCommandBarState.
   nlMatch / nlSpec); the mock puts the resolution where you can see it.
   ============================================================ */

export type Role = "verb" | "noun" | "place" | "free";

export interface Token {
  word: string;
  role: Role;
}

export interface BResult {
  id: string;
  icon: BIconName | { app: BAppKey };
  lead: string;
  sub: string;
  /** What ↵ does to this row. */
  verb: string;
  place?: BPlace;
  ocr?: { before: string; hit: string; after: string };
}

export interface BResultGroup {
  label: string;
  items: BResult[];
}

export interface BQuery {
  id: string;
  tokens: Token[];
  /** What ↵ does — echoed on the bar's trailing edge. */
  primary: string;
  /** ↵ changes the desktop (a verb was recognised), as opposed to focusing a result. */
  acts: boolean;
  /** ⌘↵ scope, when the query resolves to more than one target. */
  all?: string;
  groups: BResultGroup[];
}

const CHROME_WINDOWS = (verb: string, place?: BPlace): BResult[] => [
  {
    id: "c1",
    icon: { app: "chrome" },
    lead: "Chrome — lattices.dev / Docs",
    sub: "Studio · 1 Build · front",
    verb,
    place,
  },
  {
    id: "c2",
    icon: { app: "chrome" },
    lead: "Chrome — arach/lattices · Pull request #212",
    sub: "Studio · 2 Review",
    verb,
    place,
  },
  {
    id: "c3",
    icon: { app: "chrome" },
    lead: "Chrome — Scout dashboard",
    sub: "Built-in · 1 Build",
    verb,
    place,
  },
];

export const QUERIES = {
  chrome: {
    id: "chrome",
    tokens: [{ word: "chrome", role: "noun" }],
    primary: "Focus",
    acts: false,
    groups: [
      { label: "Windows", items: CHROME_WINDOWS("Focus") },
      {
        label: "Apps",
        items: [{ id: "c4", icon: "windows", lead: "Chrome", sub: "3 windows · 2 displays", verb: "Activate" }],
      },
    ],
  },
  tile: {
    id: "tile",
    tokens: [
      { word: "tile", role: "verb" },
      { word: "chrome", role: "noun" },
      { word: "left", role: "place" },
    ],
    primary: "Tile left",
    acts: true,
    all: "Tile all 3 left",
    groups: [{ label: "Windows", items: CHROME_WINDOWS("Tile left", "left") }],
  },
  lattices: {
    id: "lattices",
    tokens: [{ word: "lattices", role: "free" }],
    primary: "Focus",
    acts: false,
    groups: [
      {
        label: "Sessions",
        items: [
          {
            id: "l1",
            icon: "play",
            lead: "lattices",
            sub: "~/dev/lattices · tmux · 4 panes",
            verb: "Attach",
          },
        ],
      },
      {
        label: "Windows",
        items: [
          {
            id: "l2",
            icon: { app: "xcode" },
            lead: "Xcode — AppShellView.swift",
            sub: "Studio · 1 Build · ~/dev/lattices/apps/mac",
            verb: "Focus",
          },
          {
            id: "l3",
            icon: { app: "ghostty" },
            lead: "Ghostty — swift build -c release",
            sub: "Studio · 1 Build · lattices:build",
            verb: "Focus",
          },
          {
            id: "l4",
            icon: { app: "ghostty" },
            lead: "Ghostty — bun bin/lattices.ts search vox --deep",
            sub: "Studio · 1 Build · lattices:cli",
            verb: "Focus",
          },
          {
            id: "l5",
            icon: { app: "chrome" },
            lead: "Chrome — lattices.dev / Docs",
            sub: "Studio · 1 Build · front",
            verb: "Focus",
          },
          {
            id: "l6",
            icon: { app: "slack" },
            lead: "Slack — #lattices-dev",
            sub: "Built-in · 2 Review",
            verb: "Focus",
          },
        ],
      },
      {
        label: "Screen text",
        items: [
          {
            id: "l7",
            icon: { app: "ghostty" },
            lead: "Ghostty — swift build -c release",
            sub: "",
            verb: "Focus",
            ocr: { before: "Compiling ", hit: "Lattices", after: " (204 sources) · AppShellView.swift:118 warning" },
          },
          {
            id: "l8",
            icon: { app: "chrome" },
            lead: "Chrome — arach/lattices · Pull request #212",
            sub: "",
            verb: "Focus",
            ocr: { before: "18 files changed · ", hit: "lattices", after: "/apps/mac/Sources/AppShell/HomeDashboardView.swift" },
          },
        ],
      },
    ],
  },
} satisfies Record<string, BQuery>;

export function firstResult(query: BQuery): string {
  return query.groups[0]?.items[0]?.id ?? "";
}

export function CommandBar({ query }: { query?: BQuery }) {
  const hasVerb = query?.tokens.some((t) => t.role === "verb") ?? false;
  const cta = query ? (query.acts ? " bs-cta--act" : " bs-cta--go") : "";

  return (
    <div className={`bs-bar${query ? " bs-bar--live" : ""}`}>
      <BI name={hasVerb ? "command" : "search"} className="bs-icon bs-bar__glyph" />

      <span className="bs-bar__text">
        {query ? (
          <>
            {query.tokens.map((t, i) => (
              <span key={i} className={`bs-tok bs-tok--${t.role}`}>
                {t.word}
              </span>
            ))}
            <span className="bs-bar__caret" />
          </>
        ) : (
          <span className="bs-bar__ph">Search, tile, or / for a command</span>
        )}
      </span>

      {query ? (
        <span className="bs-bar__read">
          <BKbd>↵</BKbd>
          {query.primary}
        </span>
      ) : null}

      <span className={`bs-cta${cta}`} aria-hidden="true">
        <BI name={query ? "enter" : "mic"} />
      </span>
    </div>
  );
}

export function ResultList({
  query,
  active,
  onActive,
}: {
  query: BQuery;
  active: string;
  onActive?: (id: string) => void;
}) {
  return (
    <div className="bs-results">
      {query.groups.map((group) => (
        <div key={group.label}>
          <p className="bs-results__group">
            {group.label}
            <span>{group.items.length}</span>
          </p>
          {group.items.map((r) => (
            <button
              key={r.id}
              type="button"
              className={`bs-res${active === r.id ? " bs-res--on" : ""}`}
              onMouseEnter={onActive ? () => onActive(r.id) : undefined}
              onFocus={onActive ? () => onActive(r.id) : undefined}
              onClick={onActive ? () => onActive(r.id) : undefined}
            >
              {typeof r.icon === "string" ? <BI name={r.icon} /> : <BAppIcon app={r.icon.app} />}
              <span className="bs-res__text">
                <span className="bs-res__lead">{r.lead}</span>
                <span className="bs-res__sub">
                  {r.ocr ? (
                    <>
                      {r.ocr.before}
                      <b>{r.ocr.hit}</b>
                      {r.ocr.after}
                    </>
                  ) : (
                    r.sub
                  )}
                </span>
              </span>
              <span className="bs-res__verb">
                {r.place ? <PlaceGlyph place={r.place} /> : null}
                {r.verb}
              </span>
            </button>
          ))}
        </div>
      ))}
    </div>
  );
}

/** The four keys. Nothing else is listed. */
export function ResultKeys({ query }: { query: BQuery }) {
  return (
    <div className="bs-keys">
      <span>
        <BKbd>↵</BKbd> {query.primary}
      </span>
      {query.all ? (
        <span>
          <BKbd>⌘↵</BKbd> {query.all}
        </span>
      ) : null}
      <span>
        <BKbd>⇥</BKbd> Next word
      </span>
      <span style={{ marginLeft: "auto" }}>
        <BKbd>esc</BKbd> Clear
      </span>
    </div>
  );
}
