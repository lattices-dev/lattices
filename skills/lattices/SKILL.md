---
name: lattices
description: Drive a macOS developer workspace through Lattices. Use when tiling or placing windows, launching tmux sessions, searching screen text or OCR, switching workspace layers, focusing apps, or calling the local Lattices daemon API.
compatibility: Requires macOS with the Lattices menu bar app running (ws://127.0.0.1:9399).
metadata:
  author: arach
  homepage: https://lattices.dev
---

# Lattices

Lattices is a macOS workspace manager. The menu bar app hosts a local daemon at
`ws://127.0.0.1:9399`. Agents drive it with the `lats` CLI. Older installs only
have the long name: if `lats` is not found, run the same command as `lattices`.

When this skill is invoked, run the command. Summarize the result. Do not
narrate the plan first. Spoken commands belong to the `speech` skill. Native
clicks, capture, and Action-owned Chrome belong to the `action` skill.

## Prerequisite

The daemon must be running:

```bash
lats daemon status
```

If that fails, start the app with `lats app` and retry. Do not invent
window IDs, session names, or layer names. Read them from the CLI first.

## Choose a surface

Prefer the CLI. Use `lats call` only when no dedicated command exists.
Use `daemonCall` from `@lattices/lattices` only in scripts.

| Need | Command |
| --- | --- |
| What is in front of the user | `lats call desktop.snapshot` |
| ASCII map of the current space | `lats map` |
| Find a window | `lats search <query> --deep` |
| Place a window | `lats place <query> <position>` |
| Tile the frontmost window | `lats tile <position>` |
| Launch or attach this repo | `lats start` |
| Screen text | `lats scan` |
| Search screen text | `lats scan search "<query>"` |
| Switch a layer | `lats layer <name-or-slot>` (slots 1-4, 6-9 as ⌘⌥ takes them) |
| Say something out loud | `lats voice say "<text>"` (`voice stop` stops speaking) |
| Raw RPC | `lats call <method> '<json>'` |
| Method catalog | `lats call api.schema` |

`--deep` and `--all` both request every search source (index plus live
terminal inspection). Use them when the project name appears in cwd or tab
data rather than the window title.

## Canonical mutations

Use these methods. Methods are named `<domain>.<verb>` (LAT-012); the old
singular names (`window.place`, `session.launch`, `tmux.sessions`) still work as
aliases, and `lats call api.schema` lists them under `aliases`.

| Method | Use for |
| --- | --- |
| `windows.place` | Place a window or session with a typed placement |
| `layers.activate` | Switch layers as ⌘⌥ does; `mode: "launch"` starts what isn't running |
| `spaces.optimize` | Rebalance windows with an explicit scope and strategy |

`layers.switch` is `layers.activate`. `layout.distribute` is `spaces.optimize` with
`scope=visible` and `strategy=balanced`.

Resolve before mutating when the target identity matters:

```bash
lats call windows.resolve '{"target":{"kind":"session","session":"frontend-a1b2c3"},"placement":"left"}'
lats call actions.execute '{"type":"window.place","target":{"kind":"session","session":"frontend-a1b2c3"},"args":{"placement":"left"},"dryRun":true}'
```

Action receipts keep their `window.place` type. Undo the latest undoable placement with
`lats call history.undo '{}'`.

## Recipes

### Place a project window

```bash
lats search frontend --deep
lats place frontend left
```

Default place position is `bottom-right`. Positions include `left`, `right`,
`top`, `bottom`, `maximize`, `center`, and the four corners.

### Launch two sessions and tile them

```bash
lats call sessions.launch '{"path":"/Users/you/dev/frontend"}'
lats call sessions.launch '{"path":"/Users/you/dev/api"}'
lats call tmux.list
lats call windows.place '{"session":"frontend-a1b2c3","placement":"left"}'
lats call windows.place '{"session":"api-b4c5d6","placement":"right"}'
```

Session names are `<basename>-<sha256-6chars>`. Read the live name from
`lats sessions --json` or `tmux.list`. Do not guess the hash.

### Read the screen

```bash
lats scan
lats scan --full
lats scan search "error"
lats scan recent 10
lats scan deep
```

`scan` is accessibility text. `scan deep` triggers Vision OCR, then read the
fresh snapshot. Results are tagged `AX` or `OCR`. Each window has a `wid` for
`lats scan history <wid>`.

### Switch a layer

```bash
lats layer
lats layer 1
lats layer web
```

## Scripts

From Node:

```js
import { daemonCall, isDaemonRunning } from '@lattices/lattices'

if (!(await isDaemonRunning())) {
  throw new Error('Lattices daemon is not running. Start it with: lats app')
}

const windows = await daemonCall('windows.list')
```

`scripts/connect.js` prints daemon health, running projects, and session
layers. Run it with `node scripts/connect.js` from this skill directory when
the CLI package is installed.

## Live docs

Do not copy the full RPC catalog into context. Read it when needed:

1. `lats call api.schema`
2. https://lattices.dev/docs/agents
3. https://lattices.dev/docs/api
4. https://lattices.dev/docs/workspace-map
