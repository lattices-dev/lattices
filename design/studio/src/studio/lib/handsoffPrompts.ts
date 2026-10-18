"use client";

/**
 * Prompt library for HandsoffStudio.
 *
 * Grouped by what muscle they exercise. Each prompt can declare `bestOn` —
 * scenarios where its answer will be most interesting. The UI uses that to
 * surface "highlighted" prompts when a scenario is picked.
 */

export type PromptBucket =
  | "discovery"
  | "placement"
  | "choreography"
  | "distribute"
  | "topic-cluster"
  | "multi-display"
  | "layer"
  | "spatial"
  | "highlight"
  | "open-ended";

export interface PromptEntry {
  text: string;
  bucket: PromptBucket;
  /** Intents this prompt is likely to elicit — purely descriptive. */
  exercises: string[];
  /** Scenario ids where this prompt produces especially good demo material. */
  bestOn?: string[];
}

export const buckets: { id: PromptBucket; label: string; blurb: string }[] = [
  { id: "discovery", label: "Discovery", blurb: "Read-only questions about what's on screen." },
  { id: "placement", label: "Placement", blurb: "Single window to a single position." },
  { id: "choreography", label: "Choreography", blurb: "Multiple windows moved in concert." },
  { id: "distribute", label: "Distribute", blurb: "Grid an app or region." },
  { id: "topic-cluster", label: "Topic clusters", blurb: "Group by project, cwd, or topic — where the layer idea lives." },
  { id: "multi-display", label: "Multi-display", blurb: "Cross-monitor moves and queries." },
  { id: "layer", label: "Layer state", blurb: "Save / switch / activate named layouts." },
  { id: "spatial", label: "Spatial repair", blurb: "Spread, restore, undo." },
  { id: "highlight", label: "Highlight & find", blurb: "Identify a window without moving it." },
  { id: "open-ended", label: "Open-ended", blurb: "Fuzzy human asks — tests judgement." },
];

export const prompts: PromptEntry[] = [
  // ── Discovery ────────────────────────────────────────────────
  { text: "what windows do I have?", bucket: "discovery", exercises: ["list_windows"] },
  { text: "what project has the most stuff open?", bucket: "discovery", exercises: ["list_windows"], bestOn: ["multi-monitor-dev", "cluttered-solo"] },
  { text: "where am I running Claude right now?", bucket: "discovery", exercises: ["list_sessions"], bestOn: ["multi-monitor-dev", "cluttered-solo"] },
  { text: "what's frontmost?", bucket: "discovery", exercises: [] },
  { text: "how many terminal tabs do I have?", bucket: "discovery", exercises: ["list_sessions"], bestOn: ["multi-monitor-dev"] },
  { text: "is there anything Slack-related open?", bucket: "discovery", exercises: ["search"] },

  // ── Placement ───────────────────────────────────────────────
  { text: "tile Chrome to the left", bucket: "placement", exercises: ["tile_window"] },
  { text: "maximize whatever's frontmost", bucket: "placement", exercises: ["tile_window"] },
  { text: "put VS Code bottom-right", bucket: "placement", exercises: ["tile_window"], bestOn: ["cluttered-solo"] },
  { text: "center the Finder window", bucket: "placement", exercises: ["tile_window"], bestOn: ["empty-desktop", "cluttered-solo"] },
  { text: "snap Slack to the top-right corner", bucket: "placement", exercises: ["tile_window"] },

  // ── Choreography ────────────────────────────────────────────
  { text: "Chrome left, iTerm right", bucket: "choreography", exercises: ["tile_window"] },
  { text: "set up for coding — terminal left, browser right, hide Slack", bucket: "choreography", exercises: ["tile_window", "hide"] },
  { text: "split the front two windows side by side", bucket: "choreography", exercises: ["tile_window"], bestOn: ["cluttered-solo"] },
  { text: "put me in writing mode — only Notion visible, hide the rest", bucket: "choreography", exercises: ["tile_window", "hide"], bestOn: ["cluttered-solo"] },
  { text: "swap Chrome and iTerm", bucket: "choreography", exercises: ["swap"] },

  // ── Distribute ──────────────────────────────────────────────
  { text: "grid my iTerm windows", bucket: "distribute", exercises: ["distribute"], bestOn: ["cluttered-solo", "multi-monitor-dev"] },
  { text: "organize my Chrome windows on the left half", bucket: "distribute", exercises: ["distribute"], bestOn: ["cluttered-solo"] },
  { text: "spread the terminals out, they're all stacked", bucket: "distribute", exercises: ["distribute"], bestOn: ["cluttered-solo"] },
  { text: "put my notes app somewhere out of the way", bucket: "distribute", exercises: ["tile_window", "move_to_display"] },

  // ── Topic clusters ──────────────────────────────────────────
  { text: "group everything from the lattices project together", bucket: "topic-cluster", exercises: ["tile_window", "distribute"], bestOn: ["multi-monitor-dev", "cluttered-solo"] },
  { text: "find every window touching the studio and put them in quadrants", bucket: "topic-cluster", exercises: ["tile_window"], bestOn: ["multi-monitor-dev"] },
  { text: "show me all my localhost windows on the left", bucket: "topic-cluster", exercises: ["tile_window", "distribute"], bestOn: ["multi-monitor-dev"] },
  { text: "anything to do with the incident, put it on my main monitor", bucket: "topic-cluster", exercises: ["move_to_display", "tile_window"], bestOn: ["mid-debugging"] },
  { text: "consolidate the scout project — everything Scout-related on one screen", bucket: "topic-cluster", exercises: ["move_to_display", "tile_window"], bestOn: ["multi-monitor-dev"] },

  // ── Multi-display ───────────────────────────────────────────
  { text: "move Chrome to my second display", bucket: "multi-display", exercises: ["move_to_display"], bestOn: ["multi-monitor-dev", "mid-debugging"] },
  { text: "what's on my second monitor?", bucket: "multi-display", exercises: ["list_windows"], bestOn: ["multi-monitor-dev", "mid-debugging"] },
  { text: "everything Slack-related on the laptop screen please", bucket: "multi-display", exercises: ["move_to_display"], bestOn: ["multi-monitor-dev", "mid-debugging"] },
  { text: "move the stale windows off the dell to make room", bucket: "multi-display", exercises: ["move_to_display", "hide"], bestOn: ["mid-debugging"] },

  // ── Layer state ─────────────────────────────────────────────
  { text: "save this as deep-focus", bucket: "layer", exercises: ["create_layer"] },
  { text: "switch to the review layer", bucket: "layer", exercises: ["switch_layer"] },
  { text: "go to layer 2", bucket: "layer", exercises: ["switch_layer"] },
  { text: "name this layout 'incident-mode'", bucket: "layer", exercises: ["create_layer"], bestOn: ["mid-debugging"] },

  // ── Spatial repair ──────────────────────────────────────────
  { text: "undo that", bucket: "spatial", exercises: ["undo"] },
  { text: "put it back", bucket: "spatial", exercises: ["undo"] },
  { text: "make some breathing room", bucket: "spatial", exercises: ["distribute", "hide"], bestOn: ["cluttered-solo"] },
  { text: "I'm getting on a call in 2 minutes — clear the deck", bucket: "spatial", exercises: ["hide", "distribute"], bestOn: ["cluttered-solo", "mid-debugging"] },

  // ── Highlight & find ────────────────────────────────────────
  { text: "which one is the lattices terminal?", bucket: "highlight", exercises: ["highlight"], bestOn: ["multi-monitor-dev", "cluttered-solo"] },
  { text: "highlight Chrome", bucket: "highlight", exercises: ["highlight"] },
  { text: "find my mouse", bucket: "highlight", exercises: ["find_mouse"] },
  { text: "summon the cursor", bucket: "highlight", exercises: ["summon_mouse"] },

  // ── Open-ended ──────────────────────────────────────────────
  { text: "I need to write something — set me up", bucket: "open-ended", exercises: ["tile_window", "hide"], bestOn: ["cluttered-solo"] },
  { text: "what was I working on?", bucket: "open-ended", exercises: ["list_windows", "list_sessions"], bestOn: ["multi-monitor-dev", "mid-debugging"] },
  { text: "kill anything I'm not using", bucket: "open-ended", exercises: ["hide", "kill"], bestOn: ["cluttered-solo"] },
  { text: "I'm done debugging — back to normal", bucket: "open-ended", exercises: ["switch_layer", "hide"], bestOn: ["mid-debugging"] },
];

export function promptsByBucket(): Map<PromptBucket, PromptEntry[]> {
  const map = new Map<PromptBucket, PromptEntry[]>();
  for (const b of buckets) map.set(b.id, []);
  for (const p of prompts) map.get(p.bucket)?.push(p);
  return map;
}

export function isHighlighted(p: PromptEntry, scenarioId: string | null): boolean {
  if (!scenarioId) return false;
  return p.bestOn?.includes(scenarioId) ?? false;
}
