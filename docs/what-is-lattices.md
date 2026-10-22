---
title: What Lattices is
description: A plain-language introduction to Lattices for someone who has never used it
order: 0.1
---

Lattices is a workspace manager for macOS. It keeps a live model of your
windows, desktops and terminal sessions, and it lets you act on that model
with keyboard shortcuts, the `lats` command, or an API that AI agents can
call.

This page explains what Lattices does, what you install, and which parts are
optional. [Getting started](/lattices/docs/getting-started) walks through the
first ten minutes.

## Three jobs

Lattices does three things. Each one works on its own.

**Place windows.** Press Control+Option+Right and the front window fills the
right half of the screen. Run `lats tile left` for the same result from a
terminal. Agents call `windows.place` on the daemon. All three routes move
the same window through the same code. See
[Tiling and placement](/lattices/docs/guide-tiling).

**Keep project context.** A project can declare its terminal layout in a
`.lattices.json` file, and `lats start` builds that layout as a tmux session.
A workspace layer groups the windows of one piece of work and switches them
in and out as a set. See [Sessions](/lattices/docs/guide-sessions) and
[Layers](/lattices/docs/guide-layers).

**Make the desktop searchable.** `lats search` finds windows by title, app,
session or the text on screen. `lats place` finds a window and tiles it in one
step. See [Finding windows](/lattices/docs/guide-search).

## Who it is for

- Developers who work on several projects at once and rebuild the same
  window layout every day.
- People who run AI agents such as Claude Code or Codex and want those
  agents to see and arrange the desktop.
- People with more than one Mac, or a Mac and a Linux box, who want one
  keyboard to reach all of them.

## What you install

| Part | What it is | Required |
|------|------------|----------|
| Menu bar app | `Lattices.app`. Hosts the daemon, the shortcuts and the command bar. | Yes |
| CLI | `lats`, installed from the `@lattices/lattices` npm package. Bun runs it. | For terminal and agent use |
| tmux | Terminal multiplexer. `lats start` needs it. | Only for sessions |
| Screen Recording permission | Lets the app read window text for search. | Only for screen-text search |
| Gateway | A separate process for remote access over Tailscale. | Only for other machines |

The app runs without the CLI. The CLI runs most commands only while the app
is running, because the app hosts the daemon. See
[Getting started](/lattices/docs/getting-started) for the install steps.

## Words you will see

| Term | Meaning |
|------|---------|
| Window | One macOS window. Lattices identifies it by a window id, written `wid`. |
| Placement | A named screen position such as `left`, `top-right` or `2x2:1,1`. |
| Session | A tmux session that Lattices created for one project directory. |
| Layer | A named set of windows that Lattices shows together and puts away together. |
| Space | A macOS desktop. Lattices can switch Spaces to reach a window. |
| Daemon | The API server inside the menu bar app. The CLI and agents talk to it. |
| Host | Another machine that runs Lattices and accepts commands or visits. |
| Visit | Lending this Mac's mouse and keyboard to a host by pushing the pointer past a screen edge. |

[Concepts](/lattices/docs/concepts) has the full glossary and the process map.

## Related products

Lattices shares a repository, a website and a skills catalog with three
other products. Each one is a separate app with its own install and its own
docs. Lattices does not need any of them.

| Product | What it adds | Reached from `lats` as |
|---------|--------------|------------------------|
| [Action](/action/docs/overview) | Native computer use for agents: observe, click, type, record | `lats action` |
| [Canvas](/canvas/docs/overview) | Notes that float on the desktop | `lats canvas` |
| [Speech](/speech/docs/overview) | Spoken output from agents and scripts | `lats voice say` |

## Platforms

Lattices on macOS requires macOS 26 or later. Lattices on Linux runs on
Hyprland and installs from source; see
[Install on Linux](/lattices/docs/install-linux). This guide and the other
guides describe the macOS app unless they say otherwise.

## Next

- [Getting started](/lattices/docs/getting-started): install, launch, tile,
  search and place in ten minutes.
- [Lattices for AI agents](/lattices/docs/guide-agents): skills, MCP and
  the daemon API.
