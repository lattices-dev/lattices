---
title: Overview
description: What Lattices is, what it owns in the product family, and where to start
order: 0
---

Lattices is an agentic window manager. On macOS it is a menu bar app, the
`lats` CLI and a local agent API. On Linux it is a Bun host, a Quickshell
desktop app and the same CLI. Lattices gives people and agents one
programmable model of the desktop: windows, spaces, workspace layers, tmux
sessions and the text on screen.

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

## The problem

I kept losing track of windows. Terminal here, dev server there, browser
somewhere on the second monitor, three other projects buried under it all.
Every morning I'd rebuild the same layout. Half my context-switching was
just hunting for the right window.

AI agents have it worse. They're stuck inside a single shell with no way
to see what's on screen, arrange windows, or jump between projects.

## The solution

Lattices provides workspace controls, window layouts and persistent terminal
sessions:

### Programmable workspace

The CLI and agent API expose everything: query what's on screen, search
window text, tile layouts, manage sessions. Install the family skills with
`npx skills add lattices-dev/lattices --all --global --yes` (`lattices`,
`action`, `voice`, `blink`). Claude Code skills, MCP servers, or your own
scripts can drive your desktop the same way you do. Your workspace becomes
infrastructure you can observe and control programmatically.

### Smart layout manager

A native menu bar app tracks every window across all your monitors. Tile
with hotkeys, organize into switchable layers, snap to grids. It reads
your windows too. It extracts text from UI elements every 60 seconds and
runs Vision OCR on background windows every 2 hours. Everything is
searchable.

### Managed tmux sessions

We make tmux easy. Declare your dev environment in a `.lattices.json`:
which panes, which commands, what layout. lattices builds it, runs it,
and keeps it alive. Use your own terminal. Sessions survive terminal
crashes and disconnects, and you can reattach anytime.

## What's included

| Component | Platform | Description |
|-----------|----------|-------------|
| **CLI** | macOS, Linux | The `lats` command. Tile windows, manage sessions, scan screen text, control the workspace from your terminal |
| **Menu bar app** | macOS | Command palette, window tiling, project discovery, screen text indexing, voice commands |
| **Linux host and app** | Linux (Hyprland) | `lattices-host` serves the agent API; a Quickshell app and a tray menu sit on top of it |
| **Agent API** | macOS, Linux | Authenticated WebSocket on `lattices.sock` in 0.15.1. RPC methods and real-time events; see [Concepts](/lattices/docs/concepts#private-ipc-and-the-gateway) |
| **MCP server** | macOS | `lats mcp` serves the `browser_*` and `host_*` tools to agent harnesses. See [MCP](/lattices/docs/mcp) |
| **Screen scanner** | macOS | Reads text from visible windows using the Accessibility API (60s) and Apple Vision OCR (2h), indexes with FTS5 |
| **Node.js client** | macOS, Linux | Zero-dependency `daemonCall()` helper for scripting |
| **Embedded SDK** | macOS | Swift package for embedding Lattices capabilities into host apps or product-owned helpers |

## Example

```bash
cd ~/my-project && lats start
```

Agents get the same control programmatically:

```js
import { daemonCall } from '@lattices/lattices'
await daemonCall('sessions.launch', { path: '/Users/you/dev/frontend' })
await daemonCall('windows.place', {
  session: 'frontend-a1b2c3',
  placement: { kind: 'tile', value: 'left' }
})
```

## Who it's for

- Developers who juggle multiple projects and want faster window management
- People building AI agents that need to observe and control the desktop
- Power users who work across multiple macOS Spaces
- Anyone who wants persistent, auto-configured terminal sessions

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

## Next steps

- [Quickstart](/lattices/docs/quickstart): install and run your first session
- [Install on Linux](/lattices/docs/install-linux): the Hyprland host, app and CLI
- [Concepts](/lattices/docs/concepts): product boundary, processes, ports and glossary
- [Configuration](/lattices/docs/config): `.lattices.json` format and CLI commands
- [Screen scanning](/lattices/docs/ocr): AX text extraction, Vision OCR and full-text search
- [Voice](/lattices/docs/voice): voice commands and the `lats voice` reference
- [Agent guide](/lattices/docs/agents): canonical action contracts for voice, CLI and daemon clients
- [Agent API](/lattices/docs/api): RPC method reference for agents and scripts
- [MCP](/lattices/docs/mcp): the `lats mcp` server and its toolsets
- [Workspace map](/lattices/docs/workspace-map): read-only terminal/JSON desktop snapshots and visible-surface hygiene
- [Embedded SDK](/lattices/docs/embedded-sdk): host-owned helper model for Scout, HudsonKit and other embeddings
