---
title: Finding windows
description: The search tiers in Lattices, when to use each one, and how to turn a search result into a focused or tiled window
order: 1.3
---

Lattices finds windows at three depths. Index search is fast and usually
enough. Deep search inspects terminals live. Screen-text search reads the
words inside windows. This page says what each tier looks at, how to call it,
and when to step up.

Every tier needs the menu bar app running.

## Tier 1: index search

```bash
lats search tideline
```

`lats search` calls the daemon's `windows.search` method. It matches the
query against each window's title, app name, session tag and, when
screen-text search is on, the text the window shows. It reads data the app
already holds, so it returns at once.

Results are ranked. A title or session match scores 3, an app match 2, and a
screen-text match 1. Recent windows rank higher; add `--no-recency` to turn
that off.

Expected: a list of windows with their window ids, apps and titles, best
first. `No results for "tideline"` means no indexed field contains the word.

Narrow the sources when you need to:

```bash
lats search tideline --quick      # titles, apps and sessions only
lats search tideline --terminal   # terminal tabs only
```

## Tier 2: deep search

```bash
lats search tideline --deep
```

`--deep` (or `--all`) runs the index search, then inspects terminal windows
through the daemon's `terminals.search` method: each tab's working
directory, title, tmux session and running command. A terminal whose tabs
sit in `~/dev/tideline` matches even when "tideline" is not in its window
title. Each matching tab adds to the window's score, so a terminal with four
tideline tabs outranks one with a single tab.

Use deep search when you look for a project by name and the project name
lives in a directory path rather than a title. Use index search first; deep
search costs a live inspection of every terminal.

## Tier 3: screen text

Screen-text search needs Screen Recording permission and **Search & OCR** on
in Settings. It is off by default. With it on, the app reads text from
visible windows and keeps the latest results, which tier 1 then matches.

See what the app has read now:

```bash
lats scan            # the latest text per visible window
lats scan --full     # everything, not a summary
lats scan deep       # run a deep read of background windows now
```

Search the stored history with full-text syntax:

```bash
lats scan search "error OR failed"
lats scan history 4182     # every read of one window
lats scan recent 10
```

`lats scan search` and `lats scan history` read a SQLite database at
`~/.lattices/ocr.db`, which keeps three days of scans. The free build keeps
only the in-memory snapshot, so these two commands work in bundle builds
only. [Screen OCR and search](/lattices/docs/ocr) covers scan timing and
accuracy modes.

## Act on a result

Go to the top match:

```bash
lats place tideline            # focus and tile bottom-right
lats place tideline left
lats place tideline left --dry-run --json
```

`lats place` runs a deep search, focuses the first result and places it.
Pass `--dry-run` to see which window it would pick before it moves.

Pipe window ids into other commands:

```bash
lats search tideline --wid
lats window place $(lats search tideline --wid | head -1) right
```

Get structured results for a script:

```bash
lats search tideline --json
```

Each entry has `wid`, `app`, `title`, `score`, `reasons`, `tabs` and
`ocrSnippet`.

Raise a session's terminal by session name:

```bash
lats focus tideline-3f9a1c
```

## Choose a tier

| You want | Use |
|----------|-----|
| A window by a word in its title or app | `lats search <word>` |
| A terminal working in a project directory | `lats search <project> --deep` |
| The window and tile it | `lats place <word> [position]` |
| Windows showing an error message | `lats search <message>` with Search & OCR on |
| What a window showed earlier today | `lats scan history <wid>` (bundle builds) |

The command bar (Control+Option+Space) searches the same index with the same
scoring and shows screen-text matches as "Screen Text" results.

## From the daemon

```bash
lats call windows.search '{"query":"tideline"}'
lats call terminals.search '{"query":"tideline"}'
lats call ocr.snapshot '{}'
```

`windows.search` returns window objects with `matchSource` and
`ocrSnippet`. `terminals.search` returns one entry per terminal tab with its
`windowId`. [Agent API](/lattices/docs/api) documents the parameters.
