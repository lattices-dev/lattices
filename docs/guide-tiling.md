---
title: Tiling and placement
description: Move windows to named positions with keys, the CLI or the daemon, target an exact window, and undo a bad move
order: 1.2
---

A placement is a named region of a display. Lattices moves a window to a
placement from a key, from `lats tile`, or from a daemon call. This page
names the placements, shows each route, and explains how to target one exact
window instead of the front one.

Tiling needs the menu bar app running with Accessibility permission. Every
placement respects the menu bar and the Dock: it uses the visible desktop
area, not the whole screen.

## Placement names

| Name | Area |
|------|------|
| `left`, `right`, `top`, `bottom` | A half |
| `top-left`, `top-right`, `bottom-left`, `bottom-right` | A quarter |
| `left-third`, `center-third`, `right-third` | A vertical third |
| `maximize` | The whole visible area |
| `center` | 80% of the width and height, centered |
| `CxR:c,r` | One cell of a C-by-R grid, counted from 1 at the top left. `4x4:1,2` is the first column, second row. |
| `grid:CxR:c,r` | The same cell counted from 0. |

`left-half`, `right-half`, `top-half`, `bottom-half` and `max` are aliases.
[Tiling reference](/lattices/docs/tiling-reference) lists further named
positions such as sixths and eighths.

## Tile with a key

1. Bring the window to the front.
2. Press Command+Option+Shift and an arrow key.

Expected: the window fills that half of its display.

For pointer placement, enable Tile HUD in Settings. Then hold Control+Option
and move the pointer to aim a placement with the on-screen picker; release to
tile, or keep the pointer centered to cancel. Pointer placement is off by default.

The other default placement keys:

| Key | Placement |
|-----|-----------|
| Control+Option+Return | Maximize |
| Control+Option+C | Center |
| Control+Option+U / I / J / K | Top-left, top-right, bottom-left, bottom-right quarter |
| Control+Option+Shift+1 / 2 / 3 | Left, center, right third |
| With Tile HUD enabled, hold Control+Option and press 1 to 9 | That cell of the 3×3 matrix, laid out like a numpad. 5 maximizes |
| Control+Option+D | Distribute every visible window |

Settings > Shortcuts lists the full set and lets you change any of them. See
[Menu bar app](/lattices/docs/app#shortcuts).

## Tile with the CLI

`lats tile` moves the front window:

```bash
lats tile left
lats tile bottom-right
lats tile 3x3:2,2        # the centre cell of a 3-by-3 grid
```

Expected: the window moves and the command prints a receipt from the daemon.
When the app is not running, `lats tile` falls back to AppleScript on the
primary display and says so. The fallback cannot target other displays or
specific windows.

## Target an exact window

`lats tile` always takes the front window. To move a specific window, find
its window id first:

```bash
lats windows          # every visible window with its wid
lats map              # the same, drawn per display; --json for scripts
```

Then place it by id:

```bash
lats window place 4182 top-left                    # on its current display
lats window move 4182 --display 1                  # keep its relative frame
lats window move 4182 --display 1 --placement right
lats window focus 4182
```

Add `--dry-run --json` to see the plan without moving anything:

```bash
lats window move 4182 --display 0 --dry-run --json
```

A malformed wid is an error. These commands never fall back to the front
window.

## Find and place in one step

`lats place` searches for a window, focuses it and tiles it:

```bash
lats place tideline bottom-right
lats place "tideline dev" left --dry-run
```

It uses deep search, so a terminal whose tabs sit in `~/dev/tideline` matches
even when the word is not in the window title. See
[Finding windows](/lattices/docs/guide-search).

## Arrange several windows

```bash
lats tile family                     # grid every window of the front app
lats tile family "Google Chrome"     # grid one app's windows
lats tile family right               # keep the grid in the right half
lats distribute                      # grid every visible window
lats distribute Ghostty left
```

Press Hyper+G for the same job with the pointer: select windows on the
desktop, then Fill, Grid, Swap or Place them. Keep changes with Return;
restore the original frames with Escape. Hyper is Control+Option+Shift+
Command, and holding Caps Lock sends it by default.

## Undo a bad move

Lattices records a desktop map after every change and keeps them for 72
hours:

```bash
lats state                       # recent maps
lats state show                  # the latest one
lats state restore <id> --plan   # what a restore would do
lats state restore <id>
```

`lats state restore` puts windows back on the desktops and frames the map
has. It never changes display settings.

Before a risky change, name the current state:

```bash
lats state save before-demo
lats state restore before-demo
```

## From the daemon

Agents and scripts call `windows.place`:

```bash
lats call windows.place '{"wid":4182,"placement":"left"}'
lats call windows.place '{"wid":4182,"placement":{"kind":"grid","columns":3,"rows":2,"column":0,"row":1}}'
lats call windows.place '{"wid":4182,"placement":"left","dryRun":true}'
```

A placement is a plain name or a typed object with `kind` set to `tile`,
`grid` or `fractions`. `windows.resolve` tells you which window a target
would pick before you move it. [Agent guide](/lattices/docs/agents#placement-contract)
has the contract; [Agent API](/lattices/docs/api) has every method.

## Related

- [Configuration](/lattices/docs/config#tile-positions): the CLI reference
  for `lats tile` and `lats window`.
- [Layers](/lattices/docs/guide-layers): give each window a placement that
  Lattices restores when the layer switches in.
