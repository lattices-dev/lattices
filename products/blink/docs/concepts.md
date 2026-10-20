---
title: Concepts
description: Canvas's model of notes, panels, files, configuration, workspaces, and device sync.
---

# Canvas concepts

This page explains the model that the app, the CLI, and the agent socket share.
Read it before you script Canvas or change its code.

## The note is the window

A note is one Markdown file and, when it is open, one floating `NSPanel`.
Canvas keeps one panel for each note. If you open a note that is already open,
Canvas focuses the existing panel. It does not create a duplicate.

The menu bar popover and the command palette are launchers. They find and open
notes, but they are not alternate document windows. You read and edit a note in
its own panel.

## Capture, place, recall

The loop for a person is capture, place, recall:

1. **Capture.** Create or find a note from the menu bar popover, the command
   palette, or the global new-note hotkey (Hyper+N by default).
2. **Place.** Move, resize, shade, or focus panels to arrange a working set.
3. **Recall.** Canvas restores each note to the same place and size. Hyper+B
   shows or hides all panels.

An agent follows the same loop with `blink present`, `blink desk`, and the
[agent socket](/canvas/docs/api).

## Files are the truth

The Markdown files are the durable truth for notes.

| Item | Location |
|---|---|
| Notes | `~/Library/Application Support/Blink/Notes/<id>.md` |
| Configuration | `~/Library/Application Support/Blink/config.json` |
| Attachments and brand marks | `~/Library/Application Support/Blink/attachments/` |
| Saved desks | `~/Library/Application Support/Blink/desks/<name>.json` |
| Edit ledger | `~/Library/Application Support/Blink/edits.sqlite` |
| Agent socket | `~/Library/Application Support/Blink/blink.sock` |

If `BLINK_HOME` is set, Canvas uses that directory as the root for every item in
this table. Use `BLINK_HOME` to sandbox notes for tests or agents.
`BLINK_HOME` does not redirect `UserDefaults`. Canvas disables device sync while
`BLINK_HOME` is set.

Each note file holds the body and its metadata together. Metadata is YAML
frontmatter:

```markdown
---
id: q3-planning
created: 2026-07-25T22:39:44.042Z
updated: 2026-07-25T22:39:44.042Z
tags: []
pinned: false
blink:
  workspace: acme-docs
  slot: 6
  lastWriter: agent
---
# Q3 Planning
```

- The `id` is a unique slug derived from the title. It is also the file name.
- The `blink:` block holds presentation intent: `workspace`, `style`, `sheet`,
  `accent`, `font`, `fontSize`, `lineHeight`, `tint`, `tintRead`, `tintEdit`,
  `radius`, `slot`, and `lastWriter`.
- Canvas preserves frontmatter keys that it does not own. You can add your own
  keys, and they survive every save.
- All writes are atomic: Canvas writes a temporary file, syncs it, and renames it.

The edit ledger (`edits.sqlite`) records who changed each note. It is not a
second note store. If the ledger is missing or a ledger write fails, the note
save still succeeds. Read it with `blink log <id>`.

## How changes converge

Every change reaches the same store through one path:

```text
panel edits / popover actions  -> PanelManager / AppModel -> NoteStore -> atomic .md
CLI / external writes          -> same .md -> directory watcher -> NoteStore.reconcile()
NoteStore notifications        -> AppModel snapshot -> popover / palette / open panels
```

- `NoteStore` owns note mutations and the in-memory index.
- `AppModel` mirrors `NoteStore` for the user interface. It is not a second store.
- `PanelManager` owns live panels: one panel per note, focus, pending editor
  text, geometry, and save flushing.
- External writers are first-class. When a script or the CLI writes a file, the
  directory watcher calls `NoteStore.reconcile()`. The open panel updates the
  same way it does for an in-app edit. If the person has unsaved edits in that
  panel, the person's edits win.

The CLI works when the app is closed because it writes files. The `blink desk`
commands and the agent socket need the running app.

## Panels and placement

A panel has a mode (read or edit), a frame, and a display. It can also be
shaded, which folds it into its top band.

Two kinds of placement exist:

- **Placement intent** is portable. The `blink.slot` key (1 to 9) names a cell
  in a 3×3 grid on the panel's display. `blink present --slot N` sets it.
- **The exact frame** is per device. Canvas stores each panel's frame, the set of
  open panels, and each note's mode in `UserDefaults`.

A **desk** is a named snapshot of the open panels with their frames, slots,
modes, and displays. `blink desk save` and `blink desk restore` write and apply
desks. See [Placement](/canvas/docs/placement) for the grid model and which parts
are proposed.

## Configuration

`config.json` owns behavior and appearance: hotkeys, panel material, editor
typography, motion, physics, the drape backdrop, named styles, and workspace
definitions. The running app watches the file and applies changes without a
restart. A missing key uses its default. If the file does not parse, Canvas logs
the error and keeps the last valid configuration. Agents should edit this
file instead of driving the Settings window. See
[Configuration](/canvas/docs/config).

## Workspaces

A workspace is a named group of notes with an optional brand. It has two parts:

| Part | Lives in | Holds |
|---|---|---|
| Definition | `config.json` → `workspaces.<name>` | Title and brand (mark, palette, typography, corners). |
| Membership | Each note's `blink.workspace` key | The workspace name only. |

A note never carries colors, fonts, or asset paths for its workspace, so the
file stays portable Markdown. See [Workspaces](/canvas/docs/workspaces).

## Device sync

The iPhone and iPad companion is a read-only, offline view of the Mac's notes.
The Mac serves a complete snapshot over an encrypted local-network channel
(`BlinkPeer`, Multipeer Connectivity with an end-to-end sealed payload). A new
device must be approved on the Mac. You can revoke it from **Mobile Access** in
Canvas's right-click menu. The local network is the only route today. See
[iOS sync](/canvas/docs/ios-sync).

## Boundary with Lattices

Canvas is a separate app with its own lifecycle. The Lattices menu bar app does
not own Canvas's panels, NoteStore, or files. Lattices can install and launch
Canvas, and the two apps share the repository and website. See the
[Canvas overview](/canvas/docs/overview#relationship-to-lattices).
