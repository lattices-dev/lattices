import { defineStudio, type StudioPage } from "studio/registry";
import { ENG_DOC_GROUPS } from "@/studio/lib/engDocs";

/**
 * Lattices studio registry — the single source of truth for the sidebar nav.
 * Each study is one route; add an entry here and it surfaces automatically.
 */

export type Bucket = "foundations" | "studies" | "docs";
export type Surface = "macos" | "cross" | "linux";
export type Status = "concept" | "in-flight" | "shipped";

export type LatticesPage = StudioPage<Bucket, Surface, Status>;

export const HOME_HREF = "/studio";

const studioPages: readonly LatticesPage[] = [
  {
    href: HOME_HREF,
    label: "Lattices Studio",
    bucket: "foundations",
    surface: "macos",
    status: "concept",
    blurb:
      "Design surface for the Lattices macOS workspace manager — studies land here before SwiftUI gets touched.",
  },
  {
    href: "/studio/studies/shell",
    label: "Shell redesign — first pass",
    bucket: "studies",
    surface: "macos",
    status: "concept",
    blurb:
      "Navigation, Home, Windows, and the navigator, reworked as a place you go: a labeled rail, a per-page title bar, tables with column headers, and a status bar that holds still.",
    source: [
      "apps/mac/Sources/AppShell/HomeDashboardView.swift",
      "apps/mac/Sources/AppShell/AppShellView.swift",
    ],
  },
  {
    href: "/studio/studies/shell-b",
    label: "Shell redesign — second pass",
    bucket: "studies",
    surface: "macos",
    status: "concept",
    blurb:
      "The same four surfaces taken independently — a comparable, not a refinement. Home is the empty query, Windows becomes the desktop drawn to scale, and the sidebar and status bar go away.",
    source: [
      "apps/mac/Sources/Core/Overlays/UnifiedCommandBar/BrowseMenu.swift",
      "apps/mac/Sources/Core/Overlays/CommandMode/CommandModeState.swift",
    ],
  },
  {
    href: "/studio/studies/tiling",
    label: "Tiling playground",
    bucket: "studies",
    surface: "macos",
    status: "in-flight",
    blurb:
      "Every placement preset on a real screen — preset gallery, snap zones, the auto-grid, coordinate flips, and the placement spec the daemon actually receives.",
    source: ["apps/mac/Sources/Core/Workspace/WindowTiler.swift"],
  },
  {
    href: "/studio/studies/intents",
    label: "Intent Explorer",
    bucket: "studies",
    surface: "macos",
    status: "in-flight",
    blurb:
      "The closed set — every phrase guaranteed to bind to an intent, run live against the daemon.",
    source: ["apps/mac/Sources/Core/Intents/IntentEngine.swift"],
  },
  {
    href: "/studio/studies/handsoff",
    label: "Handsoff",
    bucket: "studies",
    surface: "macos",
    status: "in-flight",
    blurb:
      "The open-ended path — model in the loop. Scenario-driven mock executor over the real terminal and window APIs.",
    source: ["apps/mac/Sources/Core/Handsoff/"],
  },
  {
    href: "/studio/studies/cursor",
    label: "Cursor appearance",
    bucket: "studies",
    surface: "macos",
    status: "in-flight",
    blurb:
      "The desktop marker as a testable treatment — drive the synthetic cursor against the live daemon and compare appearances.",
    source: ["apps/mac/Sources/Core/Overlays/Cursor/"],
  },
  {
    href: "/studio/studies/nexus",
    label: "Nexus — command bar",
    bucket: "studies",
    surface: "macos",
    status: "concept",
    blurb:
      "One slim bar: search · /commands · voice → act inline or hand off to the assistant. Six states on the registration grid.",
    source: ["apps/mac/Sources/Core/Overlays/Nexus/"],
  },
  {
    href: "/studio/studies/deck-builder",
    label: "Deck Builder — companion cockpit",
    bucket: "studies",
    surface: "macos",
    status: "in-flight",
    blurb:
      "Span-aware grid editor for the companion deck: tap an empty cell to add, drag to move, pull the corner to span 2×1 / 2×2. Interactive prototype for the Mac-side builder — the iPad just receives the layout and renders it.",
    source: [
      "docs/companion-deck-builder-spec.md",
      "apps/mac/Sources/Core/Companion/LatticesCompanionCockpit.swift",
    ],
  },
  {
    href: "/studio/studies/space-bezel",
    label: "Space bezel — lattice mark variants",
    bucket: "studies",
    surface: "macos",
    status: "concept",
    blurb:
      "Three takes on the instant space-switch pill built on the 3×3 logo mechanic: matrix-as-map, matrix-as-arrow-glyph, and mark-only traversal. Press ←/→ to drive all three.",
    source: ["apps/mac/Sources/Core/Overlays/HUD/SpaceSwitchBezel.swift"],
  },
  {
    href: "/studio/studies/menubar",
    label: "Menubar popover — three passes",
    bucket: "studies",
    surface: "macos",
    status: "concept",
    blurb:
      "The menubar dropdown taken three ways at true popover scale: filter-first (a small command bar), status-up/chrome-down (context before actions), and rail+pane (a miniature Home window) — next to today's layout for comparison.",
    source: ["apps/mac/Sources/AppShell/MainView.swift"],
  },
  {
    href: "/studio/studies/action-definitions",
    label: "Action definitions — outcome editor",
    bucket: "studies",
    surface: "cross",
    status: "concept",
    blurb:
      "Define reusable workspace outcomes, resolve missing detail, preview the arrangement, and test safely before an action is made available to voice or remote controls.",
  },
  {
    href: "/studio/studies/cross-app-tabs",
    label: "Cross-app tabs — one topic, many tools",
    bucket: "studies",
    surface: "cross",
    status: "in-flight",
    blurb:
      "A native-window tab rail for grouping Chrome, terminal, and editor surfaces around one topic. Tabs preserve real app identity; Grid temporarily fans the same windows out for comparison.",
    source: [
      "apps/mac/Sources/Core/Workspace/LiveTabGroupStore.swift",
      "apps/mac/Sources/Core/Overlays/HUD/HUDWindowHints.swift",
    ],
  },
  {
    href: "/studio/studies/linux-command-center",
    label: "Linux command center — three directions",
    bucket: "studies",
    surface: "linux",
    status: "concept",
    blurb:
      "Lattices on Omarchy/Hyprland taken three ways: Mission Control (every space and window as an inventory), Flight Deck (one space to scale, keyboard first) and Operator Console (the lats CLI as the product). One local simulation drives all three.",
    source: ["bin/lattices.ts", "docs/layers.md"],
  },
  {
    href: "/studio/studies/product-family",
    label: "Product family — homepage insertion",
    bucket: "studies",
    surface: "cross",
    status: "concept",
    blurb:
      "A progressive homepage narrative where workspace, agents, Action, Blink, and Speech emerge in sequence, with earlier product-family surfaces retained for comparison.",
    source: [
      "apps/site/src/components/LandingPage.tsx",
      "apps/site/src/components/SiteChrome.tsx",
      "design/studio/public/product-family/board.html",
    ],
  },
];

/**
 * Engineering docs are their own bucket — one page per registered markdown file,
 * rendered by the Doc study and read off disk through /api/studio/eng/<slug>.
 */
const docPages: readonly LatticesPage[] = ENG_DOC_GROUPS.flatMap((group) =>
  group.entries.map((entry): LatticesPage => ({
    href: `/studio/eng/${entry.slug}`,
    // The proposal id already shows in the doc's own eyebrow; keeping it out of
    // the nav label stops long entries clipping in the fixed-width rail.
    label: entry.title,
    bucket: "docs",
    surface: "macos",
    status: entry.status === "shipped" ? "shipped" : entry.status === "in-flight" ? "in-flight" : "concept",
    blurb: entry.blurb,
    source: [entry.sourcePath],
  })),
);

export const pages: readonly LatticesPage[] = [...studioPages, ...docPages];

const defined = defineStudio({
  pages,
  surfaceOrder: ["macos", "cross", "linux"],
  surfaceLabels: { macos: "macOS", cross: "Cross-platform", linux: "Linux" },
  defaultSurface: "macos",
  buckets: [{ key: "foundations" }, { key: "studies" }, { key: "docs" }],
  statuses: {
    concept: { tone: "info", label: "CONCEPT" },
    "in-flight": { tone: "warn", label: "IN-FLIGHT" },
    shipped: { tone: "ok", label: "SHIPPED" },
  },
  iteration: {},
});

export const {
  registry,
  buckets: BUCKETS,
  statusColors: STATUS_COLORS,
  StatusPill,
  palette: statusPalette,
} = defined;

export { StatusPill as LatticesStatusPill };
