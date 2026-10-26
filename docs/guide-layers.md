---
title: Layers
description: What a workspace layer is, what happens when you switch, and how to build one from the keyboard, the CLI or workspace.json
order: 1.4
---

A layer is a named set of windows that belong to one piece of work. When
you switch to a layer, Lattices puts away the windows the layer does not use,
raises the ones it does, and lays them out. Layers replace most of what
macOS Spaces do, without moving windows between desktops.

Up to eight layers sit on a pad of slots numbered 1 to 4 and 6 to 9. Slot 5
means "the layer I am on".

The examples use an invented project, `tideline`.

## What a switch does

Every route to a switch, keyboard, command bar, CLI or API, does the same
three things in order:

1. **Put away.** Windows that the new layer does not use are hidden or
   parked. Apps with no window in the layer are hidden. Apps with some
   windows in the layer keep those and park the rest.
2. **Raise.** The layer's windows come to the front, matched by app, title,
   URL or project path.
3. **Lay out.** A layer with a `layout` arranges its windows. Entries with
   their own `tile` keep their place.

Nothing is closed. tmux sessions stay alive. A window belongs to at most one
layer. Choosing the layer you are already on gathers its windows back up.

## Switch with the keyboard

| Keys | Action |
|------|--------|
| Command+Option+1 to 4, 6 to 9 | Switch to the layer in that slot |
| Command+Option+5 | Show which layer is active |
| Control+Option+Shift+arrows | Move across the pad |
| Command+Option+T | Add the front window to the active layer |
| Command+Option+0 | Classic mode: every window back as if Lattices were not running |
| Command+Option+Z | Undo the last layer edit |

A switch shows a bezel with the pad. Settings > Shortcuts lists and changes
these bindings.

## Switch with the CLI

```bash
lats layer                 # list layers and slots
lats layer tideline        # by id or label
lats layer 1               # by pad slot
lats layer tideline --tile    # also move windows with a tile value
lats layer tideline --launch  # start missing projects, then tile
lats layer exit            # leave layers; restore parked windows
lats layer classic         # the same as Command+Option+0
lats layer undo
```

`lats layer exit`, `off`, `reveal` and `show-all` are the same action.

## Build a layer from what is on screen

The quickest way to make a layer is to arrange windows by hand and save them:

```bash
lats layer snap tideline              # the windows on screen become a layer
lats layer create tideline wid:4182 wid:4190
lats layer add wid:4201 --to tideline
lats layer remove wid:4201 --from tideline
lats layer rename tideline "Tideline web"
lats layer delete tideline
```

Find window ids with `lats windows` or `lats map`. A window added this way is
saved to `workspace.json` as its app and title, so it returns after a
restart. A window held by an entry that matches several windows, such as a
bare app name, cannot be removed on its own; edit that entry instead.

## Declare a layer in workspace.json

Layers live in `~/.lattices/workspace.json`. A layer for tideline with its
terminal, editor and browser:

```json
{
  "layers": [
    {
      "id": "tideline",
      "label": "Tideline",
      "layout": "auto",
      "projects": [
        { "path": "/Users/you/dev/tideline" },
        { "app": "Cursor", "title": "tideline" },
        { "app": "Google Chrome", "url": "http://localhost:3000", "launch": "open http://localhost:3000" }
      ]
    }
  ]
}
```

Each entry names one of `path`, `group` or `app`:

| Entry | Matches |
|-------|---------|
| `path` | The terminal window of that project's session |
| `app` with optional `title` or `url` | Windows of that app whose title contains `title` or whose URL starts with `url` |
| `group` | A tab group from the same file |

`launch` is a shell command that opens the entry when no window matches and
you switch with `--launch`. `tile` gives an entry a fixed placement; without
it the layer's `layout` decides.

| `layout` | Arrangement |
|----------|-------------|
| `auto` | Lanes by app kind: terminals left, editors in the middle, browsers right. Columns on an ultrawide; a half-and-stack on a standard display. |
| `columns` | Equal columns in entry order, up to four on an ultrawide and three otherwise. |
| `master-stack` | The first window takes the left 62%; the rest stack on the right. |

The app reads the file when it changes. A layer's position on the pad is its
position in the `layers` array.

## Leave layers

```bash
lats layer exit
```

Lattices clears the active layer, restores parked windows and unhides apps.
Saved layers stay in the file. Windows stay on the desktops they were on; a
parked window on a desktop that is not showing is restored when you next
visit that desktop.

## From the daemon

```bash
lats call layers.list '{}'
lats call layers.switch '{"name":"tideline"}'
lats call layers.switch '{"name":"tideline","mode":"launch"}'
lats call layers.exit '{}'
```

`layers.switch` takes `name` (id or label) or `index` (0-based position in
the list) and an optional `mode` of `tile` or `launch`. The daemon emits a
`layer.switched` event after each switch.

## Related

- [Workspace layers and tab groups](/lattices/docs/layers): every field,
  the put-away rules, rule-backed layers and the layer bar.
- [Sessions](/lattices/docs/guide-sessions): the `path` entries point at
  project sessions.
