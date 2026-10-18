import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface Hint {
  title: string;
  shortcut?: string;
  command?: string;
  detail: string;
}

export interface HintGroup {
  id: string;
  title: string;
  scope: string;
  hints: Hint[];
}

export interface HintPack {
  id: string;
  title: string;
  note: string;
  groups: HintGroup[];
}

/** Shared by the offline CLI and the Linux app. Personal bindings are opt-in. */
export function linuxHintPack(bindings = ""): HintPack {
  const groups: HintGroup[] = [
    {
      id: "navigation", title: "Start here", scope: "Omarchy desktop · default shortcuts",
      hints: [
        { title: "Focus a nearby window", shortcut: "Super + arrows", detail: "Choose the window to the left, right, above or below." },
        { title: "Rearrange windows", shortcut: "Super + Shift + arrows", detail: "Swap the focused window with its neighbour." },
        { title: "Switch spaces", shortcut: "Super + Tab / Shift + Tab", detail: "Hold Super; add Shift to go backwards through existing spaces." },
        { title: "Jump to a space", shortcut: "Super + 1–9", detail: "Use numbered spaces for projects you return to often. Super + 0 opens space 10." },
        { title: "Send a window to a space", shortcut: "Super + Shift + 1–9", detail: "Move the focused window and follow it. Add Alt to stay here." },
        { title: "Return to the previous space", shortcut: "Super + Ctrl + Tab", detail: "Bounce between the two spaces you used most recently." },
        { title: "Give a window the screen", shortcut: "Super + F", detail: "Toggle fullscreen; press it again to return." },
        { title: "Show all desktop shortcuts", shortcut: "Super + K", detail: "Open Omarchy’s searchable keyboard cheat sheet." },
      ],
    },
    {
      id: "app", title: "Inside Lattices", scope: "App shortcuts · Lattices must be focused",
      hints: [
        { title: "Open Lattices", command: "lats app", detail: "Open the Linux window or bring the existing one forward." },
        { title: "Find a window or run a command", shortcut: "Ctrl + K", detail: "Search in Flight Deck, filter Mission Control, or focus the Operator Console command field." },
        { title: "Jump between pages", shortcut: "Ctrl + 1 / 2 / 3 / 4", detail: "Home, Flight Deck, Layers and Activity, in that order." },
        { title: "Open Mission Control or Operator Console", shortcut: "Ctrl + 6 / 7", detail: "Inspect windows across spaces, or run Lattices commands and read their results." },
        { title: "Open this hints pack", shortcut: "F1", detail: "Open Hints from any page. Ctrl + 5 also opens Hints." },
        { title: "Read hints in a terminal", command: "lats hints", detail: "The same pack works without the app or host. Add --open to show it in the app." },
        { title: "Check or restart the app", command: "lats app status", detail: "Read the current page and host connection. lats app quit or restart affects only the window; the host and tray keep running." },
      ],
    },
    {
      id: "flight-deck", title: "Flight Deck", scope: "Overview page · Lattices must be focused",
      hints: [
        { title: "Zoom through the workspace canvas", shortcut: "Scroll / Pinch", detail: "Zoom around the pointer. Use + or − on the keyboard; camera changes do not switch desktop spaces." },
        { title: "Pan across spaces", shortcut: "Drag / Space + Drag", detail: "Drag empty canvas, hold Space to drag over windows, or use the middle mouse button. Horizontal scrolling also pans." },
        { title: "Fit all spaces or inspect one", shortcut: "0 / 1", detail: "0 fits all existing spaces on the selected display. 1 zooms into the inspected space. Click a window to select it; Enter focuses it." },
        { title: "Select a nearby window on the map", shortcut: "Arrows", detail: "Move the selection by spatial position. Selecting a window does not change desktop focus." },
        { title: "Focus the selected window", shortcut: "Enter", detail: "Focus the exact window shown in the target panel. Double-clicking a tile does the same." },
        { title: "Inspect spaces", shortcut: "[ / ]", detail: "Inspect the previous or next existing workspace. Go to space changes the real desktop; Enter focuses a selected window there." },
        { title: "Return to the current space", shortcut: "Esc", detail: "Clear search and placement previews, then return the map to the current workspace." },
        { title: "Preview before placing", command: "> place <wid> right --dry-run", detail: "In the command field, preview a frame without moving its window. The target panel also has a Preview placement toggle." },
      ],
    },
    {
      id: "mission-control", title: "Mission Control", scope: "Mission page · Lattices must be focused",
      hints: [
        { title: "Open the desktop inventory", command: "lats app mission", detail: "See windows across spaces, parked windows, layers, sessions and host health." },
        { title: "Select an inventory window", shortcut: "↑ / ↓", detail: "Move the selection without changing desktop focus. Enter focuses the selected live window." },
        { title: "Filter the inventory", shortcut: "Ctrl + K", detail: "Filter by title, app, decimal window ID or layer. Space buttons filter the list; Go to space changes the desktop." },
        { title: "Clear inventory filters", shortcut: "Esc", detail: "Show windows across all spaces again." },
      ],
    },
    {
      id: "operator-console", title: "Operator Console", scope: "Console page · Lattices must be focused",
      hints: [
        { title: "Open the command console", command: "lats app console", detail: "Run supported Lattices commands. Each result stays in this app session’s transcript." },
        { title: "Complete a command", shortcut: "Tab", detail: "Complete known commands, exact window IDs and saved layer names. Press again to cycle matches." },
        { title: "Recall a command", shortcut: "↑ / ↓", detail: "Step through command history. Return past the newest entry to recover your draft." },
        { title: "Clear the transcript", shortcut: "Ctrl + L", detail: "Remove completed entries. Running commands and command history stay available." },
        { title: "Preview an action", command: "lats window place <wid> right --dry-run", detail: "Preview without moving or focusing the window. Add --json for a structured receipt." },
      ],
    },
    {
      id: "cli-navigation", title: "Drive the desktop", scope: "Linux host · terminal commands",
      hints: [
        { title: "List spaces", command: "lats spaces", detail: "See each display’s spaces. The filled dot marks the current one; --json returns structured data." },
        { title: "Switch to the next space", command: "lats space next", detail: "Use prev to go backwards or previous to return to the last space. Add --dry-run to preview." },
        { title: "Jump directly to a space", command: "lats space <id>", detail: "Open a positive numbered space, creating it if needed. Add --json for a receipt." },
        { title: "Focus a specific window", command: "lats window focus <wid>", detail: "Use an ID from lats windows. --dry-run resolves the target without moving focus." },
        { title: "Preview a placement", command: "lats place <query> left --dry-run", detail: "Search and preview the chosen window’s placement. Remove --dry-run to focus and place it; --json returns a receipt." },
        { title: "Check the host", command: "lats doctor", detail: "Read connection, window, space, session and event health. --json is useful in scripts; failed checks return a nonzero exit code." },
      ],
    },
    {
      id: "layers", title: "Work with layers", scope: "Lattices · named groups of windows",
      hints: [
        { title: "Save the windows on screen", command: "lats layer snap <name>", detail: "Create a named layer from the windows currently visible." },
        { title: "Switch to a layer", command: "lats layer <name> --tile", detail: "Focus and arrange that layer’s windows on the current desktop. Linux layers operate within that desktop." },
        { title: "See your saved layers", command: "lats layer", detail: "List layers. In the app, Ctrl + 3 opens their windows and layout controls." },
        { title: "Bring parked windows back", command: "lats layer reveal", detail: "Restore parked windows whose original spaces are currently active. The app calls this Show all or Restore here." },
      ],
    },
    {
      id: "terminal", title: "From a terminal", scope: "Lattices CLI · use a project directory for sessions",
      hints: [
        { title: "Start or resume a project", command: "lats start", detail: "Create or reattach this directory’s tmux session. Bare lats shows status." },
        { title: "List running sessions", command: "lats ls", detail: "See projects whose terminal sessions are still running." },
        { title: "See the desktop", command: "lats map", detail: "Show an ASCII map of displays and windows. lats windows lists their IDs." },
        { title: "Search your windows", command: "lats search <query>", detail: "Find a window by app, title or session." },
        { title: "Place the focused window", command: "lats tile <position>", detail: "Try left, right, top, bottom or maximize. Placement floats the window." },
      ],
    },
    {
      id: "window-tools", title: "Keep windows handy", scope: "Omarchy desktop · default shortcuts",
      hints: [
        { title: "Put a window aside", shortcut: "Super + Alt + S", detail: "Move it to the scratchpad. Super + S shows or hides that scratchpad." },
        { title: "Float or tile a window", shortcut: "Super + T", detail: "Switch between free placement and the tiled layout." },
        { title: "Make a window follow you", shortcut: "Super + O", detail: "Toggle a floating, pinned window across spaces. Use it again to return it to the tiled layout." },
        { title: "Open the desktop menu", shortcut: "Super + Space", detail: "Find apps, settings and desktop tools in the Omarchy menu." },
        { title: "Close the focused window", shortcut: "Super + W", detail: "Close the window you are currently using." },
      ],
    },
  ];

  // Recognize only bindings with the expected action, never infer them from comments.
  const active = bindings.replace(/--\[\[[\s\S]*?\]\]/g, "").replace(/--[^\n]*/g, "");
  const personal: Hint[] = [];
  if (/o\.bind\(\s*"CTRL \+ LEFT"\s*,[^\n]*hl\.dsp\.focus\(\s*\{\s*workspace\s*=\s*"e-1"/.test(active)
    && /o\.bind\(\s*"CTRL \+ RIGHT"\s*,[^\n]*hl\.dsp\.focus\(\s*\{\s*workspace\s*=\s*"e\+1"/.test(active)) {
    personal.push({ title: "Switch spaces with your custom keys", shortcut: "Ctrl + Left / Right", detail: "Your personal bindings cycle through existing spaces, backwards or forwards." });
  }
  if (/o\.bind\(\s*"SUPER \+ CTRL \+ ALT \+ Home"\s*,[^\n]*mouse-home/.test(active)) {
    personal.push({ title: "End a visiting cursor", shortcut: "Super + Ctrl + Alt + Home", detail: "End visits to this machine and bring its own cursor back to the screen." });
  }
  if (personal.length) groups.unshift({ id: "personal", title: "Your shortcuts", scope: "Detected in your Hyprland bindings", hints: personal });

  return {
    id: "linux-omarchy", title: "Lattices on Linux",
    note: "Super is the Windows/logo key. Desktop shortcuts work anywhere; app shortcuts need Lattices focused. Personal bindings can override Omarchy defaults.",
    groups,
  };
}

export function loadLinuxHintPack(): HintPack {
  let bindings = "";
  try { bindings = readFileSync(join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "hypr/bindings.lua"), "utf8"); }
  catch { /* The default pack is also available away from a configured desktop. */ }
  return linuxHintPack(bindings);
}
