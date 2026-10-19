---
name: blink
description: Drive Canvas (formerly Blink) spatial notes on macOS. Use when creating, reading, searching, presenting, typing into, or placing floating notes through canvas or the compatible blink CLI, or when the user asks for Canvas, Blink, spatial notes, or a note on the desktop.
compatibility: Requires macOS. Canvas 2.3.0 adds canvas and Canvas.app; blink and Blink.app remain supported for legacy installations. Verify the selected release. Both use the same Markdown files.
metadata:
  author: arach
  homepage: https://lattices.dev/canvas
---

# Canvas

Canvas is spatial notes. Each note is a floating panel. The desktop is the
workspace. Agents drive it with the `canvas` CLI, which writes the same
Markdown files the app watches.

When this skill is invoked, run the command. Summarize the result. Do not
narrate the plan first. Do not drive the Canvas GUI unless the task needs the
live visual surface.

## Prerequisite

Use `canvas` when installed; otherwise use `blink` with the same note verbs.
The examples below use `canvas`. Check the selected command before changing
notes:

```bash
canvas ls --json
# Existing Blink installations: blink ls --json
```

If neither command is installed, the published npm package remains
`@arach/blink`. Version 2.3.0 provides both names; older releases expose `blink`
and install `Blink.app`:

```bash
npm install -g @arach/blink
blink app install
blink app open
```

The 2.3.0 release contract adds `Canvas.app`, `canvas`, and `canvas-app`, retaining
`blink` and `blink-app` aliases. Legacy downloads contain a real `Blink.app`
with Canvas's visible name and unchanged identity. Check publication and the
selected artifact before describing installed behavior. The installable skill
identifier remains `blink`.

Do not invent note ids. Read them from `canvas ls --json` or `canvas search`.
`canvas new` and `canvas present` print the id they created or used.

## Choose a verb

Prefer the CLI. The Markdown files are the durable store. The running app
reconciles disk and updates open panels.

| Need | Command |
| --- | --- |
| List notes | `canvas ls --json` |
| Read a note | `canvas cat <id>` |
| Search | `canvas search "<query>" --json` |
| Create | `canvas new "title"` or stdin into `canvas new --json` |
| Content, look, and place | `canvas present <id> "<markdown>" --style … --slot N` |
| Visible typed reveal | `canvas type <id> "text"` |
| Quiet whole-body replace | `canvas write <id> < file.md` |
| Append | `canvas append <id> "text"` |
| Open or move a panel | `canvas desk open <id>` / `canvas desk move <id>` |
| Delete | `canvas rm <id>` |

`present` is the usual write. It get-or-creates by id and changes only the
fields you pass. Omit the text to change presentation alone.

`type` and `append` reveal new text in an open panel. `write` replaces the
body with no animation. All three preserve presentation and unknown
frontmatter.

## Recipes

### Capture a note and place it

```bash
canvas present q3-planning $'# Q3 planning\n\nPlan the next release.' \
  --style focus --slot 6 --json
```

`--slot 1-9` is placement intent for the grid. The device-specific panel
frame is owned by the Canvas app.

### Add a visible update

```bash
canvas type q3-planning "Shipped the CLI verbs" --json
```

### File a note into a workspace

```bash
canvas workspace init "Acme Docs"
canvas new --workspace acme-docs "# Q3 Planning"
canvas workspace notes acme-docs --json
```

A workspace brand lives in `config.json`. Membership is one
`blink.workspace` key on the note. Do not copy colors or fonts into the
Markdown.

### Open a panel on a display

```bash
canvas desk screens --json
canvas desk open q3-planning --display 1 --x 980 --y 90 --width 460 --height 260
canvas desk focus q3-planning
```

`desk close` closes the panel and keeps the note.

## Paths and sandbox

Default notes directory:

`~/Library/Application Support/Blink/Notes/<id>.md`

Current source builds use the first nonempty `CANVAS_HOME`, then `BLINK_HOME`,
to isolate file-backed notes, config, attachments, ledger, and socket. Empty
values are ignored. Use the same override for app and CLI. Neither redirects
`UserDefaults`, and either disables the Mac peer host. Older releases recognize
`BLINK_HOME` only.

The rename preserves the default directory, `blink.sock`, `blink.*` frontmatter,
attachment URLs, settings, and paired-device identities. Do not move the data or
rewrite these identifiers as part of the rename.

`--writer` stamps `blink.lastWriter` and appends a ledger row. Omit it and
the CLI records `cli`. A ledger failure must not fail the save.

## Live docs

Do not copy the full CLI catalog into context. Read it when needed:

1. `canvas --help`
2. https://lattices.dev/canvas/docs/cli
3. `products/blink/docs/cli.md` in this repository
4. `products/blink/docs/workspaces.md` for workspace brand and membership
