---
title: Install on Linux
description: Install the Lattices app, CLI and desktop services on Hyprland, with optional Omarchy mouse gestures.
order: 0.6
---

Lattices on Linux includes a desktop app, the `lats` CLI, a local host and a tray menu. The installer copies a runtime into your user account. You can remove the source checkout after installation.

## Requirements

Use a Linux machine with **Hyprland** and a systemd user session. **Omarchy on Arch Linux** is the supported automatic setup. The installer supports x86-64 and ARM64.

Run the installer from a terminal inside your Hyprland desktop. Do not run the installer with `sudo`. It uses `sudo` only when Arch packages are missing.

Bun runs the app and CLI. Quickshell provides the desktop window and gesture trail. The installer also checks tmux, Python, grim, wtype, ffmpeg and tesseract. Other distributions must provide those commands before using `--no-deps`.

Tailscale is optional for local use. Set up Tailscale separately to pair with another machine. Version 0.15.0 uses authenticated private IPC locally and a separate gateway for remote access. See [Private IPC and the gateway](/lattices/docs/concepts#private-ipc-and-the-gateway) before enabling remote access.

## Install

Run:

```sh
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
```

The installer installs missing Arch dependencies and Bun, copies the Linux runtime, adds `lats`, `lattices` and `lattices-host`, and creates the app launcher. It then enables the host and tray as systemd user services, runs `lats doctor`, and opens the app.

The host and tray start at login. The app window opens when you select Lattices in the Apps menu or run `lats app`.

If the installer cannot reach the desktop or the user service manager, it reports the failure. Use `--no-start` when preparing the installation outside the graphical session.

### Install from a checkout

```sh
git clone https://github.com/lattices-dev/lattices.git
cd lattices
bash install.sh
```

If Bun and the system dependencies are already available, you can run `bun run linux:install` from the repository root.

### Inspect the plan

```sh
bash install.sh --dry-run
```

Dry-run mode does not download packages, write files or start services.

## Optional Omarchy gestures

The core install leaves desktop bindings unchanged. Add Forward-button gestures with:

```sh
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash -s -- --gestures
```

Hold the Forward button, draw the gesture, then release:

| Gesture | Action |
| --- | --- |
| Left | Previous existing space |
| Right | Next existing space |
| Down | Show or hide the Lattices overlay |
| Down, then left | Send Enter to the window where the gesture started |
| Up | Send the Fab recording toggle, when Fab is installed |

A straight gesture needs 80 logical pixels. The Enter gesture needs about 80 pixels down followed by 80 pixels left. The pen trail shows the selected action. Incomplete Enter gestures cancel after the left turn is detected.

This option reserves the Forward button for gestures. Back and ordinary wheel-click keep their existing behavior.

For a mouse without a Forward button, enable wheel-click gestures explicitly:

```sh
bash install.sh --wheel-gestures
```

`--wheel-gestures` includes Forward-button support and reserves plain wheel-click for gestures. Middle-click paste and middle-click opening of links are unavailable while that binding is enabled.

**Super+Ctrl+G** opens a 15-second button tester. It draws the trail without running actions. **Escape** exits the tester or cancels a held gesture.

The recording gesture uses a separately installed Fab CLI. This installer does not install Fab or Scout.

The installer backs up changed files, adds one managed include to `~/.config/hypr/bindings.lua`, and enables the `lattices.gestures` plugin in Omarchy's `shell.json`. Other bindings and plugins are preserved. A Hyprland configuration error restores the previous files.

## Verify the installation

Run:

```sh
lats help
lats doctor
systemctl --user status lattices-host lattices-tray
lats app
```

Doctor checks the host connection, window inventory, window placement, spaces, tmux and desktop events. A pass confirms the desktop API is available. It does not send input or move a window.

If `lats` is not on PATH, open a new terminal or run:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The Apps launcher and services use absolute paths and can run before that PATH change.

## Prepare an installation over SSH

Install files without starting the desktop components:

```sh
bash install.sh --no-start
```

When you return to a terminal inside Hyprland, activate and verify them with:

```sh
~/.local/bin/lats app install
```

The installer keeps an installed gesture profile when you rerun it without gesture flags. To switch from wheel-click gestures to Forward-button gestures only, rerun with `--gestures`.

## Update

Run the one-command installer again. It downloads one source revision and copies a new runtime before switching the installed commands. Successful activation closes the previous managed app window, restarts the host and tray, and opens the updated app.

Older runtime directories remain available for recovery. They are stored under `~/.local/share/lattices/linux-runtime/releases/`.

If an older or manual installation owns a target file, the installer lists the conflict and stops before changing it. Review the listed paths. If migrating from a source checkout, close its Lattices app before replacing the launcher. To migrate the files with backups, use:

```sh
bash install.sh --replace-existing
```

The same flag is available through `lats app install`. It also permits replacing a managed file that you edited. Backups are stored under `~/.local/state/lattices/install-backups/`.

## Troubleshooting

**The compositor socket is unavailable.** Run the installer from a terminal inside the current Hyprland session. A terminal opened before a compositor restart can retain an old `HYPRLAND_INSTANCE_SIGNATURE`. Use a new terminal. Use `--no-start` to install files without desktop access.

**The host or tray did not start.** Inspect the service logs:

```sh
journalctl --user -u lattices-host -u lattices-tray -n 60
```

The files remain installed if activation fails. Resolve the reported service or desktop error, then rerun `lats app install`.

**Gesture configuration failed.** The installer restores the files it changed if Hyprland reports a configuration error. Check `hyprctl configerrors`. Core installation works without gesture flags.

**A configuration file is a symlink.** Automatic gesture setup preserves symlinked configuration files and stops with the path to review. Manage the gesture include and plugin entry through your dotfiles, or install the core app without gestures.

**Another Linux distribution is in use.** Install the requirements through that distribution's package manager. Then run `bash install.sh --no-deps` from a checkout. Hyprland and Quickshell remain required. Gesture setup requires Omarchy's Lua configuration and Hyprland 0.56 or later.

## Installed files

| Location | Contents |
| --- | --- |
| `~/.local/bin/lats`, `lattices`, `lattices-host` | Command launchers |
| `~/.local/share/lattices/linux-runtime/` | Copied runtime releases, current link and installation receipt |
| `~/.local/share/applications/org.lattices.Lattices.desktop` | App launcher |
| `~/.config/systemd/user/lattices-host.service` | Local host service |
| `~/.config/systemd/user/lattices-tray.service` | Tray service |
| `~/.config/hypr/lattices-mouse.lua` | Optional gesture bindings |
| `~/.config/omarchy/plugins/lattices.gestures/` | Optional pen trail |
| `~/.local/state/lattices/install-backups/` | Replaced files and recovery copies |

The installer honors `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME`. Command launchers stay in `~/.local/bin`. Saved layers, pairings and captures in `~/.lattices` are kept separately from installed code.
