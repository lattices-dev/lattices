---
title: Overview
description: What Lattices owns in the product family, what ships with it, and where to start
order: 0
---

Lattices is an agentic window manager. On macOS it is a menu bar app, the
`lats` CLI and a local agent API. On Linux it is a Bun host, a Quickshell
desktop app and the same CLI. Lattices gives people and agents one
programmable model of the desktop: windows, spaces, workspace layers, tmux
sessions and the text on screen.

New here? Read [What Lattices is](/lattices/docs/what-is-lattices), then
[Getting started](/lattices/docs/getting-started).

## Lattices in the family

Lattices, Action, Canvas and Speech share this website, repository and skills
catalog. Each product ships its own app and keeps its own lifecycle.

| Product | Use it for | Docs |
|---------|-----------|------|
| **Lattices** | Window management, tiling, workspace layers, tmux sessions, screen text, voice commands | You are here |
| **Action** | Native computer use: observe, resolve, act and record, including private agent layers | [Action docs](/action/docs/overview) |
| **Canvas** | Spatial notes that float on the desktop | [Canvas docs](/canvas/docs/overview) |
| **Speech** | Spoken output from agents and scripts | [Speech docs](/speech/docs/overview) |

Some `lats` commands reach another product. For example, `lats action`
installs and calls Action, and `lats voice say` forwards speech to the Speech
app. [Concepts](/lattices/docs/concepts) shows each process, its local socket or network endpoint, and
where every command goes. The [product map](/products) compares the products.

## What's included

Screen-text indexing is off by default. It starts only after you grant
Screen Recording permission and turn on **Search & OCR** in Settings; see
[Screen scanning](/lattices/docs/ocr) for the scan intervals.

| Component | Platform | Description |
|-----------|----------|-------------|
| **CLI** | macOS, Linux | The `lats` command. Tile windows, manage sessions, scan screen text, control the workspace from your terminal |
| **Menu bar app** | macOS | Command bar, window tiling, project discovery, screen text indexing, voice commands |
| **Linux host and app** | Linux (Hyprland) | `lattices-host` serves the agent API; a Quickshell app and a tray menu sit on top of it |
| **Agent API** | macOS, Linux | Authenticated WebSocket on `lattices.sock` in 0.15.1. RPC methods and real-time events; see [Concepts](/lattices/docs/concepts#private-ipc-and-the-gateway) |
| **MCP server** | macOS | `lats mcp` serves window, browser and remote-host tools to agent harnesses. See [MCP](/lattices/docs/mcp) |
| **Screen scanner** | macOS | When enabled, reads text from visible windows with the Accessibility API and Apple Vision OCR and indexes it with FTS5 |
| **Node.js client** | macOS, Linux | Zero-dependency `daemonCall()` helper for scripting |
| **Embedded SDK** | macOS | Swift package for embedding Lattices capabilities into host apps or product-owned helpers |

## Requirements

macOS:

- macOS 26.0+
- Node.js 18+ or Bun for the CLI
- tmux for persistent terminal sessions (`brew install tmux`), optional
- Swift 6.2 / Xcode 26+, only to build the menu bar app from source

Linux:

- Hyprland with a systemd user session; Omarchy on Arch Linux is the
  supported automatic setup
- See [Install on Linux](/lattices/docs/install-linux) for the full list

## Where to go

Start here:

- [What Lattices is](/lattices/docs/what-is-lattices): the three jobs, what you install, and the words you will see
- [Quickstart](/lattices/docs/quickstart): install the app and the CLI
- [Getting started](/lattices/docs/getting-started): tile, find, place, and start a session in ten minutes
- [Install on Linux](/lattices/docs/install-linux): the Hyprland host, app and CLI

Guides:

- [Tiling and placement](/lattices/docs/guide-tiling)
- [Finding windows](/lattices/docs/guide-search)
- [Sessions](/lattices/docs/guide-sessions)
- [Layers](/lattices/docs/guide-layers)
- [Working across machines](/lattices/docs/guide-machines)
- [Lattices for AI agents](/lattices/docs/guide-agents)

Reference:

- [Concepts](/lattices/docs/concepts): product boundary, processes, sockets and glossary
- [Configuration](/lattices/docs/config): `.lattices.json` format and CLI commands
- [Menu bar app](/lattices/docs/app): every shortcut and setting
- [Screen scanning](/lattices/docs/ocr): AX text extraction, Vision OCR and full-text search
- [Voice](/lattices/docs/voice): voice commands and the `lats voice` reference
- [Agent guide](/lattices/docs/agents): canonical action contracts for voice, CLI and daemon clients
- [Agent API](/lattices/docs/api): RPC method reference for agents and scripts
- [MCP](/lattices/docs/mcp): the `lats mcp` server and its toolsets
- [Workspace map](/lattices/docs/workspace-map): read-only terminal/JSON desktop snapshots and visible-surface hygiene
- [Embedded SDK](/lattices/docs/embedded-sdk): host-owned helper model for Scout, HudsonKit and other embeddings
