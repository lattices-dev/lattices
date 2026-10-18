---
title: Quickstart
description: Install lattices and launch your first workspace in 2 minutes
order: 0.5
---

Requires macOS 26 or later. Install the [Mac app](https://github.com/lattices-dev/lattices/releases/latest) for window management, or follow these steps to add the CLI and optional terminal sessions.

For Hyprland and Omarchy, use [Install on Linux](/docs/install-linux).

## 1. Install lattices

Install [Bun](https://bun.sh) first. The CLI needs Bun at runtime, including when installed with npm.

```bash
npm install -g @lattices/lattices
```

This installs the CLI as `lats`, with `lattices` as a long-form alias.

Verify: `lats help` should print usage info.

### One-command setup

For a new Mac, the setup script installs Homebrew when needed, tmux, Bun,
and the CLI. Review the [installer source](https://github.com/lattices-dev/lattices/blob/main/scripts/install.sh) before running:

```bash
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
```

You can also install the Mac app with Homebrew:

```bash
brew tap arach/tap
brew trust arach/tap
brew install --cask arach/tap/lattices
```

The cask requires Apple Silicon and macOS 26 or later. It installs the app;
the optional CLI is available with `bun install -g @lattices/lattices`.
You can also download the [disk image](https://github.com/lattices-dev/lattices/releases/latest).

## 2. Launch the menu bar app

```bash
lats app
```

This launches the bundled Mac app. Grant Accessibility access when prompted. For screen-text search, grant Screen Recording permission and enable **Search & OCR** in Settings.
Open the command palette with **Control+Option+Space** to search and launch
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
