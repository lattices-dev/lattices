"use client";

/**
 * Mocked desktop scenarios for HandsoffStudio.
 *
 * Each scenario describes a realistic desktop state — windows, terminals, displays —
 * that can be sent to `assistant.preview` as a snapshot override. Lets us exercise the
 * agent without touching the live desktop.
 *
 * The canonical shape lives in this file. `toWorkerSnapshot()` adapts to the
 * `DesktopSnapshot` shape that `bin/assistant-intelligence.ts` consumes.
 */

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface ScenarioWindow {
  wid: number;
  app: string;
  title: string;
  frame: Rect;
  onScreen: boolean;
  zIndex: number;
  displayIndex: number;
  session?: string;
}

export interface ScenarioTerminal {
  app: string;
  displayName?: string;
  tabTitle?: string;
  cwd?: string;
  tmuxSession?: string;
  hasClaude?: boolean;
  windowId?: number;
}

export interface ScenarioDisplay {
  displayIndex: number;
  displayId: string;
  name: string;
  width: number;
  height: number;
  isMain: boolean;
  currentSpaceId: number;
  spaces: { id: number; index: number; isCurrent: boolean }[];
}

export interface Scenario {
  id: string;
  name: string;
  blurb: string;
  windows: ScenarioWindow[];
  terminals: ScenarioTerminal[];
  displays: ScenarioDisplay[];
  stageManager: boolean;
  smGrouping?: string;
  currentLayer?: string;
  tmuxSessions?: string[];
}

function display(i: number, name: string, w: number, h: number, isMain = false): ScenarioDisplay {
  return {
    displayIndex: i,
    displayId: `display-${i}-${name.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`,
    name,
    width: w,
    height: h,
    isMain,
    currentSpaceId: 100 + i,
    spaces: [{ id: 100 + i, index: 1, isCurrent: true }],
  };
}

function frame(x: number, y: number, w: number, h: number): Rect {
  return { x, y, w, h };
}

// ── Scenario 1: Cluttered solo ───────────────────────────────────────────
// A single 14" MacBook screen with 12 windows piled on top of each other.
// Tests: distribute, choreography, "make breathing room" prompts.

const macbook14 = display(0, "MacBook Pro 14\"", 1512, 982, true);

const clutteredSolo: Scenario = {
  id: "cluttered-solo",
  name: "Cluttered solo",
  blurb: "Single 14\" laptop, 12 windows stacked. Cleanup territory.",
  displays: [macbook14],
  stageManager: false,
  windows: [
    { wid: 8001, app: "Google Chrome", title: "GitHub · lattices/lattices", frame: frame(120, 60, 1280, 820), onScreen: true, zIndex: 0, displayIndex: 0 },
    { wid: 8002, app: "Google Chrome", title: "localhost:5173 — Studio", frame: frame(180, 100, 1280, 820), onScreen: true, zIndex: 1, displayIndex: 0 },
    { wid: 8003, app: "Google Chrome", title: "Vercel AI SDK Docs", frame: frame(240, 140, 1200, 800), onScreen: true, zIndex: 2, displayIndex: 0 },
    { wid: 8004, app: "iTerm2", title: "arach@air · ~/dev/lattices · zsh", frame: frame(0, 0, 900, 600), onScreen: true, zIndex: 3, displayIndex: 0, session: "lattices" },
    { wid: 8005, app: "iTerm2", title: "arach@air · ~/dev/scout · claude", frame: frame(60, 40, 900, 600), onScreen: true, zIndex: 4, displayIndex: 0, session: "scout" },
    { wid: 8006, app: "iTerm2", title: "arach@air · ~/dev/lattices · bun dev", frame: frame(120, 80, 900, 600), onScreen: true, zIndex: 5, displayIndex: 0, session: "lattices-dev" },
    { wid: 8007, app: "iTerm2", title: "arach@air · ~/dev/lattices · log tail", frame: frame(180, 120, 900, 600), onScreen: true, zIndex: 6, displayIndex: 0, session: "lattices-logs" },
    { wid: 8008, app: "Slack", title: "Slack — #lattices", frame: frame(420, 200, 900, 600), onScreen: true, zIndex: 7, displayIndex: 0 },
    { wid: 8009, app: "Notion", title: "Lattices roadmap", frame: frame(280, 180, 1100, 700), onScreen: true, zIndex: 8, displayIndex: 0 },
    { wid: 8010, app: "Finder", title: "lattices", frame: frame(60, 100, 800, 500), onScreen: true, zIndex: 9, displayIndex: 0 },
    { wid: 8011, app: "Visual Studio Code", title: "HandsoffStudio.tsx — lattices", frame: frame(80, 60, 1300, 850), onScreen: true, zIndex: 10, displayIndex: 0 },
    { wid: 8012, app: "Music", title: "Music", frame: frame(900, 500, 500, 400), onScreen: true, zIndex: 11, displayIndex: 0 },
  ],
  terminals: [
    { app: "iTerm2", displayName: "iTerm2 · lattices", tabTitle: "zsh", cwd: "/Users/arach/dev/lattices", tmuxSession: "lattices", hasClaude: false, windowId: 8004 },
    { app: "iTerm2", displayName: "iTerm2 · scout", tabTitle: "claude", cwd: "/Users/arach/dev/scout", tmuxSession: "scout", hasClaude: true, windowId: 8005 },
    { app: "iTerm2", displayName: "iTerm2 · bun dev", tabTitle: "bun dev", cwd: "/Users/arach/dev/lattices/design/studio", tmuxSession: "lattices-dev", hasClaude: false, windowId: 8006 },
    { app: "iTerm2", displayName: "iTerm2 · logs", tabTitle: "tail -f", cwd: "/Users/arach/.lattices", tmuxSession: "lattices-logs", hasClaude: false, windowId: 8007 },
  ],
  tmuxSessions: ["lattices", "scout", "lattices-dev", "lattices-logs"],
  currentLayer: "default",
};

// ── Scenario 2: Multi-monitor dev ────────────────────────────────────────
// Three displays: 14" laptop main, 34" ultrawide, vertical 24". Lots of cwd
// signal to exercise topic-clustering prompts.

const ultrawide = display(1, "Dell U3415W 34\"", 3440, 1440);
const vertical = display(2, "Dell P2415Q vertical", 1200, 1920);

const multiMonitorDev: Scenario = {
  id: "multi-monitor-dev",
  name: "Multi-monitor dev",
  blurb: "14\" laptop + 34\" ultrawide + vertical 24\". 18 windows spread across.",
  displays: [macbook14, ultrawide, vertical],
  stageManager: false,
  windows: [
    // Main (laptop) — coordination
    { wid: 9001, app: "Slack", title: "Slack — #engineering", frame: frame(0, 0, 1512, 982), onScreen: true, zIndex: 0, displayIndex: 0 },
    { wid: 9002, app: "Google Calendar", title: "Today · 3 meetings", frame: frame(60, 100, 1100, 700), onScreen: true, zIndex: 5, displayIndex: 0 },

    // Ultrawide — primary coding surface
    { wid: 9100, app: "Visual Studio Code", title: "HandsoffStudio.tsx — lattices", frame: frame(0, 0, 1720, 1440), onScreen: true, zIndex: 0, displayIndex: 1 },
    { wid: 9101, app: "Google Chrome", title: "localhost:5173 — Studio", frame: frame(1720, 0, 1720, 720), onScreen: true, zIndex: 1, displayIndex: 1 },
    { wid: 9102, app: "Google Chrome", title: "localhost:9091 — Daemon dashboard", frame: frame(1720, 720, 1720, 720), onScreen: true, zIndex: 2, displayIndex: 1 },
    { wid: 9103, app: "iTerm2", title: "arach@air · ~/dev/lattices · bun dev", frame: frame(0, 0, 1146, 720), onScreen: true, zIndex: 3, displayIndex: 1, session: "lattices-dev" },
    { wid: 9104, app: "iTerm2", title: "arach@air · ~/dev/lattices · daemon", frame: frame(1146, 0, 1147, 720), onScreen: true, zIndex: 4, displayIndex: 1, session: "lattices-daemon" },
    { wid: 9105, app: "iTerm2", title: "arach@air · ~/dev/lattices · git", frame: frame(2293, 0, 1147, 720), onScreen: true, zIndex: 5, displayIndex: 1, session: "lattices-git" },

    // Vertical — reference + comms
    { wid: 9200, app: "Google Chrome", title: "Lattices PRs — GitHub", frame: frame(0, 0, 1200, 960), onScreen: true, zIndex: 0, displayIndex: 2 },
    { wid: 9201, app: "Notion", title: "Lattices roadmap", frame: frame(0, 960, 1200, 960), onScreen: true, zIndex: 1, displayIndex: 2 },
    { wid: 9202, app: "Linear", title: "INGEST — Pipeline backlog", frame: frame(0, 0, 1200, 1920), onScreen: false, zIndex: 10, displayIndex: 2 },

    // Off-screen (other spaces)
    { wid: 9300, app: "Spotify", title: "Spotify", frame: frame(0, 0, 1200, 800), onScreen: false, zIndex: 99, displayIndex: 0 },
    { wid: 9301, app: "Finder", title: "Downloads", frame: frame(100, 100, 800, 500), onScreen: false, zIndex: 99, displayIndex: 0 },
    { wid: 9302, app: "Google Chrome", title: "Scout — companion-sync design doc", frame: frame(0, 0, 1200, 800), onScreen: false, zIndex: 99, displayIndex: 1 },
    { wid: 9303, app: "iTerm2", title: "arach@air · ~/dev/scout · claude", frame: frame(0, 0, 1000, 700), onScreen: false, zIndex: 99, displayIndex: 0, session: "scout" },
  ],
  terminals: [
    { app: "iTerm2", displayName: "iTerm2 · lattices-dev", tabTitle: "bun dev", cwd: "/Users/arach/dev/lattices/design/studio", tmuxSession: "lattices-dev", hasClaude: false, windowId: 9103 },
    { app: "iTerm2", displayName: "iTerm2 · lattices-daemon", tabTitle: "daemon logs", cwd: "/Users/arach/dev/lattices", tmuxSession: "lattices-daemon", hasClaude: false, windowId: 9104 },
    { app: "iTerm2", displayName: "iTerm2 · lattices-git", tabTitle: "zsh", cwd: "/Users/arach/dev/lattices", tmuxSession: "lattices-git", hasClaude: false, windowId: 9105 },
    { app: "iTerm2", displayName: "iTerm2 · scout", tabTitle: "claude", cwd: "/Users/arach/dev/scout", tmuxSession: "scout", hasClaude: true, windowId: 9303 },
  ],
  tmuxSessions: ["lattices-dev", "lattices-daemon", "lattices-git", "scout"],
  currentLayer: "dev",
};

// ── Scenario 3: Mid-debugging ────────────────────────────────────────────
// A focused 2-display debugging session. Logs tailing, error dashboard,
// code file open. Some stale clutter to triage.

const dell27 = display(1, "Dell U2723QE 27\"", 2560, 1440);

const midDebugging: Scenario = {
  id: "mid-debugging",
  name: "Mid-debugging",
  blurb: "Hunting a prod bug. Logs left, Sentry middle, code right. A few stale windows in the way.",
  displays: [macbook14, dell27],
  stageManager: false,
  windows: [
    // Laptop — comms (Slack thread about the incident)
    { wid: 7001, app: "Slack", title: "Slack — #incidents · prod-api went 5xx at 14:02", frame: frame(0, 0, 1512, 982), onScreen: true, zIndex: 0, displayIndex: 0 },

    // Dell 27 — the actual investigation
    { wid: 7100, app: "iTerm2", title: "tail -f api.log · 14:02 spike", frame: frame(0, 0, 853, 1440), onScreen: true, zIndex: 0, displayIndex: 1, session: "api-logs" },
    { wid: 7101, app: "Google Chrome", title: "Sentry — POST /v1/sync 5xx spike", frame: frame(853, 0, 854, 720), onScreen: true, zIndex: 1, displayIndex: 1 },
    { wid: 7102, app: "Google Chrome", title: "Datadog — api latency p99", frame: frame(853, 720, 854, 720), onScreen: true, zIndex: 2, displayIndex: 1 },
    { wid: 7103, app: "Visual Studio Code", title: "sync_handler.rs — api", frame: frame(1707, 0, 853, 1440), onScreen: true, zIndex: 3, displayIndex: 1 },

    // Stale clutter — not part of the investigation
    { wid: 7200, app: "Google Chrome", title: "Twitter / X", frame: frame(400, 200, 900, 600), onScreen: true, zIndex: 10, displayIndex: 1 },
    { wid: 7201, app: "Spotify", title: "Spotify · Lo-fi beats", frame: frame(600, 400, 500, 400), onScreen: true, zIndex: 11, displayIndex: 1 },
    { wid: 7202, app: "Notion", title: "Personal · Grocery list", frame: frame(800, 100, 700, 500), onScreen: true, zIndex: 12, displayIndex: 0 },
  ],
  terminals: [
    { app: "iTerm2", displayName: "iTerm2 · api-logs", tabTitle: "tail -f api.log", cwd: "/Users/arach/dev/api", tmuxSession: "api-logs", hasClaude: false, windowId: 7100 },
  ],
  tmuxSessions: ["api-logs"],
  currentLayer: "default",
};

// ── Scenario 4: Empty desktop ────────────────────────────────────────────
// Bare-minimum state. Tests the agent's handling of empty/sparse worlds:
// "what's open?" answers, refusals when there's nothing to act on, scan/launch.

const emptyDesktop: Scenario = {
  id: "empty-desktop",
  name: "Empty desktop",
  blurb: "One Finder window on a single screen. Tests sparse-state handling and launch prompts.",
  displays: [macbook14],
  stageManager: false,
  windows: [
    { wid: 6001, app: "Finder", title: "Macintosh HD", frame: frame(200, 200, 900, 600), onScreen: true, zIndex: 0, displayIndex: 0 },
  ],
  terminals: [],
  tmuxSessions: [],
  currentLayer: "default",
};

export const scenarios: Scenario[] = [
  clutteredSolo,
  multiMonitorDev,
  midDebugging,
  emptyDesktop,
];

export const scenarioById: Record<string, Scenario> = Object.fromEntries(
  scenarios.map((s) => [s.id, s]),
);

/**
 * Adapt a Scenario to the `DesktopSnapshot` shape that the worker consumes
 * (see `bin/assistant-intelligence.ts`). Frames go from {x,y,w,h} to "x,y,w,h"
 * strings, terminals stay loose, displays become a flat `screens` array.
 */
export function toWorkerSnapshot(s: Scenario): Record<string, unknown> {
  return {
    windows: s.windows.map((w) => ({
      wid: w.wid,
      app: w.app,
      title: w.title,
      frame: `${w.frame.x},${w.frame.y},${w.frame.w},${w.frame.h}`,
      onScreen: w.onScreen,
      zIndex: w.zIndex,
      session: w.session,
    })),
    screens: s.displays.map((d) => ({ width: d.width, height: d.height, isMain: d.isMain })),
    stageManager: s.stageManager,
    smGrouping: s.smGrouping,
    terminals: s.terminals,
    tmuxSessions: (s.tmuxSessions ?? []).map((name) => ({ name })),
    currentLayer: s.currentLayer,
  };
}
