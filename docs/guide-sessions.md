---
title: Sessions
description: How Lattices turns a project directory into a tmux session, and how to declare, start, repair and find one
order: 1.1
---

A session is a tmux session that Lattices creates for one project
directory. The project declares its panes in a `.lattices.json` file.
`lats start` builds the panes, runs their commands and attaches your
terminal. The session keeps running after you detach or close the terminal.

Sessions need tmux (`brew install tmux`). Window tiling, search, layers and
the agent API work without tmux.

The examples use an invented project, `tideline`, at `~/dev/tideline`.

## How a session is named

Lattices derives the session name from the directory:

```
<directory basename>-<first 6 hex characters of sha256(absolute path)>
```

`~/dev/tideline` becomes something like `tideline-3f9a1c`. The hash makes two
checkouts with the same basename distinct. Lattices tags the terminal
window's title with `[lattices:tideline-3f9a1c]`, which is how the app and
`lats search` find the window later.

## Declare the panes

Create a starter config:

```bash
cd ~/dev/tideline
lats init
```

`lats init` writes `.lattices.json` with `"ensure": true` and either two
panes or one. It writes two panes when `package.json` has a `dev`, `start`,
`serve` or `watch` script, checked in that order, and it picks the package
manager by lockfile: bun, then pnpm, then yarn, then npm. Without such a
script it writes a single shell pane.

A config for tideline with a shell, a dev server and a test watcher:

```json
{
  "ensure": true,
  "panes": [
    { "name": "shell", "size": 60 },
    { "name": "server", "cmd": "bun dev" },
    { "name": "tests", "cmd": "bun test --watch" }
  ]
}
```

| Field | Meaning |
|-------|---------|
| `panes[].name` | Label shown in the app. Also the target for `lats restart <name>`. |
| `panes[].cmd` | Shell command to run when the pane opens. Omit it for a plain shell. |
| `panes[].size` | Width of the first pane as a percentage, 1 to 99. Default 60. Ignored on other panes. |
| `ensure` | On reattach, re-run a pane's command when its process has exited and the shell is idle. |
| `prefill` | On reattach, type the exited command into the pane without pressing Return. |

`ensure` and `prefill` are exclusive. When both are set, `ensure` wins.

The pane count picks the layout:

| Panes | Layout |
|-------|--------|
| 1 | One full-width pane |
| 2 | Side by side. The first pane takes `size` percent of the width. |
| 3 or more | The first pane takes the left side. The rest stack on the right. |

A directory with no `.lattices.json` still starts. Lattices uses the same
two-pane or one-pane default that `lats init` would write, without saving it.

## Start, detach, reattach

```bash
cd ~/dev/tideline
lats start
```

Expected: tmux opens with the declared panes and each `cmd` running. If the
session already exists, `lats start` reattaches instead of rebuilding it.

Detach with Ctrl+B then D. The panes and their processes keep running.

Run `lats start` again from the same directory to reattach. With `ensure`
set, a pane whose command has exited restarts on reattach. With `prefill`
set, the command is typed into the pane for you to review and run.

`lats` on its own prints the directory's session name, config and app
status. It does not attach.

`lats tmux` is an alias for `lats start`.

## See what is running

```bash
lats ls          # tmux sessions, with their tab group when they have one
lats status      # managed and unmanaged sessions
lats sessions    # sessions as the daemon sees them; --json for scripts
```

`lats ls` prints `No active sessions.` when tmux has none.

## Repair a session

Restart one pane's command:

```bash
lats restart server   # by name, case-insensitive
lats restart 1        # by 0-based index
lats restart          # pane 0
```

`lats restart` sends Ctrl-C, waits half a second, escalates to SIGKILL on the
pane's child processes if needed, then sends the declared command.

Rebuild missing panes without killing the session:

```bash
lats sync
```

`lats sync` counts the panes, recreates missing ones, reapplies the layout,
restores the labels and re-runs declared commands in idle panes. Use it
after you closed a pane by hand.

Kill a session:

```bash
lats kill            # the current directory's session
lats kill tideline-3f9a1c
```

## Find the session's window

```bash
lats focus tideline-3f9a1c
```

`lats focus` raises the terminal window that carries the session tag and
switches to its Space when needed. Use `lats search tideline --deep` when
you do not know the session name; see
[Finding windows](/lattices/docs/guide-search).

The command bar (Control+Option+Space) lists every project that has a
`.lattices.json`. The app scans `~/dev`, `~/Developer`, `~/projects` and
`~/src` three levels deep for those files.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error, such as missing arguments or a bad config |
| 2 | Session not found |

## Related

- [Configuration](/lattices/docs/config): the full `.lattices.json` and CLI
  reference.
- [Layers](/lattices/docs/guide-layers): group a session's terminal with its
  editor and browser.
- [Concepts](/lattices/docs/concepts#session-naming): how naming and window
  discovery work underneath.
