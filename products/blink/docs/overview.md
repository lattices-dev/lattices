---
title: Overview
description: What Canvas is, how to install it, and how it relates to Lattices.
---

# Canvas overview

Canvas is a native macOS app for floating Markdown notes. Each note is one
floating panel and one Markdown file. The panel remembers its position and size.
The app and the `canvas` CLI read and write the same local files, so a person and
an agent work on the same notes.

Canvas 2.3.0 ships `Canvas.app` and the `canvas` CLI through `@arach/blink`.
`Blink.app` and `blink` remain compatibility names. Existing note paths,
configuration keys, bundle identity and `blink.sock` remain unchanged.

**The note is the window, and the desktop is the workspace.**
Canvas has no library window and no Dock icon. It runs from the menu
bar with floating note panels, a menu bar popover, and a command palette.

## Install and launch

Requirements:

- macOS 14 or later on Apple Silicon.
- Node.js 18 or later for the npm command launchers.

1. Install the package. It includes the signed native `canvas` CLI.

   ```sh
   npm install -g @arach/blink    # or: bun add --global @arach/blink
   ```

2. Install the app. `canvas app install` downloads the signed, notarized
   release, validates it, and installs `Canvas.app` in `/Applications`.

   ```sh
   canvas app install
   ```

3. Launch the app.

   ```sh
   canvas app open
   ```

   Result: the app icon appears in the menu bar. If Lattices is running, Canvas
   hides its own icon by default (see `behavior.alwaysShowMenuBarIcon` in
   [Configuration](/canvas/docs/config)).

To update the app, run `canvas app update`. You can also download the DMG from
the [download page](https://lattices.dev/canvas/download).

## First note

Press Hyper+N to create a note. Hyper is Control+Option+Shift+Command. Hyper+B
shows or hides all note panels. You can change both hotkeys in `config.json`.

From a terminal or an agent:

```sh
canvas present standup "# Standup" --slot 6 --writer agent
canvas type standup "- shipped the CLI" --writer agent
canvas cat standup
```

`present` creates the note and sets its grid slot. `type` appends text that the
open panel reveals character by character. See [CLI](/canvas/docs/cli) for the
full command set.

## Agent surfaces

Use these agent surfaces in this order:

| Surface | Use it for | Reference |
|---|---|---|
| `blink` CLI | Create, read, edit, search, and delete notes; group and brand workspaces; open and arrange live panels. | [CLI](/canvas/docs/cli) |
| Files | Read or write `<id>.md` notes and `config.json` directly when the CLI does not fit. | [Concepts](/canvas/docs/concepts), [Configuration](/canvas/docs/config) |
| Agent socket | Query open panels, present notes, save and restore desks, and receive change events from the running app. | [Agent socket API](/canvas/docs/api) |

Install the agent skill to give a coding agent these instructions:

```sh
npx skills add arach/lattices --skill blink --global --yes
```

There is no Canvas MCP server today. The broader agent verb set and MCP layer in
[Agent API proposal](https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/agent-api.md) and
[Agent integration proposal](https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/agent-integration.md) are proposed, not
shipped.

## Relationship to Lattices

Canvas is a separate product in the Lattices family. It shares the Lattices
repository (`products/blink/`) and website, but it is not part of the Lattices
menu bar app.

- `Blink.app` (bundle ID `dev.arach.blink`) has its own process, lifecycle,
  release tags (`blink-v*`), and npm package (`@arach/blink`).
- Quitting Lattices does not quit Canvas. Quitting Canvas does not quit Lattices.
- The Lattices menu bar app can install and launch it from the current **Blink**
  entry in its Apps list.
  Canvas's note panels and NoteStore stay inside Canvas.
- There is no `lats canvas` command or family `canvas.*` API today. The earlier
  family-domain proposal is separate from this product rename. Operate Canvas
  with the `blink` CLI.

For the Lattices side of the family, see the
[Lattices overview](/lattices/docs/overview) and the
[product map](/products).

## Next steps

- [Concepts](/canvas/docs/concepts): the note, panel, and file model.
- [CLI](/canvas/docs/cli): every `blink` command.
- [Configuration](/canvas/docs/config): behavior, hotkeys, and appearance.
- [Workspaces](/canvas/docs/workspaces): named, branded groups of notes.
- [Placement](/canvas/docs/placement): the grid and slot model.
- [iOS sync](/canvas/docs/ios-sync): the read-only iPhone and iPad companion.
- [Release](/canvas/docs/release): how Canvas ships.
