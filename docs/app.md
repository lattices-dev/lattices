---
title: Menu Bar App
description: Command palette, window tiling, and session management
order: 3
---

The lattices menu bar app sits in your menu bar and controls your
workspace from there.

## Installation

```bash
lats app              # Build (or download) and launch
lats app install      # Register launch-at-login and launch now
lats app update       # Swap in the latest app release only
lats app build        # Rebuild from source
lats app restart      # Quit, rebuild, relaunch
lats app quit         # Stop the app
```

The first run builds from source if Swift is available, otherwise
downloads a pre-built binary from GitHub releases.

Use `lats app install` when you want the companion to start now and
open automatically at login. It installs a user LaunchAgent in
`~/Library/LaunchAgents`; inspect it with `lats app login status`
and remove it with `lats app login disable`.

## Updating

```bash
lats update           # Update the CLI and app together
```

`lats update` reinstalls `@lattices/lattices` with the package manager
that owns your global install (npm, bun, or pnpm). It re-registers
launch-at-login so the LaunchAgent points at the new install, and it
relaunches the app if it was running. Pass `--force` to reinstall when
you already have the latest version.

## Command palette

Press **Control+Option+Space** from anywhere to open the command palette.
It's a searchable list of every action the app can perform, with
fuzzy matching on titles and subtitles.

### Project commands

| Command                       | Description                              |
|-------------------------------|------------------------------------------|
| Launch *project*              | Create a new session and open terminal   |
| Attach *project*              | Focus or open the running session        |
| Sync *project*                | Reconcile session to declared config     |
| Restart *pane* in *project*   | Kill and re-run a specific pane's command |

### Window commands

Available for running sessions:

| Command                       | Description                              |
|-------------------------------|------------------------------------------|
| Go to *project*               | Focus the terminal window (switches Spaces if needed) |
| Tile *project* Left           | Snap window to left half                 |
| Tile *project* Right          | Snap window to right half                |
| Maximize *project*            | Expand window to fill screen             |
| Detach *project*              | Disconnect clients, keep session alive   |
| Kill *project*                | Terminate the tmux session               |

### Tab group commands

Available when `groups` are configured in `~/.lattices/workspace.json`
(see [Tab Groups](/docs/layers#tab-groups)):

| Command                     | Description                              |
|-----------------------------|------------------------------------------|
| Launch *group*              | Start the group session (all tabs)       |
| Attach *group*              | Focus the running group session          |
| *Group*: *Tab*              | Switch to a specific tab within a group  |
| Kill *group* Group          | Terminate the group session              |

### Layer commands

Available when `layers` are configured in `~/.lattices/workspace.json`
(see [Layers](/docs/layers#layers)):

| Command                     | Description                              |
|-----------------------------|------------------------------------------|
| Switch to Layer: *label*    | Focus and tile the layer's project windows |
| Show All Windows            | Put back what layer switches parked or hid |

### App commands

| Command           | Description                              |
|-------------------|------------------------------------------|
| Settings          | Open preferences (terminal, scan root)   |
| Update Lattices   | Download the latest release and relaunch |
| Diagnostics       | View logs and debug info                 |
| Refresh Projects  | Re-scan .lattices.json configs, reload workspace.json |
| Quit Lattices      | Exit the menu bar app                    |

## Overlay actors and HUDs

Persistent overlay actors can be hidden or restored with **Hyper+B**. Apps can
publish a static hover dashboard by exposing:

```txt
.lattices/hud/manifest.json
```

Register and publish one:

```bash
lats hud register .lattices/hud/manifest.json --publish
```

The manifest points to a local `index.html`, optional icon, app activation
target, HUD dimensions, and optional app-owned `sources` metadata for logs or
state files. Lattices hosts the actor and loads the dashboard through a
transparent `WKWebView`; the app owns the renderer and writes its own logs in
the places it already uses.

## Project discovery

The app scans a configurable root directory (up to 3 levels deep)
for `.lattices.json` files. It skips `.git/` and `node_modules/`.

Auto-detection for the scan root checks these paths in order:
`~/dev`, `~/Developer`, `~/projects`, `~/src`.

For each project found, the app reads:
- Pane names and commands from `.lattices.json`
- Dev command and package manager from `package.json`
- Running status by checking `tmux has-session`

## Session management

The app calls the lattices CLI for session operations. Launch runs
`lats start` in the project directory, Sync runs `lats sync` to
reconcile panes, and Restart runs `lats restart <pane>` to kill
and re-run a pane's process. Detach and Kill call `tmux detach-client`
and `tmux kill-session` directly.

## Window tiling

The app can tile terminal windows to preset screen positions via
the command palette. It finds windows by their `[lattices:session-name]`
title tag.

For Terminal.app and iTerm2, tiling uses AppleScript to set window
bounds by matching the title tag. For other terminals, it tiles the
frontmost window.

### Tile positions (app)

| Position     | Area                            |
|--------------|---------------------------------|
| Left         | Left half                       |
| Right        | Right half                      |
| Top Left     | Top-left quarter                |
| Top Right    | Top-right quarter               |
| Bottom Left  | Bottom-left quarter             |
| Bottom Right | Bottom-right quarter            |
| Maximize     | Full visible screen             |
| Left Third   | Left third                      |
| Center Third | Center third                    |
| Right Third  | Right third                     |
| Center       | 80% width, 80% height, centered (20% margin all sides) |

## Moving windows between displays and desktops

In **Overview**, select a window and open **Move** in the floating controls.
Each destination includes the display name and desktop number, such as
**DELL S3422DWG · Desktop 2** or **Action Agent Layer · Desktop 2**.
**Bring Here** selects the current desktop on the display that contains the
Overview window.

Drag a window shape onto another display map to move it to that display's
current desktop. Drop it onto a desktop thumbnail to choose that exact
desktop. The destination highlight identifies the drop target. Selecting a
window shows its controls over the canvas; the display maps and arrangement
tray keep their positions.

Desktop Inventory and Studio also offer window movement in their context
menus:

- **Bring Here** moves the selection to the UI's display and current desktop.
- **Move to Desktop** lists each display and its desktops.
- **Move to Next Monitor** cycles through displays and preserves normalized
  window position and size.
- **Move to Monitor** selects a display's current desktop.
- **Move & Place** selects a display and a placement slot for one window.

A right-click on a member of a multi-selection targets the whole selection.
Each window keeps its own normalized frame. Move & Place is available for a
single window. Desktop destinations remain available with one display.

The UI, CLI, and daemon use the same verified movement operation. If a window
is on an inactive desktop, Lattices first carries it onto its source display's
current desktop. It then transfers the window to the chosen display and
desktop. Mission Control can appear during the move. Keep the pointer free
until the operation finishes.

A move succeeds only after Lattices verifies the final display, desktop, and
frame. If a step fails, Lattices attempts to restore the original location
and reports the failure. The interface keeps the selection and refreshes the
observed window state.

## Space navigation

"Go to" commands can switch macOS Spaces to reach a window on a
different desktop. The app uses a three-path fallback:

1. **CGWindowList** (needs Screen Recording) — looks up the window
   by title tag, finds its Space via SkyLight, switches to it, then
   raises the window
2. **Accessibility API** (needs Accessibility) — finds the window
   via AXUIElement, raises it, and activates the app
3. **AppleScript** — iterates windows by name for Terminal/iTerm2,
   or bare-activates for other terminals

When a window is found and focused, the app flashes a green border
highlight around it for ~1 second so you can spot it immediately.

Grant Screen Recording and Accessibility permissions in System
Settings > Privacy & Security for all three paths to work.

### Instant space switching

With Accessibility permission, the app intercepts Ctrl+← / Ctrl+→ before
Mission Control and switches Spaces through a synthetic Dock swipe under
a screen-update freeze — the real switch path, so Dock's space model,
Mission Control, and space-change observers all stay consistent, while
the freeze makes it render as an instant cut. A desktop filmstrip appears
mid-screen over a subtle neutral dimmed backdrop. The focus frame stays
centered while window-layout previews slide through it; the small rail below
represents every desktop. The preview reads the existing desktop inventory
without taking screenshots or scanning windows on each keypress.
Pressing past the first or last desktop is silent. Reduce Motion updates the
selection without sliding; Reduce Transparency makes the tray and canvas backdrop opaque.

While the filmstrip is visible, Control+Up, Control+Down, or Control+minus opens the full
connected desktop canvas in one motion. You can also open it directly under
the pointer: hold the right mouse button and pull upward, or hold
Control+Option and scroll down. An ordinary right-click still opens its
context menu. The opening scroll's remaining movement and momentum are
consumed so they cannot immediately change the new canvas camera.

The canvas stays open when you release the button or modifiers. Moving the
pointer highlights a desktop without moving the canvas; Left/Right or a
single click also chooses it. Up (with or without Control) and plus zoom
toward the highlighted desktop. Down and minus zoom back out. Enter or a
double-click lands there; Escape cancels without switching. Zooming never lands. Control+Option+scroll
zooms around the pointer, ordinary scrolling pans, and the bottom-left minimap
repositions the view. Pinch, Command+scroll, and the zoom buttons also work.
Fit shows all desktops. Text fields keep their arrow keys. The Control+Option
tiling HUD and Spatial Lens stay inactive while this navigator owns the gesture.

Every page in the main window has a **Zoom out** control in its header. It
opens the same connected desktop canvas over the current page. **Back to…**
returns to that page with its draft, filters, and local view state intact.
Choosing a sidebar page leaves the canvas and navigates normally.

Agents can move the tray via
`settings.spaceBezel.set` (`top`, `bottom`, `center`, or `travelEdge`
to dock at the edge of travel). Only bare Ctrl+arrows are claimed;
Ctrl+Option+arrows still tile. While the feature is on, the app
disables Mission Control's "Move left/right a space" symbolic hotkeys
(they would replay the slide animation); the original setting is
restored when the feature is toggled off or the app quits. Toggle it in
Settings > Keyboard > "Instant Space Switching".

## Voice commands

> See [Voice Commands](/docs/voice) for the full guide.

Press **Hyper+D** to open the voice command window. Hold **Option** to
speak, release to stop. Lattices transcribes via Vox, matches to an
intent, and executes. Built-in commands: find, show, open, tile, kill, scan.

The provider-backed assistant can run in parallel, offering follow-up
suggestions in the AI corner. Configure the provider and credentials in
Settings > Voice. Workspace chat itself uses Scout and needs no separate key.

## Settings

Open via the command palette or the gear icon in the main view.
The settings window has five tabs:

### General

| Setting    | Description                                          |
|------------|------------------------------------------------------|
| Terminal   | Which terminal to use (auto-detected from installed) |
| Mode       | `learning` or `auto` (see below)                     |
| Scan Root  | Directory to scan for .lattices.json configs (type a path or click Browse) |
| Updates    | Download the latest release and relaunch the app     |
| Keyboard Remaps | Optional Caps Lock layer that maps hold to Hyper and tap to Escape |

**Mode** controls how the app handles session interaction:

- **Learning** — shows tmux keybinding hints when you detach
  (helpful while getting used to tmux)
- **Auto** — detaches sessions automatically (fewer prompts)

### Keyboard Remaps

**Keyboard remaps** are enabled by default for the laptop-friendly rule:

- hold Caps Lock -> Hyper (`Control` + `Option` + `Shift` + `Command`)
- tap Caps Lock -> Escape

With **Spatial Lens** enabled, holding physical Control + Option reveals
eight contextual placement targets around the pointer. Choose a side to preview
left, right, top, or bottom placement, or choose a corner for quarter placement.
A deliberate outer flick well beyond a side target previews the physically adjacent display in that direction;
release either modifier to commit the one visible proposal. Pull back before
release to return to the original display; release in the neutral center or
press another key to cancel.

Repeated placement follows the window's live geometry: half, third,
two-thirds, then half again. The exact Control + Option hold deliberately
excludes Command and Shift, so Caps Lock continues to own the Hyper layer.

Rules live in `~/.lattices/keyboard-remaps.json`, and the Settings toggle
can turn the layer off. Keyboard remaps require Accessibility permission
because they use a local event tap.

### Companion

Shows the secure local bridge status, Mac bridge fingerprint, supported
capability grants, and paired iPad or iPhone devices. The paired-device
list shows each device fingerprint, last-seen time, and granted
capabilities. You can refresh the list, revoke an individual device, or
forget all trusted companions.

The local companion bridge and trackpad proxy are off by default for
privacy. Turn the bridge on in Settings > Companion, or open
`lattices://companion/enable` to enable the bridge and jump straight to
Companion settings. `lattices://companion/disable` turns it off again.

The trackpad proxy toggle lives here. Paired devices still need the
`input.trackpad` grant before they can send pointer events.

### AI

| Setting              | Default        | Description                              |
|----------------------|----------------|------------------------------------------|
| Workspace chat       | Scout          | Uses the existing local Scout broker and keeps a persistent Scout ref; no separate Lattices chat credential |
| Voice provider       | OpenAI         | Optional voice-only HudsonAI provider for interpretation and speech services |
| Provider credentials | Not set        | API-key storage in the macOS Keychain for the selected provider |

Shows assistant readiness and the selected provider's authentication state.

### Shortcuts

Shows keyboard shortcut reference. These are defaults; you can change them
from Settings > Shortcuts.

| Shortcut          | Action              |
|-------------------|----------------------|
| Control+Option+Space       | Open command palette |
| Hyper+1            | Workspace home       |
| Hyper+L            | Studio / screen map  |
| Hyper+2            | Window bezel         |
| Hyper+3            | HUD                  |
| Ctrl+Cmd+M         | Hands-off mode       |
| Hyper+Space        | Hyperspace window survey |
| Hyper+G            | In-place window tools |
| Hold Ctrl+Option + pointer | Preview Spatial Lens placement; release to commit |
| Hyper+H            | Window navigation hints |
| Hyper+5            | Omni search          |
| Hyper+6            | Cheat sheet          |
| Ctrl+Option+Space  | Command bar          |
| Ctrl+Option+G      | 4x4 grid placement   |
| Ctrl+Option+V      | Fill open 3x2 cell   |
| Ctrl+Option+arrows | Tile halves          |
| Ctrl+Option+mouse  | Aim HUD; release to tile, stay centered to cancel |
| Ctrl+Option+1/2/3  | Tile thirds          |
| Ctrl+Left/Right    | Instant Space switch |
| Cmd+Option+1–9    | Switch to the layer in that slot; 5 shows the current one |
| Cmd+Option+arrows | Move across the layer pad |
| Ctrl+B  D         | Detach from session  |
| Ctrl+B  X         | Kill current pane    |
| Ctrl+B  Left/Right| Move between panes   |
| Ctrl+B  Z         | Zoom pane (toggle)   |
| Ctrl+B  [         | Scroll mode          |

Hyper+L opens Studio; close it with Escape or `q` when the map owns keyboard
focus, or use the window close button. Hyper+3 opens or dismisses the HUD and
its miniature workspace map. The Scattered and Full HUD presets intentionally
retain a faint, non-interactive ambient surface after dismissal. Neither UI is
the read-only terminal [`lats map`](/docs/workspace-map) command; see that
page for exact side effects, full-teardown steps, and tab-stack cleanup.

Studio's **Layers** panel lists the Cmd+Option layers in pad order. Picking
one scopes the canvas to the layer's windows that are showing, and the
inspector lists each of its entries with the windows it matched and where each
one is: on another desktop or display, parked, hidden, or nothing, when no
window matches. Picking a layer only looks; the inspector's Cmd+Option key
switches to it.

### In-place window tools

Press Hyper+G to arrange the real windows on the current desktop without
switching to a thumbnail survey. Hover a real app window to reveal its dashed
**click to select** outline, then click it to add or remove it from the
selection. Selected windows have solid green numbered outlines; the last one
selected is the active target for single-window actions. You can also select
from the **Windows** drawer in the header or use letter hints. The bottom shelf
shows the three-step flow—Select, Arrange, Finish—and groups actions by timing:

- **Fill** expands the active selected window into open space immediately.
- **Grid** moves two or more selected windows into a balanced grid immediately.
- **Swap** exchanges the first two selected windows.
- **Place** stages an exact grid position for the active selected window; it
  applies only when you Keep changes.
- **More** exposes tab groups, layers, quick placements, and Hyperspace.

Grid, Fill, and Swap update the live desktop while Hyper+G remains open. Press
**Keep changes** or Return to accept those live moves and apply staged changes.
Press **Restore** or Escape to discard staged changes and restore the window
frames and stacking order from when Hyper+G opened. Inline **Now** and **Keep**
labels distinguish immediate actions from staged actions before anything moves.

**Snapshot** starts a three-second countdown, captures the complete display
without closing or changing Hyper+G, copies the PNG to the clipboard, and saves
the same image as a Runs artifact. The command-line equivalent is
`lats capture display [index] --clipboard --delay 3`.

### Agent screenshots

When a screenshot is requested through the daemon socket (`lattices capture
window|display`, or any `capture.screenshot*` call), Lattices draws a coral
hairline around what was captured for about a second. A tag names the agent,
where it called from (this Mac, or `ssh <ip>`) and its project. The cue appears
after the shot and is excluded from screen capture, so it never shows up in an
image. Screenshots Lattices takes for itself don't trigger it.

Each one is also appended to `~/.lattices/audit/captures.jsonl` with the caller,
target and artifact path. Read it with `lattices capture log [--limit N] [--json]`.
The CLI detects Claude Code, Codex, opencode and Cursor from their environment.
Set `LATTICES_AGENT` to name any other agent.

### Docs

Embedded quick reference with glossary, "how it works" steps, and
links to open the full `config.md` and `concepts.md` docs.

## Supported terminals

| Terminal     | Launch | Focus/Attach | Tile by tag |
|--------------|--------|--------------|-------------|
| Terminal.app | yes    | yes          | yes         |
| iTerm2       | yes    | yes          | yes         |
| Warp         | yes    | activate     | frontmost   |
| Ghostty      | yes    | activate     | frontmost   |
| Kitty        | yes    | activate     | frontmost   |
| Alacritty    | yes    | activate     | frontmost   |

"yes" means full AppleScript-based window matching by title tag.
"activate" means the app is brought to front but a specific window
can't be targeted. "frontmost" means tiling applies to whatever
window is in front.

## Screen OCR

> See [Screen OCR](/docs/ocr) for full details on configuration, scanning,
> search, and agent usage.

The app reads text from visible windows using Apple's Vision framework
and stores results in a local SQLite database with FTS5 full-text search.
Agents can use this to "see" what's on screen.

### How it works

1. Every 60 seconds, the app captures the top visible windows as images
2. A SHA256 hash detects whether the window content has changed
3. Changed windows are processed through `VNRecognizeTextRequest` (fast mode)
4. Results are stored in `~/.lattices/ocr.db` with full-text indexing
5. Entries older than 3 days are automatically purged

### Desktop Inventory integration

Desktop Inventory and omni search use OCR to find windows by their content —
not just by title or app name. Matching windows can include contextual text
snippets. Hyper+G's optional drawer is a compact roster for the current display;
use Desktop Inventory or omni search when the on-screen text is the target.

### API access

Agents can query OCR data through four API methods:

| Method         | Description                                    |
|----------------|------------------------------------------------|
| `ocr.snapshot` | Current OCR results for all visible windows    |
| `ocr.search`   | Full-text search across history (FTS5 syntax)  |
| `ocr.history`  | Timeline of OCR results for a specific window  |
| `ocr.scan`     | Trigger an immediate scan (bypasses timer)     |

```js
import { daemonCall } from '@lattices/lattices'

// Find windows showing error messages
const errors = await daemonCall('ocr.search', { query: 'error OR failed' })

// Read what's currently on screen
const snapshot = await daemonCall('ocr.snapshot')
```

More in the [Agent API reference](/docs/api#ocrsnapshot).

### Requirements

- **Screen Recording** permission — required to capture window and display images
- Granted via System Settings > Privacy & Security > Screen Recording

## Local loopback services

The menu bar process owns fixed loopback ports (see `LatticesLocalEndpoints`):

| Service | Port | Endpoint |
|---------|------|----------|
| Agent API / daemon | **9399** | `ws://127.0.0.1:9399` |
| Voice runtime (Hudson Voice / Vox) | **9398** | `ws://127.0.0.1:9398` |

Both start automatically when the app launches and stop when the app quits.
Voice does not require an external `voxd` for normal operation.

## Agent API server

The menu bar app runs a WebSocket server on `ws://127.0.0.1:9399`.
It starts automatically when the app launches and stops when the app
quits.

### Checking status

```bash
lats daemon status
```

Or programmatically:

```js
import { isDaemonRunning, daemonCall } from '@lattices/lattices'

if (await isDaemonRunning()) {
  const status = await daemonCall('daemon.status')
  console.log(status) // { uptime, clientCount, version, windowCount, tmuxSessionCount }
}
```

### What it provides

- 35+ RPC methods for reading windows, sessions, projects, spaces, layers,
  processes, terminals, and OCR. Also launching/killing sessions, tiling
  windows, switching layers, and managing tab groups.
- 5 real-time events (`windows.changed`, `tmux.changed`, `processes.changed`,
  `layer.switched`, `ocr.scanComplete`) broadcast to all connected clients.
- Window tracking that monitors the desktop window list and correlates
  windows to lats sessions via title tags.
- Space awareness, so it knows which macOS Space each window is on.

### Security

The server binds to localhost only (`127.0.0.1:9399`). Not accessible
from the network. No authentication, so any local process can connect.
This is intentional — it's for local automation, not remote access.

Full method list in the [Agent API reference](/docs/api).

## Diagnostics

The diagnostics panel shows a timestamped log of window navigation
attempts, including which path succeeded or failed. Useful for
debugging Screen Recording / Accessibility permission issues.
