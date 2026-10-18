---
title: Overview
description: What lattices is and who it's for
order: 0
---

lattices is an agentic window manager for macOS. It provides a programmable
workspace, smart layout management, and managed tmux sessions — all
controllable from the CLI or a 35+-method agent API.

## The problem

I kept losing track of windows. Terminal here, dev server there, browser
somewhere on the second monitor, three other projects buried under it all.
Every morning I'd rebuild the same layout. Half my context-switching was
just hunting for the right window.

AI agents have it worse. They're stuck inside a single shell with no way
to see what's on screen, arrange windows, or jump between projects.

## The solution

lattices addresses both sides with three layers:

### Programmable workspace

The CLI and agent API expose everything: query what's on screen, search
window text, tile layouts, manage sessions. Install the family skills with
`npx skills add lattices-dev/lattices --all --global --yes` (`lattices`,
`action`, `speech`, `blink`). Claude Code skills, MCP servers, or your own
scripts can drive your desktop the same way you do. Your workspace becomes
infrastructure you can observe and control programmatically.

### Smart layout manager

A native menu bar app tracks every window across all your monitors. Tile
with hotkeys, organize into switchable layers, snap to grids. It reads
your windows too — extracting text from UI elements every 60 seconds and
running Vision OCR on background windows every 2 hours. Everything is
searchable.

### Managed tmux sessions

We make tmux easy. Declare your dev environment in a `.lattices.json`:
which panes, which commands, what layout. lattices builds it, runs it,
and keeps it alive. Use your own terminal — sessions survive reboots
and you can reattach anytime.

## What's included

| Component | Description |
|-----------|-------------|
| **CLI**     | The `lats` command. Tile windows, manage sessions, scan screen text, control the workspace from your terminal |
| **Menu bar app** | Native macOS companion. Command palette, window tiling, project discovery, screen text indexing |
| **Agent API** | WebSocket server on `ws://127.0.0.1:9399`. 35+ methods, 5 real-time events |
| **Screen scanner** | Reads text from visible windows using Accessibility API (60s) and Apple Vision OCR (2h), indexes with FTS5 |
| **Node.js client** | Zero-dependency `daemonCall()` helper for scripting |
| **Embedded SDK** | Swift package for embedding lattices capabilities into host apps or product-owned helpers |

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

- macOS 26.0+
- Node.js 18+

### Dev dependencies

- Swift 6.2 / Xcode 26+ — only to build the menu bar app from source
- tmux — needed for persistent terminal sessions (`brew install tmux`)

## Next steps

- [Quickstart](/docs/quickstart): install and run your first session in 2 minutes
- [Configuration](/docs/config): `.lattices.json` format and CLI commands
- [Screen scanning](/docs/ocr): AX text extraction, Vision OCR, and full-text search
- [Concepts](/docs/concepts): architecture, glossary, and how it all works
- [Agent Guide](/docs/agents): canonical action contracts for voice, CLI, and daemon clients
- [Agent API](/docs/api): RPC method reference for agents and scripts
- [Workspace Map](/docs/workspace-map): read-only terminal/JSON desktop snapshots and visible-surface hygiene
- [Embedded SDK](/docs/embedded-sdk): host-owned helper model for Scout, HudsonKit, and other embeddings
