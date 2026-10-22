---
title: Concepts
description: Action's processes, ports, command routes, sessions, leases, and capture lifecycle
order: 2
---

This page names the parts of Action and shows which process receives each
command.

## Runtime versions

The port numbers and connection behavior below describe published builds.
Matching development builds use private IPC: the Action agent listens on
`~/.lattices/run/action.sock`, and the runtime and `lats action call` supply
the connection token. Lattices core uses its own private socket. Remote access
goes through a separate, explicitly started gateway with approved method grants.
See [Private transport](/action/docs/api#private-connection) and
[Remote Linux setup](/action/docs/remote-engine) for those builds.

## Processes

| Process | Role | Address or entry point |
| --- | --- | --- |
| `Action.app` | AppKit lifecycle, launcher, menus, WebKit, permission UI. Also runs one-shot native host commands. | `/Applications/Action.app` |
| Action agent | Long-lived local RPC server for native requests and drive leases | `ws://127.0.0.1:4319` |
| Recording probe | A fresh `Action.app` instance in `recording-probe` mode that performs one ScreenCaptureKit capture | Launched per recording |
| Agent runtime | TypeScript sessions, observations, targets, actions, artifacts | `products/action/packages/runtime` |
| Action CLI | Product CLI over the runtime | `products/action/packages/cli/src/main.ts` |
| Action MCP | Stdio MCP server over the runtime | `products/action/packages/mcp/src/index.ts` |

`Action.app` starts the agent as a child process from
`Contents/Helpers/ActionAgent.app`. The helper has its own bundle id and runs
as a UI-less app, so macOS does not count it as a second `Action.app`
instance. The agent exits with its parent.

## Three native paths

The runtime reaches native code in three ways. Each path exists for a reason.

```text
runtime ──WebSocket──▶ Action agent (4319)       drive leases, capture methods, raw RPC
runtime ──open -n────▶ Action.app <command>     one-shot host commands with a JSON reply file
agent ────open -n────▶ Action.app recording-probe  one ScreenCaptureKit recording
```

- **Agent RPC.** Fast, persistent, connection-scoped. Drive leases live here
  because a lease must end when its connection closes.
- **Host commands.** `native/engine/scripts/run-app-host.sh` launches
  `Action.app` with a command such as `drape`, `raise-window`, `agent-layer`,
  `click-point`, or `blink-click`, and reads a JSON reply file. These commands
  carry the app bundle's permission identity, and some need AppKit windows.
  They are not agent WebSocket methods.
- **Recording probe.** ScreenCaptureKit recording is reliable only inside a
  real app lifecycle, so each recording gets its own app instance. See
  [Recording](/action/docs/recording).

## Command destinations

Several Lattices family commands look related to Action. Only some reach it.

| Command | Receiver | Notes |
| --- | --- | --- |
| `lats action install`, `update` | Lattices CLI | Downloads `Action.dmg` from the latest `action-v*` release to `/Applications` |
| `lats action launch`, `quit`, `status` | Lattices CLI and `Action.app` | Starts or stops the app. Prepared layer displays survive `quit`. |
| `lats action call <method>` | Action agent, port 4319 | Raw RPC. The CLI does not add credentials; privileged methods require `protocolVersion` and `authToken` parameters. |
| `lats action mcp` | Action MCP server (stdio) | Needs a runtime bundle, `ACTION_ROOT`, or a checkout |
| `lats action capabilities`, `layer …`, other verbs | Action CLI | Forwarded with `bun --cwd <action-root> action …`. Fails without a runtime or checkout. |
| `lats computer …` | Lattices core daemon, port 9399 | `computer.*` methods are implemented in Lattices core, not in Action |
| `lats mcp` (`browser_*` tools) | Lattices MCP server | Drives Action-owned Chrome profiles over CDP. It does not call Action.app. |
| Action MCP with `ACTION_REMOTE_HOST` | `lattices-host` on the remote machine, port 9399 | The Linux path uses the Lattices host protocol, not the Action agent |

The Lattices CLI finds an Action root in this order: `ACTION_ROOT`, the
`products/action` directory next to the CLI, the managed runtime at
`~/Library/Application Support/Lattices/runtime/current/products/action`, and
`products/action` in the current Git checkout.

### Current mismatches

These product boundaries apply to both runtime versions. They are documented here so that a reader
does not infer a different owner from the command name.

- `lats computer` sounds like computer use, but it calls the Lattices core
  daemon. Action's native observe and act tools are in the Action MCP server.
- The `browser_*` tools are documented with Action because they drive
  Action-owned Chrome identities, but the Lattices CLI serves them.
- On Linux, the Action runtime's `RemoteEngine` uses the Lattices host protocol
  and the Lattices CLI's paired identity. Published builds connect to the host
  on port 9399; matching development builds connect through the gateway.
  No Action agent runs on the Linux host.

## Sessions and artifacts

The runtime records each run as a session. A session directory holds
observations (screenshots, accessibility snapshots, OCR), the action trace, a
manifest, and any recordings. CLI inspection writes sessions under
`artifacts/sessions/`. MCP `session_create` creates one, and
`artifacts_list` reads it.

## Observe, resolve, act

The MCP tools follow one loop:

1. `observe_snapshot` captures the surface: screenshot, accessibility, and OCR.
2. `resolve_target` turns a query (a label, text, or point) into a target.
3. `act_execute` runs one act: click, type, press-key, drag, scroll,
   focus-window, or open-app.

Accessibility comes first. A target with a bundle id and label is pressed or
set through accessibility. The pointer is a fallback.

## Drive leases

A drive lease marks that an agent is acting on the desktop. The supervision
HUD shows the lease's agent and task. `drive_begin` and `drive_release` manage
leases from MCP. An `attention` lease, which takes the system pointer, requires
explicit approval and the agent's capability token. See [API](/action/docs/api).

## Stage and agent layer

These features solve opposite problems.

| Feature | Use it to | Changes |
| --- | --- | --- |
| [Stage](/action/docs/stage) | Present listed windows on a flat backdrop for a recording | Puts a sheet behind the listed windows on the user's screen |
| [Agent layer](/action/docs/agent-layer) | Work an app or browser out of the user's sight | Moves the task to a prepared virtual display |

## Capability discovery

Version strings do not prove feature parity. Before private-layer work, read
`lats action capabilities` or the MCP `capabilities` tool. Check the source and
native fingerprints, `runtimeParity.state`, host quarantine, and
`acceptance.privateLayer.state`.

## MCP tool names

The Action MCP server advertises underscore names by default
(`observe_snapshot`, `layer_open`, `drive_begin`). Dotted names such as
`action.observe.snapshot` are compatibility aliases, enabled with
`ACTION_MCP_TOOL_NAMES=legacy` or `both`. Use the names from the active
`tools/list`.
