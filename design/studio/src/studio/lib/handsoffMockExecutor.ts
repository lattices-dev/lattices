"use client";

/**
 * Pure mock executor / planner for HandsoffStudio.
 *
 * `applyActions(scenario, actions)` returns a new scenario plus a per-action
 * log with a richly resolved plan: which windows are targeted, their before
 * and after frames, the display they land on, computed rects, warnings.
 *
 * The log is computed eagerly so the Actions pane can show what *would*
 * happen without the user clicking "commit". `applyActions` mutates a clone,
 * so callers decide whether to keep the new scenario (commit) or discard it.
 */

import type { Scenario, ScenarioWindow, Rect, ScenarioDisplay } from "./handsoffScenarios";

export interface Action {
  intent: string;
  slots?: Record<string, unknown>;
}

export interface TargetState {
  onScreen: boolean;
  displayIndex: number;
  frame?: Rect; // unknown when running against live snapshot adapter
}

export interface ResolvedTarget {
  wid: number;
  app: string;
  title?: string;
  before: TargetState;
  after?: TargetState;
  changed: boolean;
}

export interface ResolvedDisplay {
  index: number;
  name: string;
  width?: number;
  height?: number;
}

export interface ResolvedPlan {
  summary: string;
  targets: ResolvedTarget[];
  position?: string;
  display?: ResolvedDisplay;
  warnings: string[];
  /** True when we have full geometry (mock); false when only target resolution is possible (live). */
  geometryAvailable: boolean;
}

export interface ExecLogEntry {
  index: number;
  intent: string;
  slots: Record<string, unknown>;
  ok: boolean;
  note: string;
  plan: ResolvedPlan;
}

export interface ExecResult {
  scenario: Scenario;
  log: ExecLogEntry[];
}

// ── Position grammar ─────────────────────────────────────────────────────

const FRACTIONS: Record<string, { x: number; y: number; w: number; h: number }> = {
  left: { x: 0, y: 0, w: 0.5, h: 1 },
  right: { x: 0.5, y: 0, w: 0.5, h: 1 },
  top: { x: 0, y: 0, w: 1, h: 0.5 },
  bottom: { x: 0, y: 0.5, w: 1, h: 0.5 },
  "top-left": { x: 0, y: 0, w: 0.5, h: 0.5 },
  "top-right": { x: 0.5, y: 0, w: 0.5, h: 0.5 },
  "bottom-left": { x: 0, y: 0.5, w: 0.5, h: 0.5 },
  "bottom-right": { x: 0.5, y: 0.5, w: 0.5, h: 0.5 },
  "left-third": { x: 0, y: 0, w: 1 / 3, h: 1 },
  "center-third": { x: 1 / 3, y: 0, w: 1 / 3, h: 1 },
  "right-third": { x: 2 / 3, y: 0, w: 1 / 3, h: 1 },
  "top-left-third": { x: 0, y: 0, w: 1 / 3, h: 0.5 },
  "top-center-third": { x: 1 / 3, y: 0, w: 1 / 3, h: 0.5 },
  "top-right-third": { x: 2 / 3, y: 0, w: 1 / 3, h: 0.5 },
  "bottom-left-third": { x: 0, y: 0.5, w: 1 / 3, h: 0.5 },
  "bottom-center-third": { x: 1 / 3, y: 0.5, w: 1 / 3, h: 0.5 },
  "bottom-right-third": { x: 2 / 3, y: 0.5, w: 1 / 3, h: 0.5 },
  "first-fourth": { x: 0, y: 0, w: 0.25, h: 1 },
  "second-fourth": { x: 0.25, y: 0, w: 0.25, h: 1 },
  "third-fourth": { x: 0.5, y: 0, w: 0.25, h: 1 },
  "last-fourth": { x: 0.75, y: 0, w: 0.25, h: 1 },
  maximize: { x: 0, y: 0, w: 1, h: 1 },
  center: { x: 0.15, y: 0.15, w: 0.7, h: 0.7 },
};

const REGION_KEYS = new Set([
  "left", "right", "top", "bottom",
  "top-left", "top-right", "bottom-left", "bottom-right",
  "left-third", "center-third", "right-third",
]);

function rectFromPosition(position: string, display: { width: number; height: number }): Rect | null {
  const grid = position.match(/^(grid:)?(\d+)x(\d+):(\d+),(\d+)$/);
  if (grid) {
    const oneBased = !grid[1];
    const cols = Number(grid[2]);
    const rows = Number(grid[3]);
    let col = Number(grid[4]);
    let row = Number(grid[5]);
    if (oneBased) {
      col -= 1;
      row -= 1;
    }
    if (cols <= 0 || rows <= 0 || col < 0 || row < 0 || col >= cols || row >= rows) return null;
    return {
      x: Math.round((col / cols) * display.width),
      y: Math.round((row / rows) * display.height),
      w: Math.round(display.width / cols),
      h: Math.round(display.height / rows),
    };
  }
  const f = FRACTIONS[position];
  if (!f) return null;
  return {
    x: Math.round(f.x * display.width),
    y: Math.round(f.y * display.height),
    w: Math.round(f.w * display.width),
    h: Math.round(f.h * display.height),
  };
}

// ── Helpers ──────────────────────────────────────────────────────────────

function snapState(w: ScenarioWindow): TargetState {
  return {
    onScreen: w.onScreen,
    displayIndex: w.displayIndex,
    frame: { ...w.frame },
  };
}

function resolvedDisplay(d: ScenarioDisplay): ResolvedDisplay {
  return {
    index: d.displayIndex,
    name: d.name,
    width: d.width || undefined,
    height: d.height || undefined,
  };
}

function findWindowByWid(scn: Scenario, wid: unknown): ScenarioWindow | undefined {
  if (typeof wid !== "number") return undefined;
  return scn.windows.find((w) => w.wid === wid);
}

function findWindowByApp(scn: Scenario, app: unknown): ScenarioWindow | undefined {
  if (typeof app !== "string") return undefined;
  const needle = app.toLowerCase();
  return scn.windows
    .filter((w) => w.onScreen)
    .sort((a, b) => a.zIndex - b.zIndex)
    .find((w) => w.app.toLowerCase().includes(needle) || needle.includes(w.app.toLowerCase()));
}

function resolveTarget(scn: Scenario, slots: Record<string, unknown>): ScenarioWindow | undefined {
  return findWindowByWid(scn, slots.wid) ?? findWindowByApp(scn, slots.app);
}

function targetCard(w: ScenarioWindow, before: TargetState, after?: TargetState): ResolvedTarget {
  const changed = !!after && (
    after.onScreen !== before.onScreen ||
    after.displayIndex !== before.displayIndex ||
    !rectsEqual(after.frame, before.frame)
  );
  return {
    wid: w.wid,
    app: w.app,
    title: w.title,
    before,
    after,
    changed,
  };
}

function rectsEqual(a?: Rect, b?: Rect): boolean {
  if (!a || !b) return !a && !b;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
}

function makePlan(partial: Partial<ResolvedPlan> & Pick<ResolvedPlan, "summary">): ResolvedPlan {
  return {
    targets: [],
    warnings: [],
    geometryAvailable: true,
    ...partial,
  };
}

function entry(
  index: number,
  intent: string,
  slots: Record<string, unknown>,
  ok: boolean,
  note: string,
  plan: ResolvedPlan,
): ExecLogEntry {
  return { index, intent, slots, ok, note, plan };
}

// ── Action handlers ──────────────────────────────────────────────────────

function applyTileWindow(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const win = resolveTarget(scn, slots);
  const position = typeof slots.position === "string" ? slots.position : "";

  if (!win) {
    return entry(index, "tile_window", slots, false,
      `Couldn't resolve target.`,
      makePlan({
        summary: "Target window not found in the snapshot.",
        position: position || undefined,
        warnings: [unresolvedTargetWarning(slots)],
      }),
    );
  }
  if (!position) {
    return entry(index, "tile_window", slots, false,
      `${win.app}: no position specified.`,
      makePlan({
        summary: `Would tile ${win.app}, but no position was given.`,
        targets: [{
          wid: win.wid, app: win.app, title: win.title,
          before: snapState(win), changed: false,
        }],
        warnings: ["No position in slots."],
      }),
    );
  }

  const display = scn.displays[win.displayIndex];
  if (!display) {
    return entry(index, "tile_window", slots, false,
      `${win.app}: display ${win.displayIndex} missing.`,
      makePlan({
        summary: `Cannot resolve target display ${win.displayIndex}.`,
        targets: [{ wid: win.wid, app: win.app, title: win.title, before: snapState(win), changed: false }],
        warnings: [`Window claims display ${win.displayIndex} but scenario has ${scn.displays.length}.`],
      }),
    );
  }

  const rect = rectFromPosition(position, display);
  if (!rect) {
    return entry(index, "tile_window", slots, false,
      `Unknown position "${position}".`,
      makePlan({
        summary: `Position "${position}" not in the grammar.`,
        position,
        targets: [{ wid: win.wid, app: win.app, title: win.title, before: snapState(win), changed: false }],
        display: resolvedDisplay(display),
        warnings: [`Unknown position "${position}".`],
      }),
    );
  }

  const before = snapState(win);
  win.frame = rect;
  win.onScreen = true;
  const after = snapState(win);

  const warnings: string[] = [];
  if (before.onScreen === false) warnings.push("Window was off-screen — would be brought on-screen.");

  return entry(index, "tile_window", slots, true,
    `${win.app} → ${position} on ${display.name}`,
    makePlan({
      summary: `Tile ${win.app}${win.title ? ` ("${truncate(win.title, 40)}")` : ""} to ${humanPosition(position)} of ${display.name}.`,
      targets: [targetCard(win, before, after)],
      position,
      display: resolvedDisplay(display),
      warnings,
    }),
  );
}

function applyDistribute(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const appFilter = typeof slots.app === "string" ? slots.app.toLowerCase() : null;
  const region = typeof slots.region === "string" ? slots.region : null;

  const display = scn.displays[0];
  if (!display) {
    return entry(index, "distribute", slots, false,
      "No displays in scenario.",
      makePlan({ summary: "No display available.", warnings: ["Scenario has zero displays."] }),
    );
  }

  let regionRect: Rect = { x: 0, y: 0, w: display.width, h: display.height };
  let regionNote = `the full ${display.name}`;
  if (region && REGION_KEYS.has(region)) {
    regionRect = rectFromPosition(region, display)!;
    regionNote = `${humanPosition(region)} of ${display.name}`;
  } else if (region) {
    return entry(index, "distribute", slots, false,
      `Unknown region "${region}".`,
      makePlan({ summary: `Region "${region}" not in the grammar.`, display: resolvedDisplay(display), warnings: [`Unknown region "${region}".`] }),
    );
  }

  const candidates = scn.windows.filter((w) => {
    if (!w.onScreen) return false;
    if (w.displayIndex !== 0) return false;
    if (appFilter) return w.app.toLowerCase().includes(appFilter);
    return true;
  });

  if (candidates.length === 0) {
    const scope = appFilter ? ` matching "${appFilter}"` : "";
    return entry(index, "distribute", slots, false,
      `No on-screen windows${scope} on main display.`,
      makePlan({
        summary: `No matching windows${scope} on ${display.name}.`,
        display: resolvedDisplay(display),
        warnings: [`Zero matches${scope}.`],
      }),
    );
  }

  const befores = candidates.map(snapState);
  const cols = Math.ceil(Math.sqrt(candidates.length));
  const rows = Math.ceil(candidates.length / cols);
  const cellW = Math.floor(regionRect.w / cols);
  const cellH = Math.floor(regionRect.h / rows);

  candidates.forEach((w, i) => {
    const c = i % cols;
    const r = Math.floor(i / cols);
    w.frame = {
      x: regionRect.x + c * cellW,
      y: regionRect.y + r * cellH,
      w: cellW,
      h: cellH,
    };
  });

  const targets: ResolvedTarget[] = candidates.map((w, i) => targetCard(w, befores[i], snapState(w)));
  const scope = appFilter ? appFilter : "all on-screen";

  return entry(index, "distribute", slots, true,
    `Grid ${candidates.length} ${scope} (${cols}×${rows}) in ${regionNote}.`,
    makePlan({
      summary: `Arrange ${candidates.length} ${scope} window${candidates.length === 1 ? "" : "s"} in a ${cols}×${rows} grid across ${regionNote}.`,
      targets,
      position: region ?? "full",
      display: resolvedDisplay(display),
      warnings: [],
    }),
  );
}

function applyHide(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  if (typeof slots.app === "string") {
    const needle = slots.app.toLowerCase();
    const candidates = scn.windows.filter((w) => w.onScreen && w.app.toLowerCase().includes(needle));
    if (!candidates.length) {
      return entry(index, "hide", slots, false,
        `No on-screen ${slots.app} windows.`,
        makePlan({ summary: `No on-screen ${slots.app} to hide.`, warnings: [`Zero matches for "${slots.app}".`] }),
      );
    }
    const befores = candidates.map(snapState);
    for (const w of candidates) w.onScreen = false;
    const targets: ResolvedTarget[] = candidates.map((w, i) => targetCard(w, befores[i], snapState(w)));
    return entry(index, "hide", slots, true,
      `Hide ${candidates.length} ${slots.app} window${candidates.length === 1 ? "" : "s"}.`,
      makePlan({
        summary: `Hide ${candidates.length} ${slots.app} window${candidates.length === 1 ? "" : "s"}.`,
        targets,
      }),
    );
  }
  if (typeof slots.wid === "number") {
    const win = findWindowByWid(scn, slots.wid);
    if (!win) {
      return entry(index, "hide", slots, false,
        `wid:${slots.wid} not found.`,
        makePlan({ summary: `wid:${slots.wid} not in snapshot.`, warnings: [unresolvedTargetWarning(slots)] }),
      );
    }
    const before = snapState(win);
    win.onScreen = false;
    return entry(index, "hide", slots, true,
      `Minimize ${win.app} (wid:${win.wid}).`,
      makePlan({
        summary: `Minimize ${win.app}${win.title ? ` ("${truncate(win.title, 40)}")` : ""}.`,
        targets: [targetCard(win, before, snapState(win))],
      }),
    );
  }
  return entry(index, "hide", slots, false,
    "No target specified.",
    makePlan({ summary: "No app or wid given.", warnings: ["Slots are empty."] }),
  );
}

function applyFocus(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const win = resolveTarget(scn, slots);
  if (!win) {
    return entry(index, "focus", slots, false,
      "Couldn't resolve target.",
      makePlan({ summary: "Target not found.", warnings: [unresolvedTargetWarning(slots)] }),
    );
  }
  const before = snapState(win);
  for (const other of scn.windows) {
    if (other === win) continue;
    if (other.displayIndex === win.displayIndex && other.zIndex < win.zIndex) other.zIndex += 1;
  }
  win.zIndex = 0;
  win.onScreen = true;
  const display = scn.displays[win.displayIndex];
  return entry(index, "focus", slots, true,
    `Bring ${win.app} (wid:${win.wid}) to front.`,
    makePlan({
      summary: `Bring ${win.app}${win.title ? ` ("${truncate(win.title, 40)}")` : ""} to the front${display ? ` on ${display.name}` : ""}.`,
      targets: [targetCard(win, before, snapState(win))],
      display: display ? resolvedDisplay(display) : undefined,
    }),
  );
}

function applySwap(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const a = findWindowByWid(scn, slots.wid_a);
  const b = findWindowByWid(scn, slots.wid_b);
  if (!a || !b) {
    return entry(index, "swap", slots, false,
      "Need both wid_a and wid_b to resolve.",
      makePlan({ summary: "Swap requires two resolvable window ids.", warnings: ["Missing wid_a or wid_b."] }),
    );
  }
  const beforeA = snapState(a);
  const beforeB = snapState(b);
  const tmpFrame = a.frame;
  const tmpDisplay = a.displayIndex;
  a.frame = b.frame; a.displayIndex = b.displayIndex;
  b.frame = tmpFrame; b.displayIndex = tmpDisplay;
  return entry(index, "swap", slots, true,
    `Swap ${a.app} ↔ ${b.app}.`,
    makePlan({
      summary: `Swap positions of ${a.app} (wid:${a.wid}) and ${b.app} (wid:${b.wid}).`,
      targets: [
        targetCard(a, beforeA, snapState(a)),
        targetCard(b, beforeB, snapState(b)),
      ],
    }),
  );
}

function applyMoveToDisplay(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const win = resolveTarget(scn, slots);
  if (!win) {
    return entry(index, "move_to_display", slots, false,
      "Couldn't resolve target.",
      makePlan({ summary: "Target not found.", warnings: [unresolvedTargetWarning(slots)] }),
    );
  }
  const targetIdx = typeof slots.display === "number" ? slots.display : null;
  if (targetIdx == null) {
    return entry(index, "move_to_display", slots, false,
      "No display index specified.",
      makePlan({
        summary: `${win.app} target display missing.`,
        targets: [{ wid: win.wid, app: win.app, title: win.title, before: snapState(win), changed: false }],
        warnings: ["No display in slots."],
      }),
    );
  }
  const target = scn.displays[targetIdx];
  if (!target) {
    return entry(index, "move_to_display", slots, false,
      `Display ${targetIdx} not present.`,
      makePlan({
        summary: `Scenario has ${scn.displays.length} display${scn.displays.length === 1 ? "" : "s"}; can't go to ${targetIdx}.`,
        targets: [{ wid: win.wid, app: win.app, title: win.title, before: snapState(win), changed: false }],
        warnings: [`Out-of-range display index ${targetIdx}.`],
      }),
    );
  }

  const before = snapState(win);
  win.displayIndex = targetIdx;

  if (typeof slots.position === "string") {
    const rect = rectFromPosition(slots.position, target);
    if (rect) win.frame = rect;
  } else {
    win.frame = { x: 0, y: 0, w: Math.min(win.frame.w || target.width, target.width), h: Math.min(win.frame.h || target.height, target.height) };
  }

  const positionNote = typeof slots.position === "string" ? ` (${humanPosition(slots.position)})` : "";
  return entry(index, "move_to_display", slots, true,
    `${win.app} → ${target.name}${positionNote}.`,
    makePlan({
      summary: `Move ${win.app}${win.title ? ` ("${truncate(win.title, 40)}")` : ""} to ${target.name}${positionNote}.`,
      targets: [targetCard(win, before, snapState(win))],
      position: typeof slots.position === "string" ? slots.position : undefined,
      display: resolvedDisplay(target),
    }),
  );
}

function applySwitchLayer(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const layer = slots.layer;
  if (layer == null) {
    return entry(index, "switch_layer", slots, false,
      "No layer specified.",
      makePlan({ summary: "No layer in slots.", warnings: ["Missing 'layer'."] }),
    );
  }
  const prev = scn.currentLayer;
  scn.currentLayer = String(layer);
  return entry(index, "switch_layer", slots, true,
    `Switch to layer "${layer}".`,
    makePlan({
      summary: `Switch active layer from "${prev ?? "—"}" to "${layer}".`,
    }),
  );
}

function applyCreateLayer(scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  const name = slots.name;
  if (typeof name !== "string" || !name) {
    return entry(index, "create_layer", slots, false,
      "No layer name.",
      makePlan({ summary: "No layer name in slots.", warnings: ["Missing 'name'."] }),
    );
  }
  scn.currentLayer = name;
  const onScreenCount = scn.windows.filter((w) => w.onScreen).length;
  return entry(index, "create_layer", slots, true,
    `Capture current layout as "${name}".`,
    makePlan({
      summary: `Snapshot the current ${onScreenCount}-window layout and save it as "${name}".`,
    }),
  );
}

function applyInformational(intent: string, scn: Scenario, slots: Record<string, unknown>, index: number): ExecLogEntry {
  switch (intent) {
    case "list_windows": {
      const onScreen = scn.windows.filter((w) => w.onScreen).length;
      return entry(index, intent, slots, true,
        `Read out ${onScreen} on-screen window${onScreen === 1 ? "" : "s"}.`,
        makePlan({ summary: `Read out ${onScreen} on-screen window${onScreen === 1 ? "" : "s"} to the user.` }),
      );
    }
    case "list_sessions": {
      const n = scn.terminals.length;
      return entry(index, intent, slots, true,
        `List ${n} terminal session${n === 1 ? "" : "s"}.`,
        makePlan({ summary: `List ${n} terminal session${n === 1 ? "" : "s"} (including any with Claude attached).` }),
      );
    }
    case "search": {
      const q = typeof slots.query === "string" ? slots.query.toLowerCase() : "";
      if (!q) {
        return entry(index, intent, slots, false,
          "Empty search query.",
          makePlan({ summary: "No query in slots.", warnings: ["Missing 'query'."] }),
        );
      }
      const hits = scn.windows.filter((w) =>
        w.app.toLowerCase().includes(q) || w.title.toLowerCase().includes(q),
      );
      const termHits = scn.terminals.filter((t) =>
        (t.cwd ?? "").toLowerCase().includes(q) || (t.tabTitle ?? "").toLowerCase().includes(q),
      );
      const targets: ResolvedTarget[] = hits.map((w) => ({
        wid: w.wid, app: w.app, title: w.title, before: snapState(w), changed: false,
      }));
      return entry(index, intent, slots, true,
        `${hits.length} window match${hits.length === 1 ? "" : "es"} + ${termHits.length} terminal match${termHits.length === 1 ? "" : "es"} for "${q}".`,
        makePlan({
          summary: `Search for "${q}" — matches ${hits.length} window${hits.length === 1 ? "" : "s"} and ${termHits.length} terminal tab${termHits.length === 1 ? "" : "s"}.`,
          targets,
        }),
      );
    }
    case "highlight": {
      const win = resolveTarget(scn, slots);
      if (!win) {
        return entry(index, intent, slots, false,
          "Couldn't resolve target.",
          makePlan({ summary: "Highlight target not found.", warnings: [unresolvedTargetWarning(slots)] }),
        );
      }
      return entry(index, intent, slots, true,
        `Flash border on ${win.app} (wid:${win.wid}).`,
        makePlan({
          summary: `Flash a border around ${win.app}${win.title ? ` ("${truncate(win.title, 40)}")` : ""} so the user can spot it.`,
          targets: [{ wid: win.wid, app: win.app, title: win.title, before: snapState(win), changed: false }],
        }),
      );
    }
    case "find_mouse":
      return entry(index, intent, slots, true, "Pulse the cursor.",
        makePlan({ summary: "Show a sonar pulse at the current cursor position." }),
      );
    case "summon_mouse":
      return entry(index, intent, slots, true, "Warp the cursor.",
        makePlan({ summary: "Move the cursor to the center of the active screen." }),
      );
    case "scan":
      return entry(index, intent, slots, true, "Trigger OCR scan.",
        makePlan({ summary: "Run OCR across visible windows and update the index." }),
      );
    case "launch": {
      const project = typeof slots.project === "string" ? slots.project : "(unnamed)";
      return entry(index, intent, slots, true,
        `Launch project "${project}".`,
        makePlan({ summary: `Open the project session named "${project}" (mock executor does not spawn terminals).` }),
      );
    }
    case "kill": {
      const session = typeof slots.session === "string" ? slots.session : "(unnamed)";
      const before = scn.terminals.length;
      scn.terminals = scn.terminals.filter((t) => t.tmuxSession !== session);
      const removed = before - scn.terminals.length;
      return entry(index, intent, slots, true,
        `Kill session "${session}" — removed ${removed} tab${removed === 1 ? "" : "s"}.`,
        makePlan({ summary: `Kill the tmux session "${session}" and detach ${removed} terminal tab${removed === 1 ? "" : "s"}.` }),
      );
    }
    case "undo":
      return entry(index, intent, slots, false,
        "Mock executor has no per-turn history.",
        makePlan({ summary: "Undo would restore previous frames — mock executor doesn't track turn history. Use Reset to revert.", warnings: ["No history available."] }),
      );
    default:
      return entry(index, intent, slots, false,
        `Mock executor doesn't model "${intent}".`,
        makePlan({ summary: `Intent "${intent}" not modeled by the mock executor.`, warnings: [`Unknown intent "${intent}".`] }),
      );
  }
}

// ── Utility ──────────────────────────────────────────────────────────────

function unresolvedTargetWarning(slots: Record<string, unknown>): string {
  const parts: string[] = [];
  if (slots.wid != null) parts.push(`wid:${slots.wid}`);
  if (slots.app != null) parts.push(`app:"${slots.app}"`);
  if (slots.session != null) parts.push(`session:"${slots.session}"`);
  return parts.length ? `Could not resolve ${parts.join(" or ")}.` : "No target slots provided.";
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1) + "…";
}

export function humanPosition(p: string): string {
  if (p.startsWith("grid:")) return p;
  return p.replace(/-/g, " ");
}

// ── Public API ───────────────────────────────────────────────────────────

export function cloneScenario(s: Scenario): Scenario {
  return {
    ...s,
    displays: s.displays.map((d) => ({ ...d, spaces: d.spaces.map((sp) => ({ ...sp })) })),
    windows: s.windows.map((w) => ({ ...w, frame: { ...w.frame } })),
    terminals: s.terminals.map((t) => ({ ...t })),
    tmuxSessions: s.tmuxSessions ? [...s.tmuxSessions] : undefined,
  };
}

export function applyActions(scenario: Scenario, actions: Action[]): ExecResult {
  const next = cloneScenario(scenario);
  const log: ExecLogEntry[] = [];

  actions.forEach((action, i) => {
    const slots = (action.slots ?? {}) as Record<string, unknown>;
    let result: ExecLogEntry;
    switch (action.intent) {
      case "tile_window":
        result = applyTileWindow(next, slots, i);
        break;
      case "distribute":
        result = applyDistribute(next, slots, i);
        break;
      case "hide":
        result = applyHide(next, slots, i);
        break;
      case "focus":
        result = applyFocus(next, slots, i);
        break;
      case "swap":
        result = applySwap(next, slots, i);
        break;
      case "move_to_display":
        result = applyMoveToDisplay(next, slots, i);
        break;
      case "switch_layer":
        result = applySwitchLayer(next, slots, i);
        break;
      case "create_layer":
        result = applyCreateLayer(next, slots, i);
        break;
      default:
        result = applyInformational(action.intent, next, slots, i);
    }
    log.push(result);
  });

  return { scenario: next, log };
}

export function formatRect(r?: Rect): string {
  if (!r) return "—";
  if (r.w === 0 && r.h === 0) return "—";
  return `(${r.x},${r.y}, ${r.w}×${r.h})`;
}

// ── Live snapshot adapter ────────────────────────────────────────────────
// Synthesizes a Scenario-shaped object from the live windows.list /
// terminals.list / spaces.list rows so the planner can still resolve targets
// by wid and app, even when we lack frame data.

export interface LiveWindowRow { wid: number; app?: string; title?: string; isOnScreen?: boolean }
export interface LiveTerminalRow { app?: string; tabTitle?: string; cwd?: string; hasClaude?: boolean }
export interface LiveDisplayRow { displayIndex: number; displayId: string; currentSpaceId: number; spaces: { id: number; index: number; isCurrent: boolean }[]; name?: string }

export function liveRowsToScenario(
  windows: LiveWindowRow[] | undefined,
  terminals: LiveTerminalRow[] | undefined,
  displays: LiveDisplayRow[] | undefined,
): Scenario {
  const fallbackDisplay: ScenarioDisplay = {
    displayIndex: 0,
    displayId: "live-display-0",
    name: "Main display",
    width: 0,
    height: 0,
    isMain: true,
    currentSpaceId: 0,
    spaces: [{ id: 0, index: 1, isCurrent: true }],
  };
  const builtDisplays: ScenarioDisplay[] = (displays ?? []).map((d) => ({
    displayIndex: d.displayIndex,
    displayId: d.displayId,
    name: d.name ?? `Display ${d.displayIndex}`,
    width: 0,
    height: 0,
    isMain: d.displayIndex === 0,
    currentSpaceId: d.currentSpaceId,
    spaces: d.spaces,
  }));

  return {
    id: "live",
    name: "Live desktop",
    blurb: "Synthesized from windows.list / terminals.list / spaces.list",
    stageManager: false,
    displays: builtDisplays.length ? builtDisplays : [fallbackDisplay],
    windows: (windows ?? []).map((w, i) => ({
      wid: w.wid,
      app: w.app ?? "Unknown",
      title: w.title ?? "",
      frame: { x: 0, y: 0, w: 0, h: 0 },
      onScreen: w.isOnScreen !== false,
      zIndex: i,
      displayIndex: 0,
    })),
    terminals: (terminals ?? []).map((t) => ({
      app: t.app ?? "Terminal",
      tabTitle: t.tabTitle,
      cwd: t.cwd,
      hasClaude: t.hasClaude,
    })),
    tmuxSessions: [],
    currentLayer: undefined,
  };
}
