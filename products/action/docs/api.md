---
title: API
description: The Action agent WebSocket protocol over authenticated private action.sock
order: 3
---

The Action agent is a local WebSocket server inside `Action.app`. This page
documents its raw RPC protocol. Most agents use the Action MCP server instead
(see [Agent setup](/action/docs/agent-setup)). The MCP server adds sessions,
target resolution, recording status, stage, and private layers on top of this
protocol.

Source of truth:
[`ActionAgentProtocol.swift`](https://github.com/arach/lattices/blob/main/products/action/native/engine/CoreSources/ActionAgentProtocol.swift)
and
[`ActionAgentRuntime.swift`](https://github.com/arach/lattices/blob/main/products/action/native/engine/CoreSources/ActionAgentRuntime.swift).

## Transport

| Property | Value |
| --- | --- |
| Protocol | WebSocket, text frames, JSON |
| Address | `~/.lattices/run/action.sock` |
| Protocol version | `2`, reported by `status` |
| Authentication | Connection token for every WebSocket; additional capability token for privileged methods |

`status` reports `authentication: "capability-token"` and `authTokenFile`, the
path of a token file that the agent writes at each launch. The file is
user-only (`0600`) in a user-only directory (`0700`).

Privileged requests must include `protocolVersion` and `authToken` in their
params. The privileged requests are:

- `drive.begin` with `mode: "attention"`;
- `workspace.dragFile`;
- `workspace.cancelOperation`.

Every method requires an authenticated connection.

### Private connection

Action 0.4.0 uses the private connection below. Install its matching runtime
and Lattices CLI 0.15.1. Earlier TCP clients do not automatically fall back.

| Property | Value |
| --- | --- |
| Address | Unix socket `~/.lattices/run/action.sock` (override with `ACTION_SOCKET_PATH`) |
| Connection token | `~/.lattices/run/action.token`, sent as `x-lattices-token` on the WebSocket upgrade with `Host: localhost` and no `Origin` |
| Local access | User-owned directory mode `0700`, socket and token mode `0600`, plus the connection token. The server does not perform a separate peer-UID check. |
| TCP | `127.0.0.1:4319` opens only with `ACTION_ALLOW_TCP=1`, and still requires the connection token |

Every connection now needs the token, not only the privileged methods. The
privileged methods above still check `authToken` in their params as well. The
Action runtime and `lats action call` read the token for you.

Remote machines cannot reach this socket. A paired tailnet client can call a
reviewed subset of Action methods through the Lattices gateway, one exact grant
per method, for example `--grant action:status`. The gateway opens one Action
connection per call. It therefore denies `drive.begin`, `drive.touch`,
`drive.release`, `workspace.dragFile` and `workspace.cancelOperation`, which
create or use a lease owned by a persistent connection. `drive.status` remains
available with its own read grant. See
[Private IPC and the gateway](/lattices/docs/concepts#private-ipc-and-the-gateway).

The receive side stays armed while a request runs, so a cancellation can arrive
during a gesture. Responses are serialized and correlated by request `id`.

## Request

```json
{
  "id": "4f2c9b1e",
  "method": "capture.screenshotScreen",
  "params": { "output": "/tmp/screen.png" }
}
```

- `id`: request id. Native clients default to a UUID.
- `method`: a method name from the table below.
- `params`: a flat map of string keys to string values. Send numbers and
  booleans as strings (`"1440"`, `"true"`).

## Response

```json
{
  "id": "4f2c9b1e",
  "ok": true,
  "result": { "outputPath": "/tmp/screen.png", "status": "screenshot" },
  "error": null
}
```

- `ok`: success flag.
- `result`: a flat string map. Structured values, such as a drive lease, arrive
  as JSON strings inside this map.
- `error`: an error string when `ok` is `false`.

## Methods

### Runtime and permissions

| Method | Purpose | Params |
| --- | --- | --- |
| `ping` | Liveness check | none |
| `status` | Service metadata, method list, protocol version, build provenance, token path | none |
| `permissions.snapshot` | Accessibility and Screen Recording state | none |
| `permissions.request` | Prompt for both permissions | none |
| `permissions.requestAccessibility` | Prompt for Accessibility | none |
| `settings.openAccessibility` | Open the Accessibility settings pane | none |
| `settings.openScreenRecording` | Open the Screen Recording settings pane | none |

### Apps, windows, and input

| Method | Purpose | Params |
| --- | --- | --- |
| `app.launch` | Launch an app | `bundleId` |
| `app.activate` | Bring an app forward | `bundleId` |
| `window.setFrame` | Move and resize the app's window | `bundleId`, `x`, `y`, `width`, `height` |
| `window.getFrame` | Read the app's window frame | `bundleId` |
| `input.typeText` | Type text into the focused element | `text` |
| `input.drag` | Pointer drag | `fromX`, `fromY`, `toX`, `toY`, optional `durationMs` (default 300), optional `filePath` |
| `accessibility.pressElement` | Press an element by label | `bundleId`, `label`, optional `role` |
| `accessibility.setValue` | Set an element's value | `bundleId`, `label`, `value`, optional `role` |

`calculator.buttons`, `calculator.clickButton`, and `calculator.displayValue`
exist for the Calculator demo scenario. They are not a general API.

### Drive leases

A drive lease tells other clients that an agent is acting on the desktop. The
lease belongs to the connection that created it. Closing the connection
cancels that connection's leases only.

| Method | Purpose | Params |
| --- | --- | --- |
| `drive.begin` | Acquire a lease | `agent`, `task`, optional `mode`, `sessionId`; attention mode also needs approval, run and workspace ids, capability, resource, `protocolVersion`, `authToken` |
| `drive.touch` | Renew a lease | `leaseId`, optional `axTier`, `actionKind` |
| `drive.release` | Release a lease | `leaseId`, optional `outcome`, `summary` |
| `drive.status` | Snapshot of current leases | none |
| `sessions.prune` | Remove stale drive sessions | none |
| `sessions.clear` | Remove all drive sessions | none |

### Workspace drag

| Method | Purpose | Params |
| --- | --- | --- |
| `workspace.dragFile` | Drag one exact run fixture from Finder into one exact Scout drop zone | lease, run, and workspace ids; fixture URL; Finder and Scout window identities; destination AX identifier; display bounds; `protocolVersion`; `authToken` |
| `workspace.cancelOperation` | Cancel one in-flight operation | `leaseId`, `operationId`, `protocolVersion`, `authToken` |

`workspace.dragFile` is not a generic coordinate drag. It rejects unknown
params and accepts no source point, destination point, duration, command, or
executable. Action resolves exactly one Finder item by AXURL inside exactly one
titled Finder window. Action resolves exactly one run-scoped AX drop-zone
identifier inside exactly one titled `app.openscout.scout` window. All resolved
frames and points must be inside the supplied display bounds.

An approved attention `drive.begin` acquires the global `system-pointer`
resource and grants one `workspace.drag-file` capability. The capability is
bound to the connection, run, and workspace, and is consumed before the
gesture. During the drag, Action checks the lease and operation stop signals
on every step. Cleanup always attempts mouse-up and restores the saved pointer
position.

### Capture

| Method | Purpose | Params |
| --- | --- | --- |
| `capture.screenshotScreen` | Screenshot the main display | `output` |
| `capture.screenshotRegion` | Screenshot a region | `x`, `y`, `width`, `height`, `output` |
| `capture.screenshotAppWindow` | Screenshot an app window | `output`, `bundleId` or `pid` |
| `capture.recordRegion` | Record a region | `x`, `y`, `width`, `height`, `output`, optional `fps`, `scale`, `stopFile`, `finishedFile`, `debugLog`, `includeSupervisionOverlay` |
| `capture.recordAppWindow` | Record an app window | `bundleId`, `output`, optional `stopFile`, `finishedFile`, `debugLog` |

## Recording contract

The agent does not record in its own process. A record method launches a fresh
`Action.app` instance in `recording-probe` mode, and that probe performs the
ScreenCaptureKit capture.

- A successful reply means the probe started.
- The recording ends when the `stopFile` appears.
- Completion is the movie at `output` plus the `finishedFile` marker. The
  marker can also contain a recording error.
- Pass `debugLog` to collect probe logs.

See [Recording](/action/docs/recording).

## What is not in this protocol

- Private layers (`layer_*`), stage, observation, target resolution, and
  session artifacts are MCP and runtime features. The raw agent does not
  orchestrate them. See [Agent layer](/action/docs/agent-layer).
- The `browser_*` tools belong to the Lattices MCP. See
  [Browser](/action/docs/browser).
- `computer.*` methods belong to the Lattices core daemon on `lattices.sock`, not to
  this agent. See the [Lattices API](/lattices/docs/api).

## From the Lattices CLI

`lats action call <method> [params-json]` sends one request and prints the
result. In released builds it does not attach a capability token, so it cannot
call privileged methods. The matching runtime reads and attaches the token automatically;
see [Private connection](#private-connection).

```sh
lats action call status
lats action call window.getFrame '{"bundleId":"com.apple.calculator"}'
```

## Remote Linux hosts

The raw agent protocol is local to the Mac. For a Linux desktop, the Action
runtime connects to `lattices-host` instead. See
[Remote engine](/action/docs/remote-engine).
