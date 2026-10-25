---
title: Lattices for AI agents
description: Give Claude Code, Codex or any agent the desktop through skills, the lats CLI, the MCP server and the daemon API
order: 1.6
---

An agent drives Lattices through the same model you do: windows, sessions,
layers and screen text. This page sets up each surface, in the order most
people need them, and states the rules an agent should follow before it
moves anything.

Everything here needs the menu bar app running. Agents on another machine
go through the gateway; see
[Working across machines](/lattices/docs/guide-machines).

## Pick a surface

| Surface | Use it when | Setup |
|---------|-------------|-------|
| Skills | The agent runs in a harness that loads skills, such as Claude Code | `npx skills add lattices-dev/lattices --all --global --yes` |
| CLI | The agent has a shell. Covers most tasks. | `lats` on `PATH` |
| MCP | The harness speaks MCP and you want window, layer, browser or remote-host tools | `lats mcp` registered as a server |
| Daemon API | A script or a typed client needs receipts and events | `lats call`, or `daemonCall` from `@lattices/lattices` |

Prefer the CLI. Use `lats call` when no dedicated command exists. Use the
Node client only in scripts.

## 1. Install the skills

```bash
npx skills add lattices-dev/lattices --list
npx skills add lattices-dev/lattices --all --global --yes
```

The catalog has four skills. `lattices` covers tiling, sessions, search and
layers. `action`, `voice` and `blink` belong to the other products and work
only when those apps are installed. Install one at a time with
`--skill lattices`.

Each skill tells the agent which commands to run and when to stop. The
`lattices` skill starts with `lats daemon status` and refuses to invent
window ids, session names or layer names.

## 2. First checks from the CLI

Before any mutation, read the desktop:

```bash
lats daemon status           # is the app up and which version
lats doctor                  # permissions, capabilities, events
lats windows --json          # every visible window with its wid
lats map --json              # the same, per display, with coordinates
lats call desktop.snapshot   # the current Space, with window ids
lats call api.schema         # every daemon method and its parameters
```

Expected: `lats daemon status` prints a version. If it prints `Daemon not
running`, tell the user to run `lats app`. Do not try to start the app from
an agent without asking.

Then act with the commands from the other guides:

```bash
lats search tideline --deep --json
lats place tideline left --dry-run --json
lats window place 4182 right
lats layer tideline --launch
lats call windows.place '{"wid":4182,"placement":"left","dryRun":true}'
```

`--dry-run` and `dryRun` return the plan without moving a window. Every
mutating call returns a receipt that names the window it moved and the frame
it ended in.

## 3. Register the MCP server

The `lattices` package ships one MCP server. Agent config names the binary,
never a path:

```json
{ "mcpServers": { "lattices": { "command": "lattices", "args": ["mcp"] } } }
```

Print the snippet for a harness:

```bash
lats mcp --print-config claude
lats mcp --print-config codex
lats mcp --print-config kimi
```

For Claude Code:

```bash
claude mcp add lattices -s user -- lattices mcp
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.lattices]
command = "lattices"
args = ["mcp"]
```

Check what the server offers without starting a session:

```bash
lats mcp --list
```

The server has three toolsets:

| Toolset | Tools | Does the work |
|---------|-------|---------------|
| `windows` | `windows_search`, `windows_place`, `windows_focus`, `layers_list`, `layers_switch`, `history_undo` | The Lattices daemon on this Mac |
| `browser` | `browser_open`, `browser_tabs`, `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot`, `browser_console`, `browser_close`, `browser_profiles`, `browser_use_profile`, `browser_profile_info`, `browser_import_cookies`, `browser_companion_status` | Action Browser code in the package, driving a Chrome that Action owns |
| `hosts` | `hosts_list`, `host_describe`, `host_windows`, `host_screenshot`, `host_read`, `host_place`, `host_focus`, `host_act`, `host_call` | The Lattices daemon here, or a paired host |

Serve a subset with `lats mcp --toolsets browser`. In the harness, `/mcp`
should list `lattices` as connected.

Window search, placement, focus, layers and undo are MCP tools in the
`windows` toolset. Search with `windows_search` first and set `deep: true`
only when it misses. `windows_place` returns a `receiptId`; `history_undo`
with that id puts the window back. Sessions are not MCP tools yet; use the
CLI or the daemon API. Action.app has its own MCP server for
native observe and act, started with `lats action mcp`; it is separate from
`lats mcp`.

## 4. Call the daemon directly

The daemon listens on a Unix socket, `~/.lattices/run/lattices.sock`, and
requires the token stored beside it in `lattices.token`. `lats call` and the
Node client find both for you:

```bash
lats call windows.list '{}'
lats call layers.switch '{"name":"tideline"}'
```

```js
import { daemonCall, isDaemonRunning } from '@lattices/lattices'

if (await isDaemonRunning()) {
  const windows = await daemonCall('windows.list', {})
  await daemonCall('windows.place', { wid: windows[0].wid, placement: 'left' })
}
```

A raw WebSocket client must read the token file, connect to the socket,
send `Host: localhost` and the `x-lattices-token` header on the upgrade. The
socket accepts only this user. There is no TCP port unless you set
`LATTICES_ALLOW_LOOPBACK_TCP=1`, and the token is still required then.

Methods follow `<domain>.<verb>`: `windows.search`, `windows.place`,
`sessions.launch`, `layers.switch`, `ocr.snapshot`, `terminals.search`,
`capture.screenshotWindow`. `lats call api.schema` lists them all with
parameters. [Agent API](/lattices/docs/api) is the written reference.

## Rules for a well-behaved agent

- Read before you move. Take a snapshot, resolve the target, then place.
- Target by `wid` or session name. Never guess an id.
- Use `dryRun` when the target is ambiguous.
- Move one window at a time unless the user asked for a layout.
- Do not switch layers or Spaces to look around. Use `lats windows --json`
  and `lats map --json`, which read without moving.
- Screenshots are audited. Each `lats capture` and every `capture.*` call
  draws a short outline on screen and appends a line to
  `~/.lattices/audit/captures.jsonl`. The CLI names Claude Code, Codex,
  opencode and Cursor from their environment. Set `LATTICES_AGENT` to name
  any other agent.

## Related

- [Agent guide](/lattices/docs/agents): the canonical action contracts and
  receipts.
- [MCP](/lattices/docs/mcp): why the server is a subcommand, and how the
  toolsets are built.
- [Finding windows](/lattices/docs/guide-search) and
  [Tiling and placement](/lattices/docs/guide-tiling): the commands an
  agent runs most.
