---
title: Quickstart
description: Install the Lattices app and the lats CLI on a Mac
order: 0.5
---

This page installs Lattices. After it, the menu bar app is running and
`lats` works in your terminal. [Getting started](/docs/getting-started) then
walks through tiling, finding windows, and starting a project session.

Requires macOS 26 or later on Apple Silicon. For Hyprland and Omarchy, use
[Install on Linux](/docs/install-linux).

## 1. Install the app

With Homebrew:

```bash
brew tap arach/tap
brew trust arach/tap
brew install --cask arach/tap/lattices
```

Or download the [disk image](https://github.com/lattices-dev/lattices/releases/latest)
and drag `Lattices.app` to `/Applications`.

## 2. Install the CLI

The CLI needs [Bun](https://bun.sh) at runtime, including when installed
with npm.

```bash
bun install -g @lattices/lattices
```

This installs `lats`, with `lattices` as a long-form alias.
`npm install -g @lattices/lattices` also works.

Check:

```bash
lats help
```

Expected: the command reference prints. If the shell reports `command not
found`, add Bun's global bin directory to `PATH` and open a new shell.

### One-command setup

On a new Mac, the setup script installs Homebrew when needed, tmux, Bun,
and the CLI. Review the [installer source](https://github.com/lattices-dev/lattices/blob/main/scripts/install.sh)
before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
```

## 3. Launch the app

```bash
lats app
```

Expected: the Lattices icon appears in the menu bar and macOS asks for
Accessibility access. Grant it; tiling and the command bar need it. When the
CLI finds no installed app, `lats app` builds one from source if Swift is
available, or downloads a release.

To open Lattices at login:

```bash
lats app install
```

## Next

Continue with [Getting started](/docs/getting-started): tile a window with
a key, open the command bar, find and place a window from the terminal, and
start a session for a project.
