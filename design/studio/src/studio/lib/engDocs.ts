export type StudioStatus = "proposed" | "accepted" | "in-flight" | "shipped";

export interface EngDocEntry {
  slug: string;
  title: string;
  blurb?: string;
  /** Path relative to repo root, used by the content loader. */
  sourcePath: string;
  status?: StudioStatus;
  /** Stable id for ordering inside the proposals bucket. */
  proposalId?: string;
}

export interface EngDocGroup {
  key: string;
  label: string;
  entries: EngDocEntry[];
}

export const ENG_DOC_GROUPS: EngDocGroup[] = [
  {
    key: "protocols",
    label: "Protocols",
    entries: [
      {
        slug: "voice-command-protocol",
        title: "Voice command protocol",
        blurb: "Wire format between lattices and TalkieAgent.",
        sourcePath: "docs/voice-command-protocol.md",
      },
      {
        slug: "voice-error-model",
        title: "Voice error model",
        blurb: "Error taxonomy and recovery paths for voice turns.",
        sourcePath: "docs/voice-error-model.md",
      },
      {
        slug: "api",
        title: "Daemon API",
        blurb: "WebSocket method surface — windows, terminals, ocr, intents.",
        sourcePath: "docs/api.md",
      },
      {
        slug: "tiling-reference",
        title: "Tiling reference",
        blurb: "Window tiling positions, presets, and intent mapping.",
        sourcePath: "docs/tiling-reference.md",
      },
      {
        slug: "agent-execution-plan",
        title: "Agent execution plan",
        blurb: "How agent layer composes intents and resolves them.",
        sourcePath: "docs/agent-execution-plan.md",
      },
    ],
  },
  {
    key: "concepts",
    label: "The system",
    entries: [
      {
        slug: "overview",
        title: "Overview",
        sourcePath: "docs/overview.md",
      },
      {
        slug: "concepts",
        title: "Core concepts",
        sourcePath: "docs/concepts.md",
      },
      {
        slug: "layers",
        title: "System layers",
        sourcePath: "docs/layers.md",
      },
      {
        slug: "agents",
        title: "Agents",
        sourcePath: "docs/agents.md",
      },
    ],
  },
  {
    key: "proposals",
    label: "Plans",
    entries: [
      {
        slug: "lat-001-gesture-visual-customization",
        title: "Gesture visual customization",
        proposalId: "LAT-001",
        sourcePath: "docs/proposals/LAT-001-gesture-visual-customization.md",
        status: "accepted",
      },
      {
        slug: "lat-002-shared-overlay-canvas",
        title: "Shared overlay canvas",
        proposalId: "LAT-002",
        sourcePath: "docs/proposals/LAT-002-shared-overlay-canvas.md",
        status: "accepted",
      },
      {
        slug: "lat-003-menu-bar-controller-architecture",
        title: "Menu bar controller architecture",
        proposalId: "LAT-003",
        sourcePath: "docs/proposals/LAT-003-menu-bar-controller-architecture.md",
        status: "in-flight",
      },
      {
        slug: "lat-004-interactive-overlay-actors",
        title: "Interactive overlay actors",
        proposalId: "LAT-004",
        sourcePath: "docs/proposals/LAT-004-interactive-overlay-actors.md",
        status: "proposed",
      },
    ],
  },
];

const ENTRY_BY_SLUG = new Map<string, EngDocEntry>();
const ENTRY_BY_SOURCE_PATH = new Map<string, EngDocEntry>();
for (const group of ENG_DOC_GROUPS) {
  for (const entry of group.entries) {
    ENTRY_BY_SLUG.set(entry.slug, entry);
    ENTRY_BY_SOURCE_PATH.set(entry.sourcePath, entry);
  }
}

export function findEntryBySlug(slug: string): EngDocEntry | undefined {
  return ENTRY_BY_SLUG.get(slug);
}

export function findEntryBySourcePath(path: string): EngDocEntry | undefined {
  return ENTRY_BY_SOURCE_PATH.get(path);
}
