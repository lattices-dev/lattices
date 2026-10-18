---
title: Configuration
description: CLI commands, .lattices.json format, and tile positions
order: 2
---

## .lattices.json

Place a `.lattices.json` file in your project root to define your
workspace layout. lattices reads this file when creating a session.

### Minimal example

```json
{
  "panes": [
    { "name": "shell" },
    { "name": "server", "cmd": "pnpm dev" }
  ]
}
```

### Full example

```json
{
  "ensure": true,
  "panes": [
    { "name": "shell", "size": 60 },
    { "name": "server", "cmd": "pnpm dev" },
    { "name": "tests",  "cmd": "pnpm test --watch" }
  ]
}
```

## Config fields

| Field    | Type    | Required | Description                                          |
|----------|---------|----------|------------------------------------------------------|
| panes    | array   | no       | List of pane definitions (see below)                 |
| ensure   | boolean | no       | Auto-restart exited commands on reattach              |
| prefill  | boolean | no       | Type exited commands into idle panes on reattach (you hit Enter) |

`ensure` and `prefill` are mutually exclusive. If both are set,
`ensure` takes priority.

- **ensure** — when you reattach to an existing session, lattices checks
  each pane. If a pane's process has exited and the shell is idle, lattices
  automatically re-runs its declared command.
- **prefill** — same check, but the command is typed into the pane
  without pressing Enter. You review and hit Enter yourself.

## Pane fields

| Field  | Type   | Required | Description                         |
|--------|--------|----------|-------------------------------------|
| name   | string | no       | Label for the pane (shown in app)   |
| cmd    | string | no       | Command to run when pane opens      |
| size   | number | no       | Width % for the first pane (1-99)   |

- `size` only applies to the **first pane**. It sets the width of the
  main pane as a percentage. Default is 60.
- `cmd` can be any shell command. If omitted, the pane opens a shell.
- `name` is used in the lats app to show a summary of your layout,
  and as a target for `lats restart <name>`.

## Layouts

lattices picks a layout based on how many panes you define:

### 2 panes — side by side

```
┌──────────┬─────────┐
│  shell   │ server  │
│  (60%)   │ (40%)   │
└──────────┴─────────┘
```

Horizontal split. First pane on the left, second on the right.

### 3+ panes — main-vertical

```
┌──────────┬─────────┐
│  shell   │ server  │
│  (60%)   ├─────────┤
│          │ tests   │
└──────────┴─────────┘
```

First pane takes the left side. Remaining panes stack vertically
on the right.

### 4 panes

```
┌──────────┬─────────┐
│  shell   │ server  │
│  (60%)   ├─────────┤
│          │ tests   │
│          ├─────────┤
│          │ logs    │
└──────────┴─────────┘
```

## Auto-detection (no config)

If there's no `.lattices.json`, lattices still works. It will:

1. Create a 2-pane layout (60/40 split)
2. Open a shell in the left pane
3. Auto-detect your dev command from package.json scripts and run it on the right:
   - Looks for: `dev`, `start`, `serve`, `watch` (in that order)
   - Detects package manager: bun > pnpm > yarn > npm

## Creating a config

Run `lats init` in your project directory to generate a starter
`.lattices.json` based on your project. The generated config includes
`"ensure": true` by default.

## CLI commands

| Command                    | Description                                      |
|----------------------------|--------------------------------------------------|
| `lats`                   | Show workspace status and common commands         |
| `lats start`             | Create or attach to session for current project   |
| `lattices tmux`              | Alias for `lats start`                        |
| `lats init`              | Generate .lattices.json config for this project     |
| `lats ls`                | List active sessions (requires tmux)              |
| `lats kill [name]`       | Kill a session (defaults to current project)      |
| `lats sync`              | Reconcile session to match declared config        |
| `lats restart [pane]`    | Restart a pane's process (by name or index)       |
| `lats tile <position>`   | Tile the frontmost window to a screen position    |
| `lats tile family [app] [region]` | Smart-grid the frontmost app family, or a named app |
| `lats window move <wid> --display <n> [--placement <slot>]` | Move a window to another display |
| `lats window place <wid> <slot> [--display <n>]` | Snap a window into a placement slot |
| `lats distribute [app] [region]` | Smart-grid visible windows or just one app      |
| `lats group [id]`        | List tab groups or launch/attach a group          |
| `lats groups`            | List all tab groups with status                   |
| `lats tab <group> [tab]` | Switch tab within a group (by label or index)     |
| `lats app`               | Launch the menu bar companion app                 |
| `lats app install`       | Register launch-at-login and start now            |
| `lats app login status`  | Show launch-at-login registration                 |
| `lats app login disable` | Disable launch-at-login                           |
| `lats update`            | Update lattices (CLI + app), keep startup, relaunch |
| `lats app update`        | Swap in the latest app release only (not the CLI) |
| `lats app build`         | Rebuild the menu bar app from source              |
| `lats app restart`       | Rebuild and relaunch the menu bar app             |
| `lats layer [name\|slot]` | Switch to a workspace layer by name or pad slot (1-4, 6-9) |
| `lats windows [--json]`  | List all visible windows                          |
| [`lats map [--json]`](/docs/workspace-map) | Read-only current-Space terminal/JSON map |
| `lats layer add wid:N --to <layer>` | Add a window to a layer               |
| `lats layer remove wid:N --from <layer>` | Take a window out of a layer     |
| `lats actor toggle`      | Hide/show persistent overlay actors               |
| `lats hud register [manifest]` | Register a `.lattices/hud/manifest.json`   |
| `lats hud publish [id\|manifest]` | Publish a static HUD actor to the desktop |
| `lats hud sync`          | Publish all registered HUD actors                 |
| `lats search <query>`      | Search windows by title, app, session, OCR       |
| `lats search <q> --deep`   | Deep search: index + live terminal inspection    |
| `lats search <q> --all`    | Same as `--deep` (all search sources)            |
| `lats search <q> --wid`    | Print matching window IDs only (pipeable)        |
| `lats place <query> [pos]` | Deep search + focus + tile (default: bottom-right)|
| `lats focus <session>`   | Focus a session's window and switch Spaces        |
| `lats scan search <query>` | Search indexed screen text                       |
| `lats action`            | Action product status (install, agent, checkout)  |
| `lats action install`    | Download the latest Action.app release to /Applications |
| `lats action launch`     | Open Action.app (`--launch` also works on install) |
| `lats action quit`       | Quit Action.app                                   |
| `lats action call <m>`   | Raw Action agent call (ws://127.0.0.1:4319)       |
| `lats action <cmd>`      | Forward to the Action CLI (monorepo checkout)     |
| `lattices diag [limit]`       | Show recent diagnostic entries                   |
| `lats app`               | Launch the menu bar companion app                 |
| `lats app install`       | Register launch-at-login and start now            |
| `lats app login status`  | Show launch-at-login registration                 |
| `lats app login disable` | Disable launch-at-login                           |
| `lats update`            | Update lattices (CLI + app), keep startup, relaunch |
| `lats app update`        | Swap in the latest app release only (not the CLI) |
| `lats app build`         | Rebuild the menu bar app from source              |
| `lats app restart`       | Rebuild and relaunch the menu bar app             |
| `lats app quit`          | Stop the menu bar app                             |
| `lats help`              | Show help                                         |

Aliases: `ls`/`list`, `kill`/`rm`, `sync`/`reconcile`,
`restart`/`respawn`, `tile`/`t`.

## Keyboard remaps

The menu bar app can create a lightweight keyboard layer from
`~/.lattices/keyboard-remaps.json`. The default config is:

```json
{
  "rules": [
    {
      "enabled": true,
      "from": "caps_lock",
      "id": "caps_lock_hyper_escape",
      "toIfAlone": "escape",
      "toIfHeld": "hyper"
    }
  ]
}
```

It is enabled by default and can be turned off from Settings -> General ->
Keyboard remaps. Hold Caps Lock to send Hyper (`Control` + `Option` +
`Shift` + `Command`), or tap Caps Lock alone to send Escape.

## Machine-readable output

### `--json` flag

`lats windows --json` returns the raw window array.
[`lats map --json`](/docs/workspace-map) returns a versioned, per-display
current-Space snapshot with coordinate metadata:

```bash
lats windows --json
lats map --json
```

Both are useful for piping into `jq` or consuming from scripts.

### Daemon responses

All agent API calls return JSON natively. If you need structured data
from lattices, the daemon is easier than parsing stdout. See the
[API reference](/docs/api).

### Exit codes

| Code | Meaning                                     |
|------|---------------------------------------------|
| `0`  | Success                                     |
| `1`  | General error (missing args, bad config)    |
| `2`  | Session not found                           |

## Recovery

### sync

```
lats sync
```

Reconciles a running session to match the declared config:

1. Counts actual panes vs declared panes
2. Recreates any missing panes
3. Re-applies the layout (main-vertical with correct width)
4. Restores pane labels
5. Re-runs declared commands in any idle panes

Use when a pane was killed and you want to get back to the declared
state without killing the whole session.

### restart

```
lats restart [target]
```

Kills the process in a specific pane and re-runs its declared command.
The target can be:

- A **pane name** (case-insensitive): `lats restart server`
- A **0-based index**: `lats restart 1`
- **Omitted** (defaults to pane 0): `lats restart`

The restart sequence: send Ctrl-C, wait 0.5s, check if the process
stopped. If it's still running, escalate to SIGKILL on child
processes. Then send the declared command.

## Tile positions

The `lats tile` command moves the frontmost window to a preset
screen position. Available positions:

| Position       | Area                        |
|----------------|-----------------------------|
| `left`         | Left half                   |
| `right`        | Right half                  |
| `top`          | Top half                    |
| `bottom`       | Bottom half                 |
| `top-left`     | Top-left quarter            |
| `top-right`    | Top-right quarter           |
| `bottom-left`  | Bottom-left quarter         |
| `bottom-right` | Bottom-right quarter        |
| `maximize`     | Full screen (visible area)  |
| `left-third`   | Left third                  |
| `center-third` | Center third                |
| `right-third`  | Right third                 |
| `center`       | 80% width, 80% height, centered (20% margin all sides) |

Aliases: `left-half`/`left`, `right-half`/`right`, `top-half`/`top`,
`bottom-half`/`bottom`, `max`/`maximize`.

Tiling respects the menu bar and dock. It uses the visible desktop
area, not the full screen.

For arbitrary cells, use compact `CxR:c,r` with 1-indexed coordinates
from the top-left, or canonical `grid:CxR:c,r` with 0-indexed coordinates.
Example: `lats tile 4x4:1,2`.

When the menu bar app is running, `lats tile` routes through the daemon's
canonical `windows.place` and reports a verified receipt. Without the daemon it
falls back to AppleScript (frontmost app, primary display) and says so.

### Moving a specific window

`lats tile` always targets the frontmost window. To move a *specific*
window — by the CGWindowID shown in `lats map` or `lats windows` —
use `lats window move` / `lats window place` (daemon required):

```bash
lats window move 4182 --display 1                  # keep relative size/position
lats window move 4182 --display 1 --placement right
lats window place 4182 top-left                    # slot on its current display
lats window move 4182 --display 0 --dry-run --json       # plan without moving
```

A malformed wid is an error; these commands never fall back to the frontmost
window. Slots are the named positions above plus grid placements; fractional
typed placements remain available via `lats call windows.place`.

### Smart app tiling

Use `lats tile family` when you want lattices to arrange a whole
window family instead of just moving the frontmost window.

Examples:

```bash
lats tile family
lats tile family right
lats tile family iTerm2
lats tile family "Google Chrome" left
```

- With no app name, `family` means the **frontmost app**. If iTerm is
  frontmost, lattices grids your visible iTerm windows.
- If you pass a region (`left`, `right`, `top`, `bottom`, etc.), the
  smart grid is constrained to that part of the screen.
- `lats distribute` uses the same smart grid engine, but defaults to
  **all visible windows** instead of the current app family.
