---
title: Getting started
description: Install Lattices, tile a window, find a window, and start a project session in your first ten minutes
order: 0.4
---

After this page you can tile a window with a key, find and place a window
from a terminal, and start a terminal session for a project. Each step says
what to expect and what to do if it does not happen.

Requirements: a Mac on macOS 26 or later and [Bun](https://bun.sh). tmux is
needed only for step 6.

The examples use an invented project, `tideline`, checked out at
`~/dev/tideline`. Substitute your own project.

## 1. Install the app and the CLI

Install the app with Homebrew:

```bash
brew tap arach/tap
brew trust arach/tap
brew install --cask arach/tap/lattices
```

Or download the disk image from the
[latest release](https://github.com/lattices-dev/lattices/releases/latest)
and drag `Lattices.app` to `/Applications`.

Install the CLI:

```bash
bun install -g @lattices/lattices
```

`npm install -g @lattices/lattices` also works. The CLI still needs Bun at
runtime.

Check:

```bash
lats help
```

Expected: the command reference prints. If the shell reports `command not
found`, add Bun's global bin directory to `PATH` and open a new shell.

## 2. Launch the app

```bash
lats app
```

Expected: a Lattices icon appears in the menu bar and macOS asks for
Accessibility access. Grant it in System Settings > Privacy & Security >
Accessibility. Lattices moves windows through the Accessibility API, so
nothing tiles until this permission is on.

Check that the CLI can reach the app:

```bash
lats daemon status
```

Expected: a status line with the daemon's version. If the CLI prints `Daemon
not running`, the app is not running or has not finished starting. Run
`lats app` again and retry.

Start the app at login, if you want it:

```bash
lats app install
```

## 3. Tile a window with a key

1. Click any window to bring it to the front.
2. Press Control+Option+Right.

Expected: the window fills the right half of its display, below the menu bar
and above the Dock. Control+Option+Left, Up and Down place the other halves.

If nothing moves, open System Settings > Privacy & Security > Accessibility
and confirm Lattices is listed and on. Then try again.

## 4. Open the command bar

Press Control+Option+Space.

Expected: the command bar opens. Type part of a window title, an app name or
a project name. Press Return to go to the top result. Press Escape to close
the bar.

The command bar is the fastest way to reach a window on another Space or
display. It also lists projects, layers and app commands.

## 5. Find and place a window from the terminal

Search for a window by any word in its title or app name:

```bash
lats search chrome
```

Expected: a ranked list of matching windows with their window ids. If the
output is `No results for "chrome"`, try a word from a window title you can
see.

Find the top match and tile it in one step:

```bash
lats place chrome left
```

Expected: the best-matching Chrome window comes to the front and fills the
left half. Without a position, `lats place` uses `bottom-right`.

`lats tile <position>` moves the front window without a search:

```bash
lats tile right
lats tile top-left
lats tile maximize
```

[Tiling and placement](/lattices/docs/guide-tiling) lists every position.

## 6. Start a session for a project

This step needs tmux:

```bash
brew install tmux
```

Write a config for the project and start it:

```bash
cd ~/dev/tideline
lats init
lats start
```

Expected: `lats init` prints `Created .lattices.json` and the config it
wrote. For a project with a `dev` script in `package.json`, the config has two
panes: a shell on the left at 60% width and the dev server on the right.
`lats start` attaches your terminal to a tmux session named
`tideline-<hash>`, where `<hash>` comes from the directory path.

Detach with Ctrl+B then D. Run `lats start` again from the same directory to
reattach. The dev server keeps running in between.

If `lats init` prints `.lattices.json already exists.`, the project already
has a config. `lats start` uses it.

[Sessions](/lattices/docs/guide-sessions) explains the config file and the
session lifecycle.

## 7. Turn on screen-text search (optional)

With screen-text search on, `lats search` and the command bar also match
words that are visible inside windows, such as an error message in a
terminal.

1. Open System Settings > Privacy & Security > Screen Recording and turn
   Lattices on.
2. Open Lattices Settings from the menu bar and turn on **Search & OCR**.

Expected: within about a minute, `lats scan` prints text from the visible
windows. [Finding windows](/lattices/docs/guide-search) covers the search
tiers.

## Where to go next

- [Tiling and placement](/lattices/docs/guide-tiling)
- [Finding windows](/lattices/docs/guide-search)
- [Sessions](/lattices/docs/guide-sessions)
- [Layers](/lattices/docs/guide-layers)
- [Lattices for AI agents](/lattices/docs/guide-agents)
- [Menu bar app](/lattices/docs/app) for every shortcut and setting
