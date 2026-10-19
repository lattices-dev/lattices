# Canvas CLI

The 2.3.0 release contract uses `canvas`; `blink` remains a compatible
executable alias, and the npm package remains `@arach/blink`. The examples below
use `canvas`; substitute `blink` on an older installation. Update the app and
CLI together for 2.3.0's stricter private IPC permissions. See the
[release contract](release.md) for canonical and legacy downloads.

The CLI reads and writes the same files as the app. Writes are atomic and
slug-safe via BlinkCore. The running app picks every change up
**live**: it watches the Notes directory, reconciles disk against memory, and
routes the diff through
the same notifications in-app edits use. Create a note from a script and it's
in the popover a second later; edit an open note's file and the panel updates
in place (unless the user has unsaved edits in flight — then the user wins).

## Where it operates

```
$CANVAS_HOME/Notes                                 # first nonempty override
$BLINK_HOME/Notes                                  # compatible fallback
~/Library/Application Support/Blink/Notes           # default, unchanged
```

Current source builds of the app and both CLI names use the first nonempty
`CANVAS_HOME`, then `BLINK_HOME`; empty values are ignored. Use the same value
for both processes to isolate file-backed notes, config, attachments, ledger,
and socket. The override does not redirect `UserDefaults`. The Mac app disables
mobile sharing with either override. Older releases recognize `BLINK_HOME` only.

The rename preserves the default data directory, `blink.sock`, `blink.*`
frontmatter, and `blink://attachments/` URLs. Do not rename these on disk.

## Build / install

```sh
swift build -c release --product canvas
cp .build/release/canvas ~/bin/   # or anywhere on PATH
```

`swift build --product blink` remains supported. The current source family
entry points `lats canvas` and `lats blink` forward to the product. App installer
verbs belong to the npm wrapper or family entry point, not the Swift notes CLI.

## Commands

Commands that expose structured output take `--json` where shown below. Errors
go to stderr with a nonzero exit code.

```sh
canvas ls [--limit N] [--json]     # list notes, most recently updated first
canvas cat <id> [--json]           # print content (exact bytes); --json adds all metadata
canvas new [text ...] [--writer W] [--json]
canvas present <id> [text ...] [--style … --slot … --writer W] [--json]
canvas append <id> [text ...] [--writer W] [--json]
canvas type <id> [text ...] [--writer W] [--json]
canvas write <id> [text ...] [--writer W] [--json]
canvas search <query> [--json]
canvas rm <id> [--writer W] [--json]
canvas log <id> [--limit N] [--json]   # append-only edit ledger
canvas path [<id>]
canvas workspace <subcommand>
canvas desk <subcommand>
```

`workspace` is the grouping/branding verb set — see `docs/workspaces.md` for the
full guide:

```sh
canvas workspace init <name> [--title T] [brand flags…]   # create (idempotent)
canvas workspace ls                                       # list + note counts
canvas workspace show <name>                              # definition + effective brand
canvas workspace brand <name> [brand flags…]              # mark, palette, type, corners
canvas workspace add <name> <id>…                         # put notes in it
canvas workspace remove <id>…                             # take notes out
canvas workspace notes <name>                             # list member notes
canvas workspace rm <name> [--detach]                     # forget the definition
```

`new` and `present` also take `--workspace <name>` so a note can be filed on
creation. Membership is one `blink.workspace:` key in the note's frontmatter;
the brand itself lives in `config.json`, so note markdown stays portable and
free of presentation-only branding. In the running app, the capture popover's
workspace selector filters the log/canvas and recalls only that workspace's
open panels; notes created while a named workspace is active inherit it.

`present` is the compound arrival verb: it sets a note's markdown **and** its
`blink:` presentation metadata in one write, get-or-create
by id. Only the fields you pass change; the rest are preserved. Its options mirror
the `blink:` keys: `--style --sheet --accent --font --font-size --line-height
--tint --tint-read --tint-edit --radius --slot`. `--slot 1–9` is placement intent
for the grid. Omit the text to change presentation alone.

`type` and `write` are the two ways to change a note's body, and they differ only
in *how the open panel reacts*: `type` appends an anchored suffix, so the running
app reveals it character by character (the visible hand); `write` replaces the
whole body, so the panel updates in place with no animation. `append` is the
established sibling of `type` (identical behavior). All three preserve presentation
and foreign frontmatter.

`--writer` stamps `blink.lastWriter` on the note and appends a row to
`<home>/edits.sqlite` under the selected data directory.
The markdown file stays truth: a ledger failure never fails the save.
Omit `--writer` and the CLI records `cli`. In-app edits record `user`.
`canvas log` reads that sidecar even after `rm`; it is not a second note store.


`desk` is the intentionally small live counterpart to the file API. It asks the
running Canvas app to realize an existing note as a panel while `PanelManager`
continues to own one-panel-per-note identity, focus, save flushing, and geometry
persistence. Coordinates are display-local AppKit points measured from the
visible top-left corner; omitted frame values preserve the current value.
`--display N` selects a one-based display (`1` is the main display); otherwise
the panel stays on its current display.

```sh
canvas desk open standup --display 1 --x 980 --y 90 --width 460 --height 260
canvas desk move standup --x 1130 --y 70     # visible lock-and-settle
canvas desk focus standup
canvas desk close standup                    # closes the panel, keeps the note
canvas desk screens --json                   # responsive-script display geometry
```

Examples:

```sh
canvas new "grocery run"                    # → grocery-run
printf '# Standup\n\n- ship CLI\n' | canvas new --json
canvas present q3-planning "# Q3 Planning" --style focus --slot 6   # content + look + place
canvas present q3-planning --accent "#9ece6a"   # presentation-only; body untouched
canvas append grocery-run "- oat milk"      # types on live if the panel is open
canvas type standup "shipped the CLI verbs"     # same visible-hand reveal, phrasebook name
printf '%s\n' '- ship docs' | canvas append standup --json
canvas write standup < revised-standup.md       # replace the body, no animation
canvas cat grocery-run
canvas search standup --json | jq '.[0].id'
open "$(canvas path grocery-run)"           # hand the file to anything

canvas workspace init "Acme Docs"                     # a named, brandable group
canvas new --workspace acme-docs "# Q3 Planning"      # file a note into it
canvas workspace brand acme-docs --accent "#7aa2f7" --install-mark ~/acme.svg
canvas workspace notes acme-docs --json | jq -r '.[].id'
```

## JSON shape

```jsonc
{
  "id": "standup",
  "title": "Standup",
  "tags": [],
  "pinned": false,
  "created": "2026-07-14T19:51:41.934Z",
  "updated": "2026-07-14T19:51:41.934Z",
  "path": "/Users/you/Library/Application Support/Blink/Notes/standup.md",
  "content": "…",             // cat/append --json only
  "extraFrontmatter": []        // cat/append --json only — foreign keys, preserved verbatim
}
```

## Or skip the CLI entirely

The filesystem is the API (layer 1): notes are frontmattered markdown, one
file per note. You may edit them with anything — Canvas preserves frontmatter
keys it doesn't own and merges on-disk metadata before every save, so foreign
keys survive. The CLI just adds atomic writes, correct slug assignment, and
structured output for free. Prefer it for *creating* notes (slug uniqueness),
`append` when an agent should add a visible update without replacing the note,
and any scripted workflow. `append` always writes exactly one separating
newline before the supplied text; stdin bytes after that separator are kept as
provided.

`canvas link` and a product MCP server are not implemented. The agent API and
MCP documents describe proposals; the existing local socket serves live panel
commands.
