import { parseEntry, tokens, spacesFor } from "./FlightDeckModel.mjs";

export function inventory(state) {
  const entries = new Map();
  const parked = new Set((state.stage?.parked || []).map(w => w.wid));
  for (const window of state.windows || []) entries.set(window.wid, Object.assign({}, window, { presence: parked.has(window.wid) ? "parked" : window.isOnScreen ? "showing" : "elsewhere", layerNames: [] }));
  for (const layer of state.layers || []) for (const entry of layer.entries || []) for (const window of entry.windows || []) {
    if (!entries.has(window.wid)) entries.set(window.wid, Object.assign({}, window, { presence: window.presence || "elsewhere", layerNames: [] }));
    const item = entries.get(window.wid);
    if (parked.has(window.wid) || window.presence === "parked") item.presence = "parked";
    if (!item.layerNames.includes(layer.label)) item.layerNames.push(layer.label);
  }
  for (const window of state.stage?.parked || []) {
    if (!entries.has(window.wid)) entries.set(window.wid, Object.assign({}, window, { presence: "parked", spaceIds: [], layerNames: [] }));
  }
  return [...entries.values()].sort((a, b) => (a.presence === "parked") - (b.presence === "parked") ||
    (a.displayIndex ?? 0) - (b.displayIndex ?? 0) || ((a.spaceIds || []).find(id => id > 0) || Infinity) - ((b.spaceIds || []).find(id => id > 0) || Infinity) ||
    a.app.localeCompare(b.app) || a.title.localeCompare(b.title) || a.wid - b.wid);
}

export function inventoryMatches(window, query) {
  return [window.app, window.title, window.wid, window.latticesSession || "", ...(window.layerNames || [])].join(" ").toLowerCase().includes(query.trim().toLowerCase());
}

export function spaceInventory(displays, windows) {
  return displays.reduce((all, display) => all.concat(spacesFor(display).map(space => Object.assign({}, space, {
    displayIndex: display.displayIndex, displayId: display.displayId,
    isCurrent: space.id === display.currentSpaceId,
    visibleCount: windows.filter(w => w.presence !== "parked" && w.displayIndex === display.displayIndex && (w.spaceIds || []).includes(space.id)).length,
  }))), []);
}

export function consoleCommand(text, windows, layers) {
  try {
    const body = text.trim().replace(/\u200b/g, " ").replace(/^>\s*/, "");
    const words = tokens(body);
    if (words[0] === "lats") words.shift();
    const json = words.includes("--json");
    const args = words.filter(word => word !== "--json");
    const plan = value => json ? Object.assign({}, value, { json: true }) : value;
    const action = args[0];
    if (!action) return { kind: "error", message: "Enter a Lattices command. Try lats doctor or help." };
    const readMethod = action === "windows" ? "windows.list" : action === "spaces" ? "spaces.list" :
      action === "sessions" || action === "ls" ? "tmux.list" : action === "doctor" ? "app.doctor" : null;
    if (readMethod && args.length === 1) return plan({ kind: "rpc", method: readMethod, params: {}, read: true });
    if (action === "layer" && args.length === 1) return plan({ kind: "rpc", method: "layers.list", params: {}, read: true });
    if (action === "search" && args.length === 2) return plan({ kind: "rpc", method: "windows.search", params: { query: args[1], limit: 50 }, read: true });
    if (["help", "clear", "hints"].includes(action) && args.length === 1) {
      if (json && action !== "hints") throw new Error("Only data commands support --json.");
      return plan({ kind: "local", action });
    }
    if (action === "app" && args[1] === "status" && args.length === 2) return plan({ kind: "local", action: "status" });
    if (action === "app" && args.length === 2 && ["mission", "overview", "console", "hints"].includes(args[1]))
      return json ? { kind: "error", message: "Page navigation does not support --json." } : { kind: "page", page: ({ mission: "Mission", overview: "Overview", console: "Console", hints: "Hints" })[args[1]] };
    if (action === "session" && words[0] === "session" && !/^lats\s/.test(body) && args.length === 2) {
      if (!/^(\/|~(?:\/|$))/.test(args[1])) throw new Error("Use an absolute project path or ~/project for a new session.");
      return plan({ kind: "rpc", method: "sessions.launch", params: { path: args[1] } });
    }
    const mutation = parseEntry("> " + args.map(arg => JSON.stringify(arg)).join(" "), windows, layers);
    return mutation.kind === "search" ? { kind: "error", message: "Use a supported Lattices command. Type help for the list." } : plan(mutation);
  } catch (error) { return { kind: "error", message: error.message }; }
}

export function completions(prefix, windows, layers) {
  const commands = ["lats doctor", "lats windows", "lats spaces", "lats sessions", "lats layer", "lats hints", "lats app status", "lats space next", "lats space prev", "lats space previous", "lats app mission", "lats app overview", "help", "clear"];
  for (const window of windows) {
    commands.push("lats window focus " + window.wid, "lats window focus " + window.wid + " --dry-run", "lats window place " + window.wid + " right --dry-run");
  }
  for (const layer of layers) commands.push("lats layer " + JSON.stringify(layer.label) + " --tile");
  return [...new Set(commands)].filter(command => command.startsWith(prefix));
}

export const consoleHelp = `Inspect\n  lats doctor · windows · spaces · sessions · layer\n  lats search "window title"\n  lats hints · app status\n\nAct\n  lats window focus <decimal ID> [--dry-run]\n  lats window place <ID> left|right|center|maximize [--dry-run]\n  lats space next|prev|previous|<ID> [--dry-run]\n  lats layer "name" --tile · lats layer reveal\n  session /absolute/project/path  (create a detached tmux session)\n\nNavigate\n  lats app mission|overview|console|hints\n  Tab completes · ↑ ↓ history · Ctrl L clears the transcript`;

function clean(value) { return String(value ?? "").replace(/[\u0000-\u001f\u007f]/g, " "); }
function line(parts) { return parts.map(([value, width]) => clean(value).slice(0, width).padEnd(width)).join("  ").trimEnd(); }
export function formatResult(method, result, json) {
  let output;
  if (json) output = JSON.stringify(method === "app.doctor" ? result.report : result ?? null, null, 2);
  else if (method === "app.doctor") {
    const report = result.report;
    output = `Lattices doctor · ${report.hostname || "local"} · ${report.platform || "host unavailable"}\n` +
      report.checks.map(check => `${check.state === "pass" ? "✓" : check.state === "fail" ? "✗" : "?"} ${check.name}: ${check.detail}`).join("\n");
  } else if (["windows.list", "windows.search"].includes(method)) {
    output = result.length ? [line([["WINDOW", 10], ["APP", 22], ["SPACE", 8], ["TITLE", 100]]),
      ...result.map(w => line([[w.wid, 10], [w.app, 22], [w.spaceIds.join(","), 8], [w.title, 100]]))].join("\n") : "No matching windows.";
  } else if (method === "tmux.list") {
    output = result.length ? result.map(s => `${clean(s.name)} · ${s.windowCount} windows · ${(s.panes || []).length} panes\n  ${clean(s.path)}`).join("\n") : "No tmux sessions running.";
  } else if (method === "spaces.list") {
    output = result.map(d => `${clean(d.displayId || d.name)}\n` + d.spaces.map(s => `  ${s.isCurrent ? "●" : "○"} ${s.id} · ${s.windowCount ?? "?"} windows`).join("\n")).join("\n");
  } else if (method === "layers.list") {
    output = result.layers.length ? result.layers.map((l, i) => `${result.active === i ? "●" : "○"} ${clean(l.label)} · ${clean(l.layout || "in place")}`).join("\n") : "No saved layers.";
  } else if (method === "windows.resolve") {
    output = `Resolved window ${result.window.wid}: ${clean(result.window.title)}\nPreview only · no focus changed.`;
  } else if (method === "windows.place") {
    output = `Window ${result.target.wid} · ${clean(result.placement)}\nFrame ${result.frame.x}, ${result.frame.y} · ${result.frame.w} × ${result.frame.h}\n` +
      (result.status === "planned" ? "Preview only · no window moved." : result.verified === false ? "Placement requested; the host could not verify the final frame." : "Placement verified.");
  } else if (method === "spaces.focus") {
    output = result.status === "planned" ? `Planned space switch: ${result.target}\nPreview only · no space changed.` : `Space ${result.currentSpaceId} · display ${result.displayIndex}`;
  } else if (method === "windows.focus") {
    output = `Focused window ${result.window.wid} · ${clean(result.window.title)}`;
  } else if (method === "sessions.launch") {
    output = `${result.created ? "Created" : "Found"} tmux session ${clean(result.session?.name || result.session)}\nDetached session · open it in a terminal to attach.`;
  } else output = JSON.stringify(result ?? null, null, 2);
  return output.length > 16000 ? output.slice(0, 16000) + "\n… output truncated" : output;
}
