import { workspaceTarget } from "../../packages/desktop-client/workspace-target.mjs";

// Pure desktop projection and command parsing, shared by QML and its tests.
export function matches(window, query) {
  return (window.app + " " + window.title + " " + (window.latticesSession || "")).toLowerCase().includes(query.trim().toLowerCase());
}

export function mapWindows(windows, display, space, query = "") {
  if (!display) return [];
  return windows.filter(w => w.displayIndex === display.displayIndex &&
    (w.spaceIds.includes(space) || (space === display.currentSpaceId && w.isOnScreen)) &&
    w.frame.w > 0 && w.frame.h > 0 && matches(w, query))
    .sort((a, b) => a.frame.y - b.frame.y || a.frame.x - b.frame.x || a.wid - b.wid);
}

export function nearbyWindow(windows, wid, direction) {
  if (!["left", "right", "up", "down"].includes(direction)) return null;
  const current = windows.find(w => w.wid === wid);
  if (!current) return windows[0]?.wid ?? null;
  const horizontal = direction === "left" || direction === "right";
  const sign = direction === "left" || direction === "up" ? -1 : 1;
  const cx = current.frame.x + current.frame.w / 2;
  const cy = current.frame.y + current.frame.h / 2;
  const candidates = windows.filter(w => w.wid !== wid).map(w => {
    const dx = w.frame.x + w.frame.w / 2 - cx;
    const dy = w.frame.y + w.frame.h / 2 - cy;
    const ahead = (horizontal ? dx : dy) * sign;
    return { wid: w.wid, ahead, score: ahead + Math.abs(horizontal ? dy : dx) * 2 };
  }).filter(w => w.ahead > 1).sort((a, b) => a.score - b.score || a.wid - b.wid);
  return candidates[0]?.wid ?? wid;
}

export function spacesFor(display) {
  if (!display) return [];
  const spaces = (display.spaces || []).filter(s => Number.isInteger(s.id) && s.id > 0);
  if (display.currentSpaceId > 0 && !spaces.some(s => s.id === display.currentSpaceId))
    spaces.push({ id: display.currentSpaceId, name: String(display.currentSpaceId), windowCount: 0, isCurrent: true });
  return spaces.filter((s, i, all) => all.findIndex(other => other.id === s.id) === i).sort((a, b) => a.id - b.id);
}

export function nextSpace(spaces, id, delta) {
  if (!spaces.length) return null;
  const index = spaces.findIndex(s => s.id === id);
  return spaces[((index < 0 ? 0 : index) + delta + spaces.length) % spaces.length].id;
}

export function entryMode(text) {
  return /^\s*(>|lats(?:\s|$))/.test(text) ? "command" : "search";
}

export function tokens(text) {
  const result = [];
  let value = "", quote = "", started = false, escaped = false;
  for (const char of text) {
    if (escaped) { value += char; escaped = false; }
    else if (quote === '"' && char === "\\") escaped = true;
    else if (quote) {
      if (char === quote) quote = "";
      else value += char;
    } else if (char === "'" || char === '"') { quote = char; started = true; }
    else if (/\s/.test(char)) { if (started) { result.push(value); value = ""; started = false; } }
    else { value += char; started = true; }
  }
  if (quote || escaped) throw new Error("Close the quote before running this command.");
  if (started) result.push(value);
  return result;
}

function windowTarget(value, windows, exact) {
  if (/^[1-9]\d*$/.test(value)) {
    const wid = Number(value);
    if (wid > 4294967295) throw new Error("Window IDs must be positive decimal numbers.");
    if (!windows.some(w => w.wid === wid)) throw new Error("That window is no longer available.");
    return wid;
  }
  if (exact) throw new Error("Use the decimal window ID shown in the target panel.");
  const found = windows.filter(w => matches(w, value));
  if (found.length !== 1) throw new Error(found.length ? "Several windows match. Select one on the map." : "No window matches that name.");
  return found[0].wid;
}

// An explicit > or lats prefix is required. These are typed RPCs, never shell text.
export function parseEntry(text, windows, layers) {
  if (entryMode(text) !== "command") return { kind: "search", query: text.trim() };
  try {
    const parts = tokens(text.trim().replace(/^>\s*/, ""));
    const cli = parts[0] === "lats";
    if (cli) parts.shift();
    let action = parts.shift();
    let exact = false;
    if (action === "window") { action = parts.shift(); exact = true; }
    const dryRun = parts.includes("--dry-run");
    const args = parts.filter(p => p !== "--dry-run" && !(action === "layer" && p === "--tile"));
    if (args.some(p => p.startsWith("--"))) throw new Error("This command does not support that option.");
    if (action === "hints" && args.length === 0 && !dryRun) return { kind: "page", page: "Hints" };
    if (action === "space" && args.length === 1) {
      const workspace = workspaceTarget(args[0]);
      if (workspace === null) throw new Error("Use space next, prev, previous, or a positive decimal ID.");
      return { kind: "rpc", method: "spaces.focus", params: { workspace, dryRun } };
    }
    if (action === "focus" && args.length) {
      if (exact && args.length !== 1) throw new Error("Use lats window focus <decimal ID>.");
      const wid = windowTarget(args.join(" "), windows, exact);
      return { kind: "rpc", method: dryRun ? "windows.resolve" : "windows.focus", params: { wid } };
    }
    if (action === "place" && args.length >= 2) {
      const placement = args.pop();
      if (!["left", "right", "center", "maximize"].includes(placement)) throw new Error("Use left, right, center, or maximize.");
      if (exact && args.length !== 1) throw new Error("Use lats window place <decimal ID> <position>.");
      const wid = windowTarget(args.join(" "), windows, exact);
      return { kind: "rpc", method: "windows.place", params: { wid, placement, dryRun } };
    }
    if (action === "layer" && args.length && !dryRun) {
      const name = args.join(" ").toLowerCase();
      if (name === "reveal" || name === "show-all") return { kind: "rpc", method: "layers.reveal", params: {} };
      const found = layers.filter(l => l.id.toLowerCase() === name || l.label.toLowerCase() === name);
      if (found.length !== 1) throw new Error("Use the exact name of a saved layer.");
      return { kind: "rpc", method: "layers.activate", params: { layer: found[0].id, mode: "tile" } };
    }
    throw new Error("Use > focus <name>, > space <ID>, > place <ID> <position>, > layer <name>, or > hints.");
  } catch (error) { return { kind: "error", message: error.message }; }
}
