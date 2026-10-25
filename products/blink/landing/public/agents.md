# Canvas — instructions for agents

Canvas is a native macOS spatial note-taking app. It is designed to be operated by humans and agents through the same local files.

Canvas is the new name for Blink. The 2.3.0 canonical release installs
`Canvas.app` and provides the `canvas` CLI. The package remains `@arach/blink`;
`blink` is a compatible command alias. Legacy download channels still use
`Blink.app`. Check the [release contract](https://lattices.dev/canvas/docs/release)
for the selected channel. Update the app and CLI together.

Keep existing file paths, `blink.*` frontmatter, and protocol identifiers
unchanged. The gateway identifies this product as `blink`, and `system.hello`
reports `"app": "Blink"` with `"displayName": "Canvas"`.

Canvas remains an independent app. The family commands `lats canvas` and
`lats blink` forward to Canvas without sharing the Lattices app lifecycle.

**The note is the window, and the desktop is the workspace**. A note is one floating panel in the running app and one Markdown file on disk. Opening an already-open note focuses its existing panel rather than creating a duplicate.

## Choose the right surface

- Operating Canvas: use the `canvas` CLI for notes and `config.json` for behavior and appearance. Use `blink` on an older installation.
- Reading or writing content: prefer CLI commands; plain file access is the lower-level escape hatch.
- Verifying live appearance or placement: use the GUI only when the task requires the rendered visual surface.
- Developing Canvas itself: read the repository's `AGENTS.md` before changing code.

The running app also serves a local Unix socket for a limited set of live panel, note, and desk operations, plus newline-delimited events. See the [implemented socket API](https://lattices.dev/canvas/docs/api) for the supported methods. The broader agent API proposal and an MCP server are not implemented. Use the CLI and filesystem for ordinary note edits.

## First check

```sh
canvas ls --json
```

Expected result: a JSON list of notes. The command reads files only. It does
not open panels. For automation that must not touch the user's notes, set
`CANVAS_HOME` to a scratch directory first:

```sh
export CANVAS_HOME="$(mktemp -d)"
canvas present hello $'# Hello\n\nFirst note from an agent.' --json
canvas cat hello
```

`present` creates the note `hello` and returns it as JSON. `cat` prints the
Markdown. The note lives only in the scratch directory. A Canvas app that runs
with the default home does not show it. Without a home override, the same
commands write to the user's notes, and a running app opens the note as a
panel.

## Requirements and install

- macOS 14 or newer
- Apple Silicon
- Node.js 18 or newer for the npm shims

```sh
npm install -g @arach/blink
canvas app install
canvas app open
```

The npm package includes the signed native CLI. `canvas app install` fetches
and validates the signed, notarized release before installing the app in
`/Applications`. The installer prefers the canonical Canvas channel when
versions tie; legacy releases retain `Blink.app`.

Check the installed CLI when version-sensitive behavior matters:

```sh
canvas --version
npm view @arach/blink version
```

## File layout

Default file-backed root:

```text
~/Library/Application Support/Blink/
├── Notes/
│   └── <id>.md
├── config.json
└── attachments/
```

The first nonempty `CANVAS_HOME`, then `BLINK_HOME`, overrides the file-backed
root for notes, config, attachments, ledger, and socket. Empty values are
ignored. Use the same override for the app and CLI for isolated tests and
automation. Older releases recognize `BLINK_HOME` only.

These overrides do not redirect device-local `UserDefaults`. Exact panel
frames, the open-panel set, and per-note read/edit mode remain Mac-local state.
The Mac app disables mobile sharing when either home override is active.

## Note model

- One Markdown file is one note.
- The filename stem and frontmatter `id` are a unique title-derived slug.
- The title is derived from the first meaningful content line.
- Note metadata and portable presentation live in YAML frontmatter.
- Unknown or foreign frontmatter must survive round trips.
- Portable placement intent such as `blink.slot` lives in frontmatter.
- Exact pixel geometry is device-local and must never be substituted for portable placement intent.

Example:

```md
---
id: q3-plan
blink:
  style: focus
  accent: "#7dd3fc"
  slot: 6
---
# Q3 plan

Ship something people love.
```

## Core commands

```sh
blink ls [--limit N] [--json]
blink cat <id> [--json]
blink new [text ...] [--json]
blink present <id> [text ...] [presentation options] [--json]
blink append <id> [text ...] [--json]
blink type <id> [text ...] [--json]
blink write <id> [text ...] [--json]
blink search <query> [--json]
blink rm <id> [--json]
blink path [<id>]
blink workspace <subcommand>
```

Commands accept stdin where content is optional. Prefer stdin when exact whitespace or multi-line Markdown matters.

### Choose the correct write verb

- `blink new`: create a note and let Canvas assign a unique slug.
- `blink present`: get or create a known id while changing content, presentation, and placement together. This is the default composition verb.
- `blink type`: append a visible update. If the panel is open, Canvas reveals the appended suffix as typed text.
- `blink append`: the established sibling of `type`; it also appends a visible update.
- `blink write`: quietly replace an existing note's body. Use only when full replacement is intended.
- `blink rm`: delete a note. Use only when deletion is explicitly intended.

## Common workflows

Create and place a complete note:

```sh
blink present q3-plan $'# Q3 plan\n\nShip something people love.' \
  --style focus --slot 6 --json
```

Read, search, and inspect paths:

```sh
blink ls --json
blink cat q3-plan
blink search "launch" --json
blink path q3-plan
```

Add a visible update without replacing the note:

```sh
printf '%s\n' '- rollout is green' | blink type q3-plan --json
```

Quietly replace the body from a file:

```sh
blink write q3-plan < revised-q3-plan.md
```

Create and use a named workspace:

```sh
blink workspace init "Acme Docs"
blink new --workspace acme-docs "# Q3 planning"
blink workspace notes acme-docs --json
```

A workspace is a generic group plus treatment. Its definition lives in `config.json`; note membership is one `blink.workspace` frontmatter key.

## Configuration

Edit:

```text
~/Library/Application Support/Blink/config.json
```

Canvas watches the file and hot-applies valid changes to behavior, hotkeys, panels, appearance, motion, editor styling, named styles, and workspaces. Prefer this file to driving the Settings UI.

Full reference: [Configuration](https://lattices.dev/canvas/docs/config)

## Safety rules

1. Prefer CLI mutations. Canvas's write path is atomic: temporary file, `fsync`, rename.
2. Preserve note content and frontmatter you do not own.
3. Do not replace a full note when an append or presentation-only change is enough.
4. If a user has unsaved text in an open panel, the user's text wins over an external edit.
5. Never move or rewrite device-local panel geometry casually. Spatial memory is part of the product contract.
6. Opening an open note should focus it, never create a duplicate.
7. Use `CANVAS_HOME` for isolated automation that must not touch the user's real note files. Set `BLINK_HOME` instead on older releases.
8. Treat workspaces as generic treatments; do not bake a third-party product identity into Canvas.

## Runtime behavior

External writes are first-class. The running app watches the Notes directory, calls `NoteStore.reconcile()`, and emits the same created/updated/deleted notifications as in-app changes. The menubar, command palette, and open panels then update from the same runtime path.

If Canvas is closed, CLI writes still succeed. The note is available when the app next opens.

## Canonical references

- Website: https://lattices.dev/canvas
- LLM overview: https://lattices.dev/canvas/docs/llms.txt
- Repository: https://github.com/arach/lattices/tree/main/products/blink
- CLI: https://github.com/arach/lattices/blob/main/products/blink/docs/cli.md
- Config: https://github.com/arach/lattices/blob/main/products/blink/docs/config.md
- Workspaces: https://github.com/arach/lattices/blob/main/products/blink/docs/workspaces.md
- Downloads: https://lattices.dev/canvas/download
- Development instructions: https://github.com/arach/lattices/blob/main/products/blink/AGENTS.md
