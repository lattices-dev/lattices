---
title: Quickstart
description: Install lattices and launch your first workspace in 2 minutes
order: 0.5
---

Four steps to a running workspace on macOS. For Hyprland and Omarchy, use [Install on Linux](/docs/install-linux).

## 1. Install lattices

```bash
git clone https://github.com/arach/lattices
cd lattices && bun link
```

This installs the CLI as `lats`, with `lattices` as a long-form alias.

Verify: `lats help` should print usage info.

## 2. Launch the menu bar app

```bash
lats app
```

This builds (or downloads) and launches the native macOS companion.
Open the command palette with **Cmd+Shift+M** to search and launch
any project, tile windows, or switch workspace layers.

To also open Lattices automatically when you log in:

```bash
lats app install
```

## 3. Add a project config

Drop a `.lattices.json` in your project root:

```bash
cd ~/your-project
lats init
```

This generates a config like:

```json
{
  "panes": [
    { "name": "shell", "size": 60 },
    { "name": "server", "cmd": "bun dev" }
  ]
}
```

The menu bar app discovers projects with `.lattices.json` files
automatically — they show up in the command palette.

## 4. (Optional) Add tmux for persistent sessions

If you want terminal sessions that survive disconnects and auto-restore
your pane layout:

```bash
brew install tmux
cd ~/your-project
lats              # home screen: status only, does not attach
lats start        # create or reattach the session
```

This creates a tmux session with your configured panes side by side.
The session persists in the background — close your terminal, reopen it,
run `lats start` again, and everything is still there.

> **Without tmux**, you still get the menu bar app, command palette,
> window tiling, workspace layers, OCR, and the full agent API.

## What's next

- [Configuration](/docs/config): `.lattices.json` reference and CLI commands
- [Menu Bar App](/docs/app): command palette, tiling, and settings
- [Layers & Groups](/docs/layers): organize projects into switchable contexts
- [Screen OCR](/docs/ocr): let agents read what's on screen
- [Concepts](/docs/concepts): sessions, panes, and the architecture
- [Agent API](/docs/api): programmatic control for agents and scripts
