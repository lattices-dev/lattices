# action

> Native-first macOS demo automation with an AppKit UI and a local agent runtime

## Critical Context

**IMPORTANT:** Read these rules before making any changes:

- Migration is complete: the original Action main history was merged into arach/lattices at products/action on August 27, 2026 (import commit b1ad511adf509c0c60d7f3edce7cd15257601db2). Use arach/lattices for ongoing development; arach/action is historical.
- On Arach's Mac, /Users/arach/dev/action is a compatibility symlink to /Users/arach/dev/lattices/products/action. Both paths share the Lattices Git checkout and its uncommitted work. Verify the Git root and status before changing files.
- Read ../../AGENTS.md for Lattices workspace rules before applying these product instructions. Keep Action.app, its local agent, and its recording lifecycle independent from the Lattices menu bar app.
- Private layers: read docs/agent-layer.md. Check CLI/MCP capabilities, native/source provenance, host quarantine and acceptance.privateLayer.state=accepted before opening. MCP layer_open {browser:true} binds a CDP-only session; input failures never authorize native fallback. Reconnect after updates. Version and raw WS methods do not prove feature parity.
- Persistent monitor: layer prepare explicitly connects a display and may change desktop topology. Tasks attach with layer open; layer close restores task windows but leaves the monitor connected. Only explicit layer release disconnects it. Check layer display-status; never provision or release silently during a task.
- Installation targets use a matched signed app and MCP runtime with rollback. native:doctor rebuilds; use it only on an authorized development host.
- Use bun as the JavaScript package manager for this repo.
- Action lives at `products/action/` inside the Lattices monorepo. Run product-local commands from this directory or use the root `action:*` scripts.
- The public product page and published Action documentation live at `https://lattices.dev/action`; source links point into `arach/lattices`.
- Action releases use `action-vX.Y.Z` tags so they cannot collide with Lattices app tags.
- The native product lives in native/engine and builds a signed Action.app bundle.
- Action.app owns AppKit lifecycle, menus, WebKit, permissions UX, and the recording probe path.
- The local Action agent exposes WebSocket methods and should not own fragile AppKit lifecycle responsibilities directly.
- ScreenCaptureKit recording is currently stabilized by launching a fresh Action.app instance in recording-probe mode.
- Recording commands should be treated as asynchronous: the initial CLI reply acknowledges startup, while completion is represented by a finished marker file.
- The repo still contains older design docs in docs/*.md that describe architecture and product direction beyond the Dewey quickstart set.

## Project Structure

| Component | Path | Purpose |
|-----------|------|---------|
| Root | `README.md` | |
| Dewey | `dewey.config.ts` | |
| Native | `native/engine/` | |
| AppHost | `native/engine/Sources/ActionHostMain.swift` | |
| AgentRuntime | `native/engine/CoreSources/ActionAgentRuntime.swift` | |
| RecordingProbe | `native/engine/Sources/RecordingProbeAppRunner.swift` | |
| Launcher | `native/engine/Sources/ActionLauncherViewModel.swift` | |
| Docs | `docs/` | |

## Quick Navigation

- Working with **webkit**? → Read docs/native-runtime.md and native/engine/Sources/ActionHostMain.swift for the AppKit-owned UI lifecycle.
- Working with **record**? → Read docs/recording.md and native/engine/CoreSources/ActionRecordingProbeLauncher.swift before changing recording behavior.
- Working with **agent**? → Read docs/native-runtime.md and native/engine/CoreSources/ActionAgentRuntime.swift for the current app/agent split.
- Working with **permission**? → Check native/engine/Sources/ActionLauncherViewModel.swift and the native wrapper scripts in native/engine/scripts/.
- Working with **build**? → On the authorized development host, use native/engine/scripts/build-app.sh to produce a signed app bundle. native:doctor rebuilds; do not run it as read-only installation-target QA.
- Working with **theme**? → Read docs/theming.agent.md before changing colour, type or metrics. Views paint through StageHUDTheme, which resolves whichever ActionTheme is installed; themes are patches authored as JSON.

## Getting started

> Install Action.app, grant permissions, and check the local agent

This page installs the released `Action.app` and checks that its agent runs.
To build Action from source, see [Build from source](#build-from-source).

## Prerequisites

- macOS on Apple Silicon.
- [Bun](https://bun.sh/docs/installation).
- The Action CLI. Install it with `bun add -g @lattices/action`.

## Install and launch

1. Install the app:

   ```sh
   action install
   ```

   The command downloads `Action.dmg` from the latest `action-v*` GitHub
   release and installs `/Applications/Action.app`. It does not need a source
   checkout. Add `--launch` to open the app after installation.

2. Launch the app:

   ```sh
   action launch
   ```

3. Grant Accessibility and Screen Recording to `Action.app`:

   ```sh
   action setup action-cua
   ```

   Setup asks macOS for both and waits until they are granted. Native control
   needs Accessibility. Screenshots and recording need Screen Recording.

4. Check the status:

   ```sh
   action status --json
   ```

   Under `app`, expect `installed: true`, `running: true`, and
   `agentReachable: true`. `backends` reports each computer-use backend.

If `agentReachable` is `false`, launch the app again with `action launch`.
`Action.app` starts its agent helper when it launches.

## Query the agent

```sh
action call ping
action call status
action call permissions.snapshot
```

`status` lists the supported methods, the protocol version, and the path of
the capability-token file. Parameters are a JSON object; the CLI sends each
value as a string:

```sh
action call capture.screenshotScreen '{"output":"/tmp/action-screen.png"}'
```

See [API](/action/docs/api) for every method.

## Connect an agent

The app alone does not include the MCP server. To connect Claude Code, Codex,
or another MCP harness, install the matching runtime bundle and configure it as
described in [Agent setup](/action/docs/agent-setup). After that, verify the
install:

```sh
action capabilities
```

Expect `runtimeParity.state` to be `matched-source-digest`. A version number
alone does not prove that the app and runtime match.

## Quit

```sh
action quit
```

This quits the Action launcher. Prepared [agent-layer](/action/docs/agent-layer)
displays stay connected until you release them explicitly.

## Build from source

Use this path only on a development host. Requirements are macOS 14 or newer,
Bun, and a Swift 6.2 toolchain. Without a developer signing identity, the build
uses ad hoc signing, and permission checks are not stable across rebuilds.

From `products/action` in a Lattices checkout:

1. Install dependencies:

   ```sh
   bun install
   ```

2. Build the signed app:

   ```sh
   bun run native:app:build
   ```

   The build writes `native/dist/Action.app`, including the agent helper.

3. Launch the app:

   ```sh
   bun run native:launch
   ```

   The launch command rebuilds only if the app is missing or older than its
   sources. After a native change, use `bun run native:relaunch`.

4. Check the bundle and permissions:

   ```sh
   bun run native:verify
   bun run native:permissions:status
   ```

5. With permissions granted, run the capture smoke checks:

   ```sh
   bun run native:test:screenshot
   bun run native:test:record
   ```

   The recording check waits for completion and reports the video, the
   `.finished` marker, and the debug log.

`bun run native:doctor` builds, signs, verifies, and reports permissions in one
step. It changes the native build. Do not run it as a read-only check on an
installation target. From the Lattices repository root, `bun run action:launch`
and `bun run action:dev` call the same launch and relaunch scripts.

## Recording is asynchronous

A recording start reply means that startup was accepted. It does not mean that
the recording finished. Completion is the movie file plus a `.finished` marker.
See [Recording](/action/docs/recording).

## Next steps

- [Concepts](/action/docs/concepts)
- [Native runtime](/action/docs/native-runtime)
- [Browser](/action/docs/browser)

## Concepts

> Action's processes, ports, command routes, sessions, leases, and capture lifecycle

This page names the parts of Action and shows which process receives each
command.

## Runtime versions

The port numbers and connection behavior below describe published builds.
Matching development builds use private IPC: the Action agent listens on
`~/.lattices/run/action.sock`, and the runtime and `action call` supply
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
| `action install`, `update` | `@lattices/action` | Downloads `Action.dmg` from the latest `action-v*` release to `/Applications` |
| `action launch`, `quit`, `status` | `@lattices/action` and `Action.app` | Starts or stops the app. Prepared layer displays survive `quit`. `status` also reports each computer-use backend. |
| `action call <method>` | Action agent, `action.sock` | Raw RPC. The CLI supplies the local token and protocol version. |
| `action setup`, `observe`, `press`, `set`, `act` | `@lattices/action` | Computer use through `action-cua`, `codex-cua`, or `trycua-cua` |
| `action mcp` | `@lattices/action` MCP server (stdio) | The computer-use tools (`cua_*`). The full Action MCP server, with drive and layer tools, is `lats action mcp`. |
| `action capabilities`, `layer …`, other verbs | Action runtime CLI | Forwarded to `<action-root>/packages/cli`. Fails without a runtime or checkout. |
| `lats action …` | Lattices CLI | The same app commands from the Lattices CLI, plus `lats action mcp` |
| `lats cua …` (alias `lats computer`) | Lattices core daemon, port 9399 | `cua.*` methods (alias `computer.*`) are implemented in Lattices core, not in Action |
| `lats mcp` (`browser_*` tools) | Lattices MCP server | Drives Action-owned Chrome profiles over CDP. It does not call Action.app. |
| Action MCP with `ACTION_REMOTE_HOST` | `lattices-host` on the remote machine, port 9399 | The Linux path uses the Lattices host protocol, not the Action agent |

The Lattices CLI finds an Action root in this order: `ACTION_ROOT`, the
`products/action` directory next to the CLI, the managed runtime at
`~/Library/Application Support/Lattices/runtime/current/products/action`, and
`products/action` in the current Git checkout.

### Current mismatches

These product boundaries apply to both runtime versions. They are documented here so that a reader
does not infer a different owner from the command name.

- `lats cua` sounds like Action, but it calls the Lattices core
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

Every `act_execute` reply, success or error, carries `delivery`. It says how
far the act got, so an agent knows whether to send it again:

| `status` | Meaning | `retrySafe` |
| --- | --- | --- |
| `not_delivered` | Refused or failed before any host command ran. Nothing happened. | true |
| `delivery_uncertain` | A host command ran and failed. The act may have landed. | false, except focus-window and open-app |
| `delivered_unverified` | The host ran the act. Nothing read the result back. | false, except focus-window and open-app |

`recovery` is `retry`, `observe_then_retry` (observe first, then act only if
the change is missing) or `none`.

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
`action capabilities` or the MCP `capabilities` tool. Check the source and
native fingerprints, `runtimeParity.state`, host quarantine, and
`acceptance.privateLayer.state`.

## MCP tool names

The Action MCP server advertises underscore names by default
(`observe_snapshot`, `layer_open`, `drive_begin`). Dotted names such as
`action.observe.snapshot` are compatibility aliases, enabled with
`ACTION_MCP_TOOL_NAMES=legacy` or `both`. Use the names from the active
`tools/list`.

## API

> The Action agent WebSocket protocol over authenticated private action.sock

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
Action runtime and `action call` read the token for you.

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

`action call <method> [params-json]` sends one request and prints the
result. In released builds it does not attach a capability token, so it cannot
call privileged methods. The matching runtime reads and attaches the token automatically;
see [Private connection](#private-connection).

```sh
action call status
action call window.getFrame '{"bundleId":"com.apple.calculator"}'
```

## Remote Linux hosts

The raw agent protocol is local to the Mac. For a Linux desktop, the Action
runtime connects to `lattices-host` instead. See
[Remote engine](/action/docs/remote-engine).

## Browser

> The three browser surfaces an agent can drive with Action, and which tools reach each one

An agent can use a browser with Action in three ways. They differ in which
tools reach the page, which identity the page has, and whether the user sees it.

## Choose a surface

| Surface | Served by | Control | Identity |
| --- | --- | --- | --- |
| Your regular Chrome | Action MCP native tools | Screen capture and accessibility only (`observe_snapshot`, `resolve_target`, `act_execute`) | Your real Chrome profiles |
| An Action browser | Lattices MCP `browser_*` tools | DOM control over the Chrome DevTools Protocol (CDP) | An Action-owned Chrome profile, blank or seeded |
| A private-layer browser | Action MCP `layer_*` tools | CDP only, on a prepared virtual display | An Action-owned profile per workspace |

Use regular Chrome when the task needs your live session and visible tabs. Use
an Action browser for DOM-level work in a window you can watch. Use a
private-layer browser when the work must stay off your screens.

## Regular Chrome

`browser_open {mode:"regular"}` opens a URL in your own Chrome as a visible
handoff. Nothing attaches DevTools to it. To act in that window, use the Action
MCP native loop: `observe_snapshot`, then `resolve_target`, then
`act_execute`.

## Action browsers

The `browser_*` tools are part of the Lattices MCP server, not `Action.app`.
Register it once:

```sh
claude mcp add lattices -s user -- lattices mcp
```

The tools launch a real, non-headless Chrome on an Action-owned user data
directory and drive it over CDP. The debug port defaults to `9334` and can be
set with `ACTION_BROWSER_DEBUG_PORT`.

| Tool | Purpose |
| --- | --- |
| `browser_open` | Open a URL in an Action browser, or hand it to regular Chrome |
| `browser_snapshot` | Read the page as an element list with refs |
| `browser_click`, `browser_fill` | Act on an element ref |
| `browser_screenshot`, `browser_resize` | Capture or size the viewport |
| `browser_tabs`, `browser_close` | List or close tabs |
| `browser_console` | Read console output |
| `browser_profiles`, `browser_profile_info`, `browser_use_profile` | List and select browser identities |
| `browser_import_cookies` | Seed an identity with cookies from one of your Chrome profiles |
| `browser_companion_status` | Check the optional Chrome companion bridge on `ws://127.0.0.1:4321` |

Identities, cookie seeding, and the companion bridge are covered in
[Browser profiles](/action/docs/browser-profiles). The full tool reference is
in the [Lattices MCP](/lattices/docs/mcp) page.

## Private-layer browsers

A private-layer browser runs on a prepared virtual display in an agent-layer
workspace. Prepare the display once with the CLI, then use the Action MCP:

```text
layer_open     {workspace, browser:true, url, task}
layer_snapshot {workspace}
layer_click / layer_type / layer_press / layer_js / layer_go
layer_close    {workspace}
```

- `layer_open` begins a drive lease unless you pass an existing `leaseId`.
  `layer_close` releases it.
- Coordinates come from the last `layer_snapshot`.
- The path is CDP only. There is no native fallback, so do not mix in desktop
  `observe_*` or `drive_aim` calls.
- Browser flags, navigation, input, and JavaScript need MCP. The CLI `layer`
  commands cover lifecycle, snapshot, picture-in-picture, and recording.

Read `capabilities` first and confirm that the host and build accept private
layers. See [Agent layer](/action/docs/agent-layer).

## Browser profiles

> Regular Chrome, Action browsers, and identities seeded from your Chrome profiles

How Action gives an agent a **browser identity** without taking over your daily
Chrome, and which kind of control you get in each case.

## Three browsers, two kinds of control

When an agent says "I'll open it in Chrome", it can mean one of three things.
They are not interchangeable.

| | What it is | What the agent can do |
|---|---|---|
| **1. Your regular Chrome** | The browser you use all day. Your real profiles (`Default`, `Profile 1` / "Work"), your tabs, history, extensions, and logins. | **Open a URL, and that's it.** `browser_open { mode: "regular" }` is a visible handoff with no DevTools attachment. To make the agent *act* there, use Action's native macOS control: screen capture + accessibility (`action.observe.snapshot`, `action.resolve.target`, `action.act.execute`). |
| **2. An Action browser** | A real, non-headless Chrome that Action owns, on its own user-data-dir under `~/Library/Application Support/Action/ChromeProfiles/`. The default identity `agent-browser` is blank and signed into nothing. | **Full DOM control** over CDP: `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot`, `browser_tabs`. |
| **3. An Action browser identity seeded from one of your Chrome profiles** | The same Action-owned Chrome under a name you choose (`work`, `mira`, …), carrying cookies copied from one of your real profiles for an explicit allowlist of domains. | **Full DOM control, on sites you're already signed in to.** |

The tradeoff in one line: **your regular Chrome has your session but only
screen-and-accessibility control; an Action browser has DOM control but starts
as a stranger.** Seeding (option 3) is how you get both.

This is a boundary Action does not try to cross. [Chrome 136 and later ignore
remote-debugging switches for the default personal data
directory](https://developer.chrome.com/blog/remote-debugging-port), and Action
does not attempt to bypass it. Pointing automation at your everyday user-data-dir
would also fight Chrome's directory lock and hand an agent your full history,
extensions, and sessions by accident.

### Picking one

- The user wants to *look* at something in their own browser → **regular**.
- The agent needs to click through a public site → **Action browser**.
- The agent needs to click through a site you're logged into → **seeded identity**.
- The agent needs to act inside your real signed-in session, and cookies aren't
  enough (passkeys, SSO device trust, an extension's state) → **regular Chrome
  plus Action's native observe/act**, not the browser tools.

## The canonical example: seed "Profile 1" into `work`, then drive it

Your Chrome profile *directory* names are `Default`, `Profile 1`, `Profile 2`, …
and are not the display names you see in Chrome's avatar menu. A browser you
call "Work" is usually the `Profile 1` directory. Map them first, then seed.

From an agent, over MCP:

```text
browser_import_cookies { listSourceProfiles: true }
# -> [{ dir: "Default", name: "Personal" }, { dir: "Profile 1", name: "Work" }, ...]

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"] }
# dry run: lists exactly which cookies would be copied

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"], confirm: true }
# writes them into the Action identity `work`

browser_open { url: "https://github.com/notifications", profile: "work" }
browser_snapshot
browser_screenshot
```

The same thing from the terminal:

```bash
# map display names to profile directories
bun run chrome:companion:import:cookies -- --list-profiles

# dry run
bun run chrome:companion:import:cookies -- list --into work --source "Profile 1" --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --source "Profile 1" --domains github.com --confirm
```

After that, `work` is an ordinary Action identity: `browser_use_profile
{ profile: "work" }` or `browser_open { url, profile: "work" }`, and every DOM
tool works against it.

## Named identities

Identities are created on first use: any unused name gives you a fresh blank
one. Shipped conventions:

- `agent-browser`: the default blank agent identity
- `work`: seeded from your work Chrome profile, per the example above
- `mira`: the creative/Midjourney identity used by the companion tooling

Create and prepare one with the companion extension loaded:

```bash
# from the Action product root (`products/action`)
bun run chrome:companion:profile -- setup work
```

This builds the companion extension, creates the profile directory, opens
`chrome://extensions` in that profile, and reveals `packages/chrome-companion/dist`
so you can **Load unpacked** once.

Later:

```bash
bun run chrome:companion:profile -- launch work
bun run chrome:companion:profile -- check work
bun run chrome:companion:profile -- path work
```

Environment aliases (shared between companion tooling and Action Browser MCP):

| Variable | Meaning |
|----------|---------|
| `ACTION_BROWSER_PROFILE` / `ACTION_CHROME_COMPANION_PROFILE` | Active identity name |
| `ACTION_BROWSER_PROFILE_DIR` / `ACTION_CHROME_COMPANION_PROFILE_DIR` | Absolute user-data-dir override |
| `ACTION_BROWSER_PROFILE_ROOT` / `ACTION_CHROME_COMPANION_PROFILE_ROOT` | Root for named identities |
| `ACTION_BROWSER_DEBUG_PORT` | CDP port (MCP default `9334`) |
| `ACTION_ROOT` | Action product root (`<lattices-checkout>/products/action`); cookie tools use it when the MCP process starts elsewhere |

## Cookie seeding

Copy **selected** cookies from a regular Chrome profile into an Action identity:

```bash
# list your Chrome profiles (directory + display name)
bun run chrome:companion:import:cookies -- --list-profiles

# list Action identities
bun run chrome:companion:import:cookies -- --list-action-profiles

# dry-run
bun run chrome:companion:import:cookies -- list --into work --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --domains github.com --confirm

# narrow to specific cookies
bun run chrome:companion:import:cookies -- import --into mira \
  --domains midjourney.com \
  --only cf_clearance \
  --confirm
```

Or via the profile CLI:

```bash
bun run chrome:companion:profile -- import-cookies import --into work --domains github.com --confirm
```

Notes:

- Requires a Keychain allow for Chrome Safe Storage only when decrypting values;
  the import path copies encrypted blobs as-is for same-machine use.
- Prefer domain allowlists over full-jar dumps.
- Cookies are not a complete identity (localStorage / passkeys may still need a
  one-time interactive login in the Action identity).

## Chrome companion (generic extension)

Package: `packages/chrome-companion`

- Manifest V3 extension with DOM observe / resolve / act helpers
- In Action versions before 0.4.0, a localhost bridge on `http://127.0.0.1:4321` (WebSocket for the extension)
- One-time **Load unpacked** per Action identity (`dist/` after build)

Action 0.4.0 uses Chrome native messaging instead
of the extension's TCP connection. The registered native host connects to
`~/.lattices/run/action-chrome.sock` with `action-chrome.token`. Use the matching
extension, native host, and Action runtime, including for a local installation.
Register the host for the exact extension ID and Chrome user-data directory;
registration for regular Chrome does not cover a separate Action identity.

```bash
bun run chrome:companion:build
bun run chrome:companion:bridge
bun run chrome:companion:health
bun run chrome:companion:profile -- setup work
```

Chrome Stable often ignores `--load-extension`; the reliable path is manual
unpacked install inside the Action-owned identity.

## Action browser MCP

Server: `bin/mcp/toolsets/browser/index.ts` in the lattices repo root. The
browser tools are a toolset inside the lattices MCP, served by `lattices mcp`.
See [the Lattices MCP doc](/lattices/docs/mcp).

### Tools

| Tool | Purpose |
|------|---------|
| `browser_profiles` | List Action identities, the active one, and the three-surface policy |
| `browser_use_profile` | Switch the active identity (`agent-browser`, `work`, `mira`, …) |
| `browser_profile_info` | Active path, cookie readiness, companion hints |
| `browser_import_cookies` | Dry-run or confirm a seed from a regular Chrome profile |
| `browser_companion_status` | Extension dist + bridge health |
| `browser_open` | Open in an Action browser, or `mode: "regular"` for an open-only handoff |
| `browser_tabs` / `browser_snapshot` / `browser_click` / `browser_fill` / `browser_screenshot` / `browser_close` | DOM automation via CDP, Action browsers only |
| `browser_console` | Read console messages from an Action browser tab |
| `browser_resize` | Set a tab to an explicit viewport width and height for responsive checks; `target: "window"` resizes the real Chrome window instead |

### Two MCP surfaces

- **Native runtime MCP** (`action`): observe / resolve / act / record on macOS
  through Action.app. This is what controls your *regular* Chrome window, and
  every other native app, via screen capture and accessibility.
- **Browser MCP** (the `browser` toolset of `lattices mcp`): Action-owned Chrome
  identities plus DOM-level tools over CDP.

Register it. The entry names the `lattices` binary and no path, so a repo move or
a version bump cannot break it:

```bash
claude mcp add lattices -s user -- lattices mcp
```

To pin a default identity, add the environment variable to that same entry:

```bash
claude mcp add lattices -s user -e ACTION_BROWSER_PROFILE=work -- lattices mcp
```

`ACTION_ROOT` is only needed for the Chrome Companion paths below, and only when
the tools run from a published `lattices` install rather than a checkout.

### Agent workflow

```text
browser_profiles                                   # what identities exist
browser_use_profile { profile: "work" }            # pick one
browser_open { url: "https://github.com" }         # drive it
browser_snapshot
browser_screenshot
browser_companion_status                           # optional richer DOM path
browser_close { scope: "browser" }                 # when the task is done
```

To open a URL in the user's own Chrome instead:

```text
browser_open { url: "https://github.com", mode: "regular" }
```

Regular mode is deliberately not controllable, and the result says so:
`controlAvailable: false`, plus the native control path. Snapshot, click, fill,
and screenshot continue to target the Action browser.

### Responsive breakpoints

`browser_resize` gives an already-open tab an explicit viewport, so a narrow
layout can be captured instead of assumed.

```text
browser_open   { url: "http://localhost:3000" }
browser_resize { width: 1440, height: 900 }
browser_screenshot
browser_resize { width: 390, height: 844, mobile: true, matchMedia: ["(max-width: 767px)"] }
browser_screenshot
browser_resize { reset: true }
```

Two targets, deliberately not interchangeable:

| | What moves | Cost |
|---|---|---|
| `target: "tab"` (default) | CSS emulation for that one tab | Exact to the pixel, other tabs unaffected, fully reversible |
| `target: "window"` | The real Chrome window hosting the tab | Every tab in that window moves, the display is a hard ceiling, and the tab's emulated viewport is dropped first |

A device-metrics override belongs to the CDP session that set it, and Action
Browser opens a fresh session per tool call. Two consequences shape the design:

- The server keeps the requested viewport in memory and re-applies it on every
  session, so a resize survives the later `browser_screenshot` that is the whole
  point of it. It is per-tab, in-memory only, and dropped when the tab or the
  browser closes. Nothing is written to the profile.
- `reset` cannot simply call `clearDeviceMetricsOverride`: a foreign session's
  clear is accepted and does nothing, leaving Chrome stuck at the stale size. The
  reset re-sets the metrics to adopt ownership first, then clears them.

`deviceScaleFactor` defaults to `1`, which makes screenshot pixels equal CSS
pixels: a 390-wide viewport returns a 390px-wide PNG. Read `exact` in the reply
before trusting a capture: a page with a hard `min-width` can refuse to lay out
as narrow as it was asked to.

## Plugin versioning

Harnesses cache the Action Browser skill and interface metadata by plugin
version. Bump all seven manifests together when that metadata changes:

```bash
bun run plugin:version              # check that every manifest agrees
bun run plugin:version -- 0.4.1     # set them all
```

The check covers the root and Action product marketplace/Kimi manifests, plus
the browser plugin's Claude, Codex, and Kimi manifests. Reinstall or refresh the
plugin in each harness so its cached skill is replaced.

The plugin no longer carries an MCP server or a `SERVER_VERSION`. Browser tools
ship with the lattices CLI; updating that CLI and restarting its MCP process
updates the server separately from refreshing this skill-only plugin.

## What is intentionally not done

- Automation attachment to the currently open regular Chrome window
- Silent full cookie jar import
- Claiming a page is authenticated without observing it after seed/login

## Related

- [packages/chrome-companion/README.md](../packages/chrome-companion/README.md)
- [ACT-001 surface adapter architecture](decisions/ACT-001-surface-adapter-architecture.md)
- [plugins/action-browser/skills/action-browser/SKILL.md](../plugins/action-browser/skills/action-browser/SKILL.md)

## Browser request deadlines

`browser_open.waitMs` is the total operation budget (15,000 ms by default),
including profile selection, Chrome startup, HTTP/CDP connection, navigation,
and readiness checks. Zero fails immediately without opening a tab. Expiry
returns an MCP tool error and cancels pending transport work; increasing
`waitMs` does not remove the 10-second limit on individual HTTP/CDP operations.

Configure the MCP server as `command: "lattices", args: ["mcp"]`, no path, so it
cannot be pinned to a stale checkout or plugin cache. On the next MCP process
start, `initialize` reports the lattices version, and `tools/list` exposes
`browser_open.mode`, `profile`, and `newTab`. Existing MCP processes retain their
loaded implementation until reloaded.

The `lattices` launcher resolves Bun from `LATTICES_BUN_BIN`, PATH, or the
standard user and Homebrew locations, so it survives the bare system PATH a
GUI-launched harness hands it. An explicit invalid override fails with an
actionable error.

## Agent layer

> Work an app or Action-owned browser on a prepared private virtual display

Action's agent layer attaches an app or Action-owned browser to a prepared,
persistent virtual monitor. The monitor and each task have separate lifetimes.
Use MCP for the complete browser workflow.

## Named virtual workspaces

The multi-workspace candidate adds independent virtual displays. This is not a
host-isolation acceptance result. Validate the matched native app and runtime
on the target host before using it for desktop-preserving work.

Use `--workspace <name>` on each CLI layer command. Use `workspace` on each MCP
layer call. Omission selects `default`; it never selects the last workspace
used. Names contain 1–32 lowercase letters, digits, or hyphens and start with a
letter. The existing unnamed display remains the `default` workspace.

Each workspace has its own display owner, task, browser profile, preview,
operator controls, and recording. Closing a task leaves its display connected.
Opening a task never replaces an active task. An MCP caller cannot close another
caller's task. Cross-process transaction locks protect each workspace's lifecycle
and control files; concurrent mutations fail without overwriting another request.
An app process can belong to only one active workspace. Use separate browser
processes for browser tasks on different workspaces.

Preparation changes the macOS display topology. Arrange a setup interval before
running these commands. Build only in the native development workspace; copy a
matched bundle and runtime to installation targets.

```bash
action layer prepare --workspace stage --width 1920 --height 1080
action layer prepare --workspace agent --width 1440 --height 900
action layer list
```

After preflight and host acceptance, attach tasks through MCP:

```text
layer_open {workspace:"stage", previewFull:true}
layer_open {workspace:"agent", browser:true, url:"https://lattices.dev/action", previewWorkspace:"stage"}
layer_snapshot {workspace:"agent"}
layer_snapshot {workspace:"stage", full:true}
layer_record {workspace:"stage", action:"start", out:"/absolute/path/stage.mov"}
layer_record {workspace:"agent", action:"start", out:"/absolute/path/agent.mov"}
layer_go {workspace:"agent", url:"https://lattices.dev/docs/agents"}
layer_record {workspace:"agent", action:"stop"}
layer_record {workspace:"stage", action:"stop"}
```

`previewWorkspace` places the agent preview on the prepared stage display. The
displays are peers, not nested virtual machines. The outer recording captures
the stage and embedded preview. The inner recording captures the agent display.
Verify both recording completion results and movie files before reporting a take
as finished. An empty stage task does not populate or arrange application windows.

Set `previewFull:true` on the stage's `layer_open` or `layer_pip` call to show its
entire display, including the embedded agent preview. Otherwise the preview follows
the subject windows and can crop out the embedded preview. CLI equivalent:
`action layer pip --workspace stage --preview-full`. Each preview identifies
its workspace and host. Preview framing does not change full-display recording.

Use `layer_pip {workspace:"agent", previewWorkspace:"stage"}` to move an existing
preview. CLI equivalent:

```bash
action layer pip --workspace agent --preview-workspace stage
```

Action rejects self-previews and recursive preview chains. A preview that loses
its destination must not fall back to a physical screen. A display cannot be
released while another workspace previews onto it. Close the dependent agent
task before releasing the stage display:

```text
layer_close {workspace:"agent"}
layer_close {workspace:"stage"}
```

```bash
action layer release --workspace agent
action layer release --workspace stage
```

Browser profiles are separate for each named workspace. A busy debugging port
is reusable only when its process matches the expected browser executable,
profile path, and port. A mismatch fails without adopting or stopping that
process. Port overrides for named workspaces use
`ACTION_LAYER_BROWSER_PORT_<WORKSPACE>`, with uppercase letters and underscores
in place of hyphens. `ACTION_LAYER_BROWSER_PORT` applies to `default` only.

Multiple virtual displays do not create independent macOS keyboards or focus.
Browser interactions use CDP. Native input uses a shared exclusive input lease
and can still cause temporary focus changes. Validate physical display modes,
arrangement, pointer, frontmost app, and unrelated window frames throughout the
two-workspace lifecycle. Also verify independent pause, stop, recording, crash
cleanup, and preview-destination loss. Passing a one-display test does not prove
that the two-display configuration is accepted.

## Prepare the monitor once

Provision the monitor explicitly when the user is ready for a display topology
change. Preparation creates the virtual display and may change macOS modes,
arrangement, or window placement; it does not promise an unchanged desktop.
Check capabilities and quarantine first. Preparation never clears quarantine.

```bash
action layer display-status
action layer prepare --width 1440 --height 900
```

`display-status` is read-only. `prepare` reuses an existing live monitor when
the requested size matches, or when no size is supplied. A new monitor defaults
to 1440×900. A different size requires explicit release and preparation; an
ordinary task must not silently resize or recreate the monitor.

Once prepared, `layer open` attaches a task without connecting another display.
`layer close` restores that task's windows and leaves the monitor connected.
When the user wants to disconnect the monitor, use `action layer release`;
it refuses while a task is active, so close the task first with `layer close`. Release can
also change the desktop topology. A restart, crashed monitor owner, or missing
monitor requires explicit preparation again, not automatic recovery during
the next task.

## Check capabilities before opening

Run `action capabilities`, then call `capabilities` on the active MCP
connection. Check its `tools/list` for `layer_open`, `layer_snapshot`,
`layer_click`, `layer_type`, `layer_js`, and `layer_close`.
Use `action layer display-status` to confirm a prepared monitor is active.
If it is missing, stop the task and report the preparation requirement.

Compare the orchestration source digest, signed native build manifest, and
native executable hash with the intended deployment. A version match or an
installer message saying the app is current does not prove feature parity.
For a standard packaged runtime, require `runtimeParity.state` to be
`matched-source-digest`; resolve `source-digest-mismatch` or `unverified`
before use. This compares bundled artifacts; it does not verify a running app.
An overridden native host is unverified until its own artifact is checked.
Reconnect MCP after changing its runtime or configuration, then repeat discovery.

Check `safety.privateLayer` before any display or browser is opened. If blocked,
stop and report its reason and evidence path. Do not clear the quarantine or
retry through the CLI/native host. Do not replace requested isolation with
ordinary background browser opening; it can still activate or reflow the desktop.

An absent quarantine means only that no host block is recorded. It does not
prove acceptance. Inspect `acceptance.privateLayer` in the capabilities reply.
Require `state: "accepted"` for ordinary use that requires desktop preservation;
missing, stale, invalid, or unverified evidence means stop before opening.
The record lives at `~/Library/Application Support/Action/agent-layer/isolation-acceptance.json`.
It binds acceptance to the native executable and source, orchestration source,
host/OS, and physical display configuration. Capabilities checks that binding;
it does not run display QA or certify a build automatically. Older servers
without the field are unverified. See [Acceptance](#acceptance) for evidence
requirements. Controlled QA requires authorization for that host and a
preserved rollback and layout; do not manufacture a passing record.

**Known failed acceptance, 2026-10-11:** the retained Air trace shows the
physical display change from 2560×1664 to 1470×956 during
`CGVirtualDisplay.applySettings`, before browser setup and Action's positioning
transaction. Air remains quarantined. The guarded build prevents display
creation; it does not repair the display defect. A successful close or restored
focus does not pass the preservation requirement.

**Mini foreground check, 2026-10-11:** retained desktop traces from both the
PiP and no-PiP browser runs show no physical-display, pointer, or unrelated
window-frame drift. Both show the frontmost process changing to macOS
`UserNotificationCenter` during `layer_open`, before the first snapshot or
page input. That foreground check failed and is confounded by system
notification UI; it is not evidence of a Chrome/CDP input defect or an
isolation pass.

Those traces exercised the earlier per-task display-creation path. Keeping a
monitor connected removes that hotplug step from ordinary task opening; it
does not retroactively pass those runs.

**Bounded arts-mini task pass, 2026-10-11:** two task sessions reused the same
prepared display and passed strict, continuous 50 ms desktop-preservation
monitoring across open, interaction, and close. This evidence covers that host
and tested build, which predates the new persistent viewer controls. It does
not certify the current controls build, Air, cold provisioning, monitor-owner
restart, or release. Provisioning, task attachment, and release need distinct
evidence. Acceptance for ordinary tasks uses a baseline taken with the
persistent monitor already prepared; a passing run is not a current matching
acceptance record by itself.

Build and diagnose on the development host. `native:doctor` rebuilds and signs;
it is not a read-only preflight and must not be used to repair an installation
target implicitly. Install a matched native app and orchestration runtime with
rollback instead. For a packaged runtime, set `ACTION_ROOT=<extract>/products/action`,
not the extraction root. Keep the archive's sibling `bin/` and `products/`
directories together so the runtime can import `bin/host-pairing.ts`.

## Private browser workflow

Current MCP servers advertise underscore names. Use the active `tools/list`;
dotted `action.*` names are optional compatibility aliases.

```text
layer_open      { browser: true, url: "https://example.com", task: "Read the page", pip: true }
layer_snapshot  {}
layer_click     { label: "More" }
layer_type      { text: "Search text" }
layer_js        { code: "document.title" }
layer_go        { url: "https://example.com/next" }
layer_close     { outcome: "done", summary: "Read the page" }
```

`browser: true` selects Action-owned Chrome. Browser page interaction uses
CDP exclusively. If CDP is missing, a label or selector cannot be resolved,
coordinates reach browser chrome or leave the viewport, or a shortcut is not
supported by the page route, the operation fails without native input.
Use `layer_go` for navigation instead of `cmd+l`. This input contract does not
establish that virtual-display creation preserves the physical desktop.
CDP-only input also does not prevent page JavaScript from requesting popups
or focus, system permission/notification UI from appearing, or display
creation from changing the desktop. Acceptance must observe those effects.

Retain `session` from `layer_open`: `mode`, `pid`, `displayId`, `startedAt`,
and `browserPid` when present. Action results include the session and execution
route (`devtools` with `pageTargetId`, or `blink` with a native `host`). A
replacement layer invalidates the binding; do not reuse an earlier snapshot
or act against the replacement. Check `layer_status` after a connection loss
or timeout before retrying. Reobserve before repeating an operation whose
outcome is uncertain.

Use the layer's own snapshot and primitives. `layer_open` begins a drive lease
unless `leaseId` supplies one; it returns that lease and `layer_close` releases
the lease it created. A supplied lease remains the caller's responsibility.
Do not begin a second drive for the layer or use a desktop snapshot as its
coordinate reference. If setup fails, MCP attempts to close the layer it created
and reports any unconfirmed cleanup. Inspect `layer_status` before retrying.
Check `layer_status` before the first open too: opening fails while the
workspace already has an active task. Close it explicitly first, and do not
close another caller's task without user authority.

For native apps, open `{ bundleId: "com.apple.calculator", width: 1280,
height: 800, pip: true }`. Select `windowId` or `windowTitle` to borrow only
matching windows. Native input can temporarily borrow focus or the pointer;
that path does not guarantee continuous focus isolation.

## Transport boundaries

| Surface | Layer support |
| --- | --- |
| Action MCP | Complete `layer_*` workflow, including `browser: true`, URL navigation, input, and JavaScript |
| CLI | Monitor `layer prepare`, `display-status`, `release`; task `open`, `status`, `snapshot`, `pip`, `record start/stop`, `close` |
| Native host | Native display/app primitives; no MCP browser orchestration |
| Action WebSocket | Raw agent RPC catalog; route private-layer work to MCP |
| Lattices daemon | Workspace window groups; route private-layer work to Action MCP |

CLI `layer open` accepts `--bundle-id` or `--pid`, `--width`, `--height`,
`--window-id` or `--window-title`, and `--pip`. It rejects `--browser`, `--url`,
unknown flags, and unsupported interaction verbs with an MCP routing error.
The CLI task lifetime is detached; always close it when work ends. Width and
height on `open` must match the prepared monitor; they do not configure a new
display. Closing a task does not release the monitor.

## Acceptance

Read-only lookup is `action capabilities` or MCP `capabilities`, under
`acceptance.privateLayer`. The native host supplies the current host and
physical-display context; inability to read that context leaves acceptance
unverified. The record's matching status does not override `safety.privateLayer`
quarantine, prove the running process matches the installed bundle, or replace
review of the retained evidence.

The operator-reviewed record has this schema:

| Field | Required value |
| --- | --- |
| `schemaVersion`, `outcome` | `1`, `"passed"` |
| `acceptedAt`, `expiresAt`, `reviewer` | Valid ISO timestamps and a nonempty reviewer; expired records are stale. |
| `binding` | `executableSha256`, `nativeSourceDigest`, `orchestrationSourceDigest`, `hostFingerprint`, `osBuild`, `displayConfigurationDigest`, matching the current context. |
| `checks` | `physicalDisplayMode`, `scale`, `arrangement`, `frontmostApp`, `pointer`, `unrelatedWindowFrames`, each `"unchanged-throughout"`. |
| `phases` | `["open", "interaction", "close"]` |
| `evidence` | Nonempty list of `{ path, sha256 }` entries; absolute local artifact paths with verified hashes. |

Capabilities discovers and validates this record. It does not write one.
Create or renew it only from reviewed, authorized acceptance evidence.

For ordinary task acceptance, prepare the monitor first under authorized setup
conditions, then capture physical modes (logical and pixel sizes, scale and refresh rate),
display arrangement/mirroring, frontmost app, pointer, and unrelated window
frames before opening. Monitor those values throughout task attachment, interaction,
and teardown. Verify a layer snapshot and a real browser interaction, then
confirm closure and window restoration. Fail on the first unexpected change.
A final sample that matches the baseline cannot erase an earlier failure.
Test initial preparation, monitor-owner restart, and explicit release
separately; those operations change display topology and must not be folded
into a claim that ordinary tasks never connect or disconnect a display.

## What it does

- Attaches to the prepared monitor and moves the subject app's windows onto it. The original frame of each window is recorded. The persistent monitor owner holds the `CGVirtualDisplay` independently of the task.
- `windowId` (the `kCGWindowNumber`) or `windowTitle` (a case-insensitive substring) moves only the matching windows. Use it to borrow one window of an app the user is also in, such as a browser.
- Starts one ScreenCaptureKit stream on the layer display and keeps it running for the layer's life. The viewer, snapshots and recordings all come off that stream (see [Feed](#feed)).
- Launches the subject in the background if it isn't running, and asks an app with no windows for one (the reopen a Dock click sends). Background launch requests no activation; this is not an isolation acceptance result.
- `url` (a URL, a bare host read as `https`, or a file path) opens in the subject without activating it, once its windows are on the layer. It needs `bundleId` or `pid`, and can't be combined with `windowId` or `windowTitle`.
- Adopts windows the subject opens while the layer is up, such as a `cmd+n` window, a pop-up, or an `open-app` with `input.url`. They move onto the layer as they appear, cascaded. A layer that borrowed one window by `windowId` or `windowTitle` adopts nothing more.
- Shows the PiP viewer unless `pip` is `false`.
- Writes a state file: display id, global bounds (top-left origin, points), PiP state, and the moved windows with their original frames.
- Keeps one task per workspace. Opening while a task is active fails; close the task first.

## Primitives

The layer's own tools are the short way to work it. Look, then act on what you saw:

```
layer_open     { bundleId: "com.apple.Safari", url: "news.ycombinator.com" }
layer_snapshot {}                                  → p.png, 950×560
layer_click    { x: 475, y: 196 }                  pixels in that snapshot
layer_click    { label: "new" }                    or a control by its label
layer_type     { text: "lobste.rs\n" }             a trailing \n submits
layer_press    { key: "cmd+l" }
layer_drag     { from: [95, 224], to: [570, 252] }
layer_scroll   { x: 475, y: 280, dy: -600 }
layer_close    {}
```

Points are pixels in the last `layer_snapshot` image, read through its crop and scale, so an agent never adds the layer's origin or works out the display's scale. `space: "layer"` takes points on the layer display instead. A point outside the last snapshot is an error, and so is a point with no snapshot taken yet.

Browser primitives use the bound CDP page and return `route: "devtools"` with
`pageTargetId`. Native primitives use `action.act.execute` and return
`route: "blink"` with the native `host`. Both report the layer session; input
primitives normally return a fresh snapshot (`look: false` skips it). A lease
is taken for the caller when none is passed. The native routing below is not a
fallback for a browser session.

## Native blink acts

While a layer is up, `action.act.execute` routes these acts as blink acts:

| Act | Host command | When |
|---|---|---|
| `click` with a point | `blink-click` | the point is on the layer display |
| `type` | `blink-type` | no accessibility label path applies |
| `press-key` | `blink-key` | always |
| `drag` | `blink-drag` | both points are on the layer, and no `filePath` |
| `scroll` | `blink-scroll` | the point is on the layer |

Accessibility comes first. A target with a bundle id and label is pressed or set through accessibility and never blinks. `blink-click` hit-tests its point before it touches the pointer: if the element there is a button, checkbox, radio, pop-up, menu item, disclosure triangle, link or tab that takes `AXPress`, it is pressed and the result says `via=ax`. A text field, text area, combo box or search field there is focused through accessibility instead of clicked into. Nothing moves and focus does not change.

`blink-type` works the same way. It inserts the text at the caret of the app's focused text field through accessibility (`via=ax`), and only borrows focus for keystrokes (`via=keys`) when the field doesn't take it, is secure, or a `delayMs` cadence is requested. Web fields usually take keystrokes. When the field's value is readable, the blink holds focus until the text shows up in it (`via=keys verified`), because a web view consumes keys in its own content process after the app's main loop has already drained. A trailing newline in `type` text (`"lobste.rs\n"`) splits off: the text goes in through accessibility and the field is submitted with `AXConfirm`, a Return that moves nothing. `press-key` tries accessibility too: a chord that is a menu item's shortcut (`cmd+l`, `cmd+n`) presses that menu item (`via=ax menu="Open Location…"`), and a bare Return or Escape in a text field confirms or cancels it. Anything else borrows focus for the keystroke (`via=keys`).

`press-key` takes a chord in `input.key`, written however the agent reads it: `"return"`, `"cmd+l"`, `"Cmd-Shift-T"`, `"⌘⇧T"`, `["cmd", "l"]` in `input.keys`, or `key` plus `input.modifiers`. Aliases such as `enter`, `esc`, `backspace` and `ArrowDown` map to the host's names. An unknown key is an error that points at `type`, never text typed one character at a time.

The pointer is the fallback: no pressable element at the point, a requested `holdMs`, or `--pointer` on the host command. A pointer blink saves the cursor position and the frontmost app, clicks, and restores both within tens of milliseconds. Its result says `via=pointer`.

`type` and `press-key` land in the app's focused window. If that window is off the layer, the blink raises the app's layer window first, without activating the app, and refuses if focus still isn't on the layer. Keystrokes never reach a window on the user's screen.

`type` and `press-key` target `input.bundleId` or `input.pid` if given, else the layer's app. Accessibility paths (`press-accessibility-element`, `set-accessibility-value`) do not change. A click outside the layer display uses `click-point`.

Drag and scroll have no accessibility equivalent and always use the pointer. It leaves the user's screens for the length of the gesture (200 ms for a drag by default; an instant for a scroll) and comes back. Scroll wheel events activate nothing. A drag's mouse-down activates the app it lands in for up to a second, and focus is handed back afterwards.

Blink acts report the `blink` tier. A background drive lease allows them. They do not show the pointer-focus countdown.

## Feed

The layer captures its own display, not the subject app. A stream that targets an app makes macOS badge that app's windows as shared, and the badge is drawn into the window, so it would show in every frame. The framing to the subject's windows happens downstream, by crop. The stream only delivers frames when something on the layer changes, so an idle layer costs next to nothing.

- **Viewer.** The PiP grows out of the screen corner on its first frame and frames the subject's windows, following them as they move and resize. Drag the header to move it; double-click the header to enlarge it, and double-click again to restore its size. Hide leaves the layer running; `layer pip` / `layer_pip` brings it back.
- **State.** One dot in the viewer's bottom-right corner: solid coral while the agent can act, breathing while a take records, hollow while paused.
- **Marks.** The host posts where native acts landed and the viewer rings it: a circle for a click, an outline around the focused field for typing and keys. Accessibility paths can avoid pointer movement; pointer and key fallbacks may temporarily borrow pointer or focus.
- **Note.** The latest `action.drive.note` shows along the bottom edge for about 12 seconds.
- **Snapshot.** `layer snapshot` / `layer_snapshot` writes a PNG from the latest frame: the subject's windows by default, one window with `windowId`, or the whole layer with `full`. Nothing is captured on request, so it answers in tens of milliseconds. `unchangedMs` is how long the layer has been still, not how stale the picture is.
- **Recording.** `layer record start|stop` / `layer_record` adds a recording output to the running stream, so the take starts on the next frame. It records the whole layer display at its native size. One take at a time; closing the layer finishes a take in progress.

## Operator controls

The viewer has a persistent hostname header and native controls outside the captured image:

- **Pause / Resume.** Pauses layer input dispatch. While paused, `state.json` has `"paused": true`; observations remain available. Resume is an operator action. Events or page scripts already dispatched cannot be undone.
- **Stop.** Pauses input, records a session-specific `handoff.json`, and ends the layer without activating the target app. This stops the layer session, not the agent's entire harness or unrelated work.
- **Agent.** Looks for the opener's app on this host. Action records its process chain at `open` (`--owner-pids`), activates the nearest app in that chain, and otherwise asks Lattices (`terminals.search`, then `window.focus`) which local terminal window shows it. If nothing resolves, the viewer beeps. This does not return from an SSH host to a conversation on another machine.
- **Take over.** Records a session-specific handoff, ends the layer, and activates the target app. Borrowed windows return to their recorded frames; windows created on the layer are closed, subject to unsaved-changes prompts. This is not an in-place remote-control mode.
- **Hide.** Hides only the viewer; the layer keeps running.

Stop and Take over refuse further agent input during teardown and after cleanup. `layer close` does not clear the handoff. A new explicit `layer open` acknowledges it; callers must obtain fresh user authorization before opening again. The prepared monitor remains connected after either action.

These are host-local controls. An interactive viewer streamed to another machine or into a chat is not implemented.

Requests go through `control.request.json` next to the state file and a `SIGUSR2`; the reply lands in `control.reply.json`.

## Lifetime

`layer_close` is the intended teardown. It creates the stop file and waits for the layer to put the windows back and exit. Windows that were opened after the layer went up (`born` in the state file) never sat on the user's screen, so they are closed instead of moved there. One that asks before closing (unsaved changes) stays open and goes back to the frame it appeared at. If the layer does not exit, Action sends `SIGTERM`.

This tears down the task's feed and window attachment, not the monitor.
`layer release` stops the persistent monitor owner only after its task has been
explicitly closed. It refuses active tasks and incoming previews without closing
them. Close dependent tasks first, then release their displays.

The layer also tears down when its owner dies:

- **MCP.** The layer watches the MCP server (`--parent-pid`) and restores the windows if the server exits.
- **CLI.** The CLI exits once the layer is up, so the layer is detached. Run `layer close` to take it down when the work is done.

A detached layer doesn't wait for `layer close` forever. It also comes down when:

- **Its owners exit.** Every process in the opener's chain that was alive at `open` has exited.
- **It goes idle.** 30 minutes pass with no act, no snapshot or recording request, and no use of the viewer. A recording in progress keeps the layer up. Pass `--idle-timeout <seconds>` to the host to change the lease; `0` turns it off.

Either way the windows go back first, as with `layer close`.

`layer status` reports the live layer. If the recorded process is gone, status removes the stale files and reports the layer as inactive.

Task and monitor state live in `~/Library/Application Support/Action/agent-layer/`.
Use `layer status` for the task and `layer display-status` for the monitor;
an inactive task with a ready monitor is the normal state between tasks.

## Requirements and limits

- The feed needs Screen Recording for Action. Without it the layer still works (windows move, blink acts land), but there is no viewer, snapshot or recording; the layer's `layer.log` says `feed failed`. Recording needs macOS 15.
- The display touches the bottom-right-most display only at its corner. A pointer pushed exactly through that corner can still cross onto it.
- A pointer blink click on another app activates that app for a moment before focus goes back. The menu bar can flicker for that moment.
- Blink acts refuse targets that aren't on an agent layer: a point off the layer, or an app with no window on it. `--any-display` lifts that for tests.
- Killing a task with `SIGKILL` skips its window restoration; the persistent monitor remains. Killing the monitor owner disconnects the display, allowing macOS to relocate its windows. Neither is an ordinary task teardown or a preservation guarantee.

## Native runtime

> How Action.app and the Action agent split native responsibilities

This page describes the runtime split that currently makes `action` behave like
a real macOS app instead of a command wrapper pretending to be one.

## The split

There are two native roles:

## `Action.app`

Owns:

- AppKit lifecycle
- menus and app-switcher behavior
- WebKit windows
- launcher UI
- permission UX
- recording probe execution

Main file:

- [ActionHostMain.swift](../native/engine/Sources/ActionHostMain.swift)

## Local agent runtime

`Action.app` starts the agent as a child helper,
`Contents/Helpers/ActionAgent.app`, on `ws://127.0.0.1:4319`. The helper exits
with its parent.

Owns:

- WebSocket transport
- automation-facing request handling
- local runtime methods
- bridge-friendly command orchestration

Main files:

- [ActionAgentRuntime.swift](../native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionAgentClient.swift](../native/engine/CoreSources/ActionAgentClient.swift)
- [ActionAgentCommandBridge.swift](../native/engine/Sources/ActionAgentCommandBridge.swift)

## Why this exists

Two important failures pushed the design here:

### 1. WebKit

WebKit behaved unreliably when UI modes were entered through the wrong runtime
path. The fix was to let AppKit own the UI lifecycle cleanly.

### 2. ScreenCaptureKit recording

Recording was not reliable when attempted inside the wrong lifecycle context.
The stable path now launches a fresh `Action.app` instance in `recording-probe`
mode for the actual capture work.

The lesson is simple:

**AppKit-dependent work should run inside a real app lifecycle.**

## Current execution flow

For normal operator usage:

1. `Action.app` launches
2. launcher UI comes up
3. local agent is started if needed
4. UI talks to the agent for runtime state and automation methods

For recording:

1. command or UI requests recording
2. host talks to the local agent
3. agent launches `Action.app` again in `recording-probe` mode
4. probe performs the actual `ScreenCaptureKit` recording
5. artifacts and finished markers are written

## Important boundaries

Keep these rules intact:

- do not move WebKit lifecycle back into a fake headless command path
- do not move recording implementation back into the plain headless agent path
- keep the agent useful for orchestration and transport
- keep AppKit-owned concerns in the app process

## Private-layer discovery

Use `action capabilities` and the active MCP `capabilities` / `tools/list`
for build provenance and routing. Check host quarantine before opening a private
display. Native support, runtime health, and version strings do not establish
physical desktop preservation. See [Agent layer](/action/docs/agent-layer).

`native:doctor` builds and signs. Run it on an authorized development host.
On an installation target, preserve the installed bundle and rollback; deploy
a matched app and MCP runtime instead of rebuilding implicitly. Reconnect MCP
after runtime changes.

To assemble a matched runtime candidate on the development host, use:

```bash
bun scripts/package-agent-runtime.ts --app /path/Action.app --output /new/action-runtime --instructions-root /path/to/lattices-docs-checkout
```

The command verifies the signed app's recorded MCP source fingerprint, bundles
the source and locked production dependencies, and includes the selected layer
docs and Action skill. It rejects a mismatched pair or existing output and does
not install anything. `runtime-provenance.json` records the artifact identities
and marks host desktop-isolation acceptance as uncertified. Keep the previous
runtime for rollback and preserve host quarantine when installing a candidate.

The extracted archive contains sibling `bin/` and `products/` directories.
Set `ACTION_ROOT=<extract>/products/action`, not the extraction root, and keep
`bin/host-pairing.ts` in place; the runtime imports that canonical dependency.

## Scripts and helpers

Call native work through package.json scripts from `products/action`:

```bash
bun run native:app:build
bun run native:doctor
bun run native:launch
bun run native:relaunch
bun run native:host -- status
bun run native:test:screenshot
bun run native:test:record
```

The scripts wrap helpers in [native/engine/scripts](../native/engine/scripts). The most important wrappers are:

- `build-app.sh`
- `doctor.sh`
- `run-app-host.sh`
- `test-screenshot.sh`
- `test-record.sh`

## Recording

> How Action records a window or region and signals completion

Recording is the most important runtime path in this project.

This page documents how it currently works and what assumptions should remain
true while the product is still being hardened.

## What is stable now

The native recording path now succeeds for:

- bounded region recording
- app-window recording

The successful path produces:

- a `.mov` file
- a `.finished` marker file
- an optional debug log if `--debug-log` is supplied

## The key discovery

The main recording bug was not just a bad capture configuration.

The deeper issue was lifecycle ownership:

- `ScreenCaptureKit` recording was unreliable or crash-prone when hosted from the
  wrong runtime path
- a minimal real AppKit app lifecycle succeeded with the same capture logic

That is why the current solution uses a dedicated `recording-probe` mode inside
`Action.app`.

## Current recording path

For a region recording request:

1. host command accepts the request
2. host sends a recording method to the local agent
3. agent launches `Action.app` with `recording-probe`
4. probe runner creates a tiny AppKit window and starts recording
5. recording continues until the stop file appears
6. probe writes the finished marker and exits

Core files:

- [ActionRecordingProbeLauncher.swift](../native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- [RecordingProbeAppRunner.swift](../native/engine/Sources/RecordingProbeAppRunner.swift)
- [ActionHostMain.swift](../native/engine/Sources/ActionHostMain.swift)

## Testing recording

The wrapper script is:

```bash
bun run native:test:record
```

For lower-level testing, `run-app-host.sh` can call recording commands
directly.

## Important caveat

The initial CLI reply usually means:

`recording started successfully`

It does **not** mean:

`recording completed successfully`

Completion is represented by the finished marker file.

## What to preserve

- real AppKit lifecycle for actual recording work
- stop-file and finished-file based orchestration
- debug-log passthrough for probe runs
- clean app/agent separation even if the app is doing the final recording work

## What to avoid

- pushing real recording back into a plain headless lifecycle
- assuming a WebSocket ack is equivalent to a completed recording
- removing the probe path before a better lifecycle-safe replacement exists

## Stage

> Present listed windows on a flat backdrop for a clean take

Action owns the look of a take. The wallpaper is never written.

`action.stage.set` is the primitive: declare the world, Action makes it so.

```json
{
  "mode": "drape",
  "color": "0e0d0a",
  "subjects": [
    { "bundleId": "to.talkie.agent.dev", "title": "Settings" },
    { "bundleId": "com.googlecode.iterm2" }
  ]
}
```

## What it does

- Puts up a flat color sheet at ordinary window level (`NSWindow.Level.normal`).
- `AXRaise`s only the listed windows. Same level is what lets them sit on the sheet.
- Reads on-screen window order in the staged bounds (or the sheet's frames). The scene is the listed subjects on the sheet. Anything else above the sheet, including the driver terminal, is an intruder unless it was listed.
- Fails `stage.set` if a listed subject is still buried or a non-subject occupies the scene. It raises again a couple of times before refusing. The sheet stays up so `stage.status` can show who is actually on top.
- Leaves every other app alone. No hiding. No desktop-picture writes.
- Dies with the process that asked for it. `action.stage.clear` takes it down on purpose.

## Lifetime

`action.stage.clear` is the intended teardown. Two backstops cover the case where it never runs:

- **Owner.** A drape set through MCP watches the MCP server and dismisses itself if that server dies. A drape set through the CLI cannot do this: the CLI process exits the moment the sheet is up, so a drape watching it would take itself down immediately. CLI drapes are detached.
- **`seconds`.** An optional lifetime after which the drape dismisses itself. The CLI defaults to 1800; pass `--seconds` to change it. MCP omits it by default because the owner check already covers a dead server.

`stage status` reports `owner`, `pid`, whether the drape is still up, and `scene`: the windows actually on top of the sheet.

`mode: "space"` keeps the sheet on the current Space only. Instantiate subjects on that Space; windows on other Spaces will not compose into the frame.

`level: "desktop"` is the other sheet in the repertoire. It sits under all app windows and is the wrong default for a take.

## Surfaces

- MCP: `action.stage.set`, `action.stage.clear`, `action.stage.status`
- CLI: `bun packages/cli/src/main.ts stage set|clear|status`

To work an app out of the user's sight instead of staging it for a take, see [Agent layer](/action/docs/agent-layer).

## Skills

> Review patterns an AI agent follows when changing Action

These are project-specific skills or task patterns an AI agent should follow.

## Native runtime review

Use when:

- changing AppKit lifecycle code
- changing agent startup or bridge logic
- changing WebKit entry paths

Instructions:

1. read [Native runtime](/action/docs/native-runtime)
2. verify whether the change belongs in app code or agent code
3. keep AppKit-owned behavior in `Action.app`
4. verify the signed app still builds

## Recording review

Use when:

- changing `ScreenCaptureKit` recording
- changing stop-file or finished-file handling
- changing probe launch behavior

Instructions:

1. read [Recording](/action/docs/recording)
2. inspect the probe launcher and probe app runner
3. preserve `.mov` + `.finished` behavior
4. test a real recording path, not just a unit-level refactor

## Agent API review

Use when:

- adding WebSocket methods
- changing request or response shape
- updating CLI-to-agent behavior

Instructions:

1. read [Api](/action/docs/api)
2. update the protocol source of truth
3. confirm method names remain documented
4. verify callers still match the transport contract

## Hermes Action

Use when:

- connecting Hermes to the native Action runtime
- using Action MCP tools from a harness
- recording or inspecting native macOS surfaces through Hermes

Instructions:

1. read [docs/harnesses/hermes-action.md](harnesses/hermes-action.md)
2. use [skills/hermes-action/SKILL.md](../skills/hermes-action/SKILL.md) as the harness doctrine
3. prefer observe and resolve before act
4. treat recording start as asynchronous until `.finished` or `action.record.status` confirms completion

## Overview

> What Action is, what it installs, and how it relates to Lattices

Action is a native macOS app that lets agents inspect and control Mac apps and
browser surfaces, and record what they did. It is a separate product in the
Lattices family. It has its own signed `Action.app`, its own local agent, its
own release tags (`action-vX.Y.Z`), and its own lifecycle.

## What Action does

| Job | Surfaces |
| --- | --- |
| Inspect | Screenshots, accessibility trees, Apple Vision OCR, optional provider vision |
| Control | Target resolution, clicks, typing, key chords, drags, scrolls, focus, app launch |
| Record | ScreenCaptureKit video of a window or region, plus session traces and artifacts |
| Stage | A flat backdrop behind listed windows for a clean take (see [Stage](/action/docs/stage)) |
| Work out of sight | A private virtual display for an app or Action-owned browser (see [Agent layer](/action/docs/agent-layer)) |

## What gets installed

| Part | Where | Purpose |
| --- | --- | --- |
| `Action.app` | `/Applications/Action.app` (bundle id `dev.lattices.Action`) | AppKit lifecycle, menus, WebKit, permission UI, recording probes |
| Action agent | `Action.app/Contents/Helpers/ActionAgent.app`, `ws://127.0.0.1:4319` | Local WebSocket RPC for native requests and drive leases |
| Agent runtime | A runtime bundle or a `products/action` checkout | TypeScript runtime, product CLI, and the Action MCP server |

`action install` installs the app only. The app alone does not include MCP
orchestration. To connect an agent over MCP, install the matching runtime as
described in [Agent setup](/action/docs/agent-setup).

## How Action relates to Lattices

Lattices 0.15.1 owns workspace organization on `lattices.sock`. Action 0.4.0
owns native computer use on `action.sock`. Both sockets are in
`~/.lattices/run`. Quitting one app does not stop the other. Remote access goes only through the opt-in Lattices gateway. See
[API](/action/docs/api#private-connection).

Action has its own CLI, `action`, from `@lattices/action`. It installs,
launches, quits, and queries Action, drives apps through its computer-use
backends, and forwards other verbs to the Action runtime CLI. `lats action`
remains as the Lattices family entry point. Two
nearby commands do not reach Action:

- `lats cua` (alias `lats computer`) calls the core daemon's `cua.*` methods. See the
  [Lattices API](/lattices/docs/api).
- `lats mcp` serves the `browser_*` tools that drive Action-owned Chrome
  profiles over CDP. That server is part of the Lattices CLI, not Action.app.
  See [Browser](/action/docs/browser) and the [Lattices MCP](/lattices/docs/mcp).

[Concepts](/action/docs/concepts) has the full command-to-process table.

## Platforms

Action.app runs on macOS. There is no Linux build of Action.app. The Action
runtime can drive a Linux desktop that runs `lattices-host`. See
[Remote engine](/action/docs/remote-engine).

## Next steps

- [Getting started](/action/docs/getting-started): install, launch, and check the app.
- [Agent setup](/action/docs/agent-setup): connect an MCP agent to a matched runtime.
- [Concepts](/action/docs/concepts): processes, ports, sessions, and leases.
- [API](/action/docs/api): the agent WebSocket protocol.

## ARCHITECTURE

# Architecture

`action` is a ground-up rewrite for agentic macOS demo automation.

It exists because `vif` and `stage` both produced valuable learnings, but neither is the right long-term core:

- `vif` proved there is real value in combining capture, browser/app automation, overlays, audio, and export.
- `stage` proved the architecture should be cleaner, more session-oriented, and more explicit about primitives.
- Both also showed a failure mode: if the scene format, CLI behavior, and runtime lifecycle get tangled together, the tool becomes hard to reason about and easy to break.

The central architectural decision for `action` is:

**The runtime is the product. The scene format is a compiled input, not the architecture.**

Another useful way to say the same thing:

**`action` is an action runtime that can observe, act, reflect, and record.**

## Goals

- Provide a deterministic, session-based runtime for observing apps and browsers, resolving targets, executing actions, reflecting on what happened, and recording structured traces.
- Support agent-authored demo and promo workflows without relying on hidden heuristics or magical state.
- Separate live automation from final composition so polished output can improve without destabilizing the runtime.
- Lean fully into macOS-native fidelity instead of designing for fake cross-platform flexibility.

## Non-Goals

- Not a generic automation framework for every operating system
- Not an Electron-first runtime
- Not a GUI editor in v0
- Not a vision-only “click whatever looks right” system
- Not a scene DSL that owns business logic and runtime state
- Not a VM/container-first automation stack for host UI, browser, or capture
  work

## Core Layers

`action` should be implemented as a small number of strict layers.

### 1. Native Engine

Swift-based macOS engine responsible for:

- ScreenCaptureKit capture
- Accessibility inspection
- Input synthesis
- Window enumeration and positioning
- Overlay windows when needed during live capture
- Audio session and telemetry primitives

The engine should be treated as a capability provider, not the place where product workflows live.

The native layer should be split into separate processes:

- `Action.app`: normal AppKit lifecycle, WebKit, menus, settings, permissions UX
- `ActionAgent`: headless local service exposing WebSocket and local IPC surfaces
- `ActionCLI`: thin operational client that talks to the agent, not directly to UI

This separation is not optional. UI lifecycle and agent lifecycle have different
constraints, and combining them leads to brittle behavior.

### Remote Workers

Remote VMs and containers can still be useful for auxiliary work such as
isolated command execution, rendering, browser-free tests, or heavyweight model
jobs. They should not own the core Action browser, Accessibility, AppKit, or
ScreenCaptureKit paths because those capabilities depend on the user's macOS
host, permissions, windows, and dedicated local Chrome profiles.

### 2. Runtime

The runtime is the heart of the system. It owns:

- session creation and teardown
- lifecycle transitions
- current surfaces and active targets
- observations and resolution logic
- action execution
- reflection and inspection workflows
- traces and artifacts

All mutable run state belongs to a concrete session. Avoid hidden globals and avoid lifecycle behavior that relies on shell cleanup or broad process-kill patterns.

### 3. Compiler

The compiler converts author intent into an executable timeline.

It should:

- validate scene/input structure
- normalize high-level user intent into explicit runtime actions
- attach fallbacks and preconditions
- separate narrative cues from execution steps
- produce an inspectable timeline before execution

The compiler should eventually support more than one input source:

- hand-authored scenario intent
- recorded runtime traces converted into scenario drafts

This matters because one of the most valuable workflows is likely to be:

1. a user demonstrates a flow manually
2. the runtime captures media plus trace
3. `action` derives a reusable scenario from that run
4. the system reruns or polishes it later

### 4. Composer

Composition is a separate phase from capture and execution.

The composer should:

- transform raw captures and runtime traces into a render manifest
- infer or apply zooms, cursor polish, subtitles, callouts, chapter cards, and audio timing
- delegate actual rendering to a backend such as Remotion

This separation is essential. Styling, transitions, and branding should be able to evolve independently from action execution.

The composer should not own live app control, session lifecycle, or target
resolution. It is post-capture orchestration, not the runtime.

### 5. Frontends

Frontends must stay thin.

- CLI: operational control and local authoring workflows
- MCP: agent-facing execution surface
- TS HUD: richer operator console for logs, diagnostics, artifacts, scenario control, and reflection output
- native HUD: minimal always-on capture companion tied closely to runtime truth and immediate controls

They should call the same runtime interfaces, not implement separate behavior.

The HUD split should be deliberate:

- the native HUD should stay minimal and capture-adjacent
- the TS HUD can carry more product richness and operator affordances
- neither HUD should become the owner of runtime truth
- if a HUD is on screen during a live session, it should expose explicit controls instead of acting like passive decoration

## Core Primitives

`action` should keep its vocabulary small and stable.

### Session

One automation run with:

- stable id
- explicit lifecycle
- owned resources
- trace output
- artifact list

Suggested lifecycle:

- `created`
- `preflight`
- `ready`
- `running`
- `paused`
- `completing`
- `completed`
- `failed`
- `cancelled`

### Surface

A place where the runtime can observe or act.

Examples:

- desktop
- app window
- browser tab
- bounded region

### Observation

A typed fact gathered from the engine or browser adapter.

Examples:

- window bounds
- DOM node snapshot
- AX element
- cursor position
- recording state
- audio level

### Reflection

A structured interpretation of current state or recent action.

Examples:

- UI critique from a model provider
- QA finding attached to a screenshot
- target suggestion derived from vision plus AX context
- operator-facing summary of what changed after an action

Reflection is not the same thing as raw observation.

- observations are facts gathered from the system
- reflections are interpretations produced from those facts

The runtime should own reflection sessions, prompts, findings, and artifacts, but
provider-specific model clients should stay outside the native engine. See
[LIVE_INSPECTION_RUNTIME.md](docs/LIVE_INSPECTION_RUNTIME.md).

### Target

A stable reference to something actionable.

Target resolution should support:

- semantic ids
- AX/DOM-based resolution
- bounded text/role matching
- calibrated anchors
- coordinates as last resort

### Action

A deterministic atomic operation.

Examples:

- click
- type
- press key
- focus window
- open app
- start recording
- stop recording
- show cue
- wait for condition

### Cue

A narrative or editorial element that matters to the viewer.

Examples:

- label
- chapter marker
- subtitle
- callout
- caption

### Effect

A render-time presentation element, not necessarily a live overlay.

Examples:

- auto zoom
- smart reframe
- cursor emphasis
- background dimming
- click pulse
- transition

### Artifact

Anything the run produces.

Examples:

- screenshot
- raw capture
- trace log
- focus metadata
- subtitle file
- final rendered video

## Target Resolution

Target picking is a v0 feature, not a nice-to-have.

The system must not normalize blind coordinate clicking as the default interaction model.

Recommended resolution order:

1. semantic target
2. exact accessibility or DOM match
3. bounded fuzzy text/role match
4. calibrated anchor
5. coordinate fallback

Recommended API shape:

- `observe()`
- `target.resolve(query, context)`
- `act(action, target)`

And the resolver must be conservative:

- return confidence
- return ambiguity explicitly
- avoid guessing when multiple candidates are plausible
- allow human or agent inspection before acting

## Execution Model

There are two major phases.

### Live Phase

The runtime:

- prepares the environment
- resolves targets
- executes actions
- captures raw media
- records metadata and trace events

### Compose Phase

The composer:

- consumes raw media and trace data
- computes polish such as zooms and cursor motion
- aligns narration, subtitles, music, and chapter cues
- renders exports via a backend

This split is a hard requirement. It keeps the runtime reliable and the output quality flexible.

## Scene Model

Scenes should describe intent, not be forced to contain all operational detail.

Good scenes should express:

- goal
- context
- surfaces
- targets
- sequence
- narration
- style
- export preferences

The compiler should lower those into an executable timeline with explicit dependencies and fallbacks.

## Render Backend Boundary

`action` should define its own render manifest and allow multiple composition backends.

Near-term plan:

- `composer-core`: manifest schema and transformation logic
- `composer-remotion`: first production backend

This allows `action` to borrow high-quality composition capabilities from tools like Remotion without turning React video rendering into the core product architecture.

## Operational Design Rules

- No daemon mystery states
- No hidden global runtime state
- No broad shell cleanup as the main lifecycle mechanism
- No UI-only source of truth
- No premature cross-platform abstraction
- No scene format that bypasses runtime primitives

## Proposed Package Boundaries

- `packages/protocol`
- `packages/runtime`
- `packages/compiler`
- `packages/composer-core`
- `packages/composer-remotion`
- `packages/cli`
- `packages/mcp`
- `native/engine`

## v0 Definition of Done

`action` v0 should feel solid before it feels broad.

That means:

- explicit session lifecycle
- reliable target resolution
- deterministic action execution
- raw capture plus trace metadata
- polished but backend-driven composition
- clean CLI and MCP surfaces

If v0 cannot reliably observe, resolve, act, record, and compose a basic feature demo on macOS, it is not done.

## AX_BACKGROUND_AUTOMATION

# AX Background Automation

Action should treat macOS Accessibility as the default path for host-native
automation.

The product goal is not to create a second hardware cursor. The goal is to act
through semantic app surfaces while presenting a visual cursor/caret overlay
that explains what is happening.

## Model

For a target app, Action should prefer:

1. read the AX tree
2. resolve a specific element
3. use semantic AX actions or settable attributes
4. show a non-interactive overlay describing the action
5. verify by reading AX state again

The overlay is presentation only. It must not be treated as the input channel.

## Action Ladder

Use the least attention-taking primitive that can complete the task:

1. `observe`: AX tree, window bounds, screenshot.
2. `semantic`: `AXPress`, `AXShowMenu`, set `AXValue`, set `AXSelectedText`.
3. `target-focus`: set `AXFocused`, then send direct app/process events if the
   app requires a focused control.
4. `app-api`: Chrome DevTools Protocol, AppleScript, Shortcuts, or app-specific
   APIs when they are more deterministic than generic AX.
5. `attention`: activate/raise an app, system hotkeys, pointer warping, or HID
   events.

The runtime should record which tier was used for every action.

## Warning Policy

`observe` and `semantic` actions can run silently with the top-right trace.

`target-focus` actions should show a subtle amber notice:

> Target focus may change inside {app}.

`attention` actions should require an explicit, visible warning before execution:

> Action needs foreground control of {app} and may move focus or the pointer.

The user should be able to cancel or defer attention-taking actions.

## Current Daily App Findings

Use:

```bash
bun run native:ax:audit
```

The audit is read-only. It snapshots AX nodes for daily apps and reports:

- roles
- available AX actions
- settable attributes
- pressable elements
- text-like writable controls
- whether the frontmost app changed during the audit

Early local findings:

- Chrome exposes many `AXPress` controls and an `AXTextField` for the omnibox.
- iTerm exposes titlebar/search controls plus a large terminal `AXTextArea`.
- Codex currently exposes a coarse Electron shell: mostly groups and titlebar
  buttons, not a rich editor/input AX tree in this sample.
- Cursor should be audited when running; the script intentionally does not
  launch apps because launching can itself become attention-taking behavior.

## CAPTURE_CONTROLS_PRECEDENT

# Capture Controls Precedent

## Keep

- a countdown that is obvious before capture starts
- controls that stay reachable while the take is live
- runtime-owned truth for recording state and interruption

## Avoid

- a HUD that shows buttons without a real control path behind them
- fake pause states when native capture is not actually paused
- interruption paths that leave recording hanging without a stop marker

## Adapt

- use the native stage HUD as the immediate operator surface
- keep the control channel file-based so the overlay and runner stay loosely coupled
- treat interrupt as a clean stop/cancel path instead of pretending the take can be paused safely

## Decision

- the guided native session will surface countdown skip/cancel before capture starts
- the live take will surface an interrupt control that stops recording cleanly
- cancelled runs will report cancellation explicitly instead of pretending they completed

## Reference Weight

Blend of `vif` product feel and `stage` runtime-boundary discipline.

## COMPOSITION_AND_SCENARIOS

# Composition And Scenarios

## Purpose

This document explains what "composition" means in `action`, and how it relates
to agentic automation, manual capture, and reusable scenarios.

The key point is simple:

**Composition happens after capture.**

It is not the runtime. It is not the session controller. It is not the source of
truth for what happened.

## Core Idea

`action` should separate three concerns:

1. live interaction and capture
2. scenario representation
3. final presentation

Those are related, but they should not be fused into one system.

### Live Interaction And Capture

This is the runtime phase.

It includes:

- observing windows, surfaces, and targets
- acting through clicks, typing, focus changes, and waits
- recording video and screenshots
- collecting structured traces

This is where truth is created.

### Scenario Representation

A scenario is a reusable, inspectable description of what should happen.

It may be authored:

- directly by a human
- directly by an agent
- derived from a recorded session
- derived from a hybrid of user actions plus later cleanup

This is where intent is organized.

### Final Presentation

This is the composition phase.

It includes:

- zooms
- reframing
- cursor emphasis
- chapter cards
- subtitles
- narration timing
- music
- transitions

This is where polish is applied.

## What Composer-Core Should Mean

`composer-core` should be a narrow package.

It should own:

- render-manifest types
- composition-friendly timing structures
- focus-window descriptions
- chapter and subtitle placement data
- effect definitions that can be consumed by a renderer

It should not own:

- live app control
- target resolution
- session lifecycle
- capture start/stop
- HUD control
- input synthesis

That means `composer-core` is not "the video editor." It is the contract between
the runtime's artifacts and a rendering backend such as Remotion.

## Agentic First Still Holds

This architecture is still agentic first.

The agent-facing value comes from:

- stable targets
- deterministic runs
- inspectable traces
- reusable scenarios

The important shift is that the agent should not be forced to author everything
up front.

There are at least three valid ways to create a scenario.

## Three Scenario Sources

### 1. Authored Scenario

A human or agent writes the intended sequence before execution.

Example:

- open Calculator
- type `12`
- click `+`
- type `30`
- press `=`

This is the most direct "agentic automation" mode.

### 2. Recorded Session

A human drives the product manually while `action` records:

- video
- focus changes
- target resolutions
- clicks
- keys
- timing
- window state

Later, `action` can convert that into a structured scenario draft.

This is the mode you were pointing at: a user navigates a website or UI, and the
system turns the observed session into something reusable.

### 3. Hybrid Scenario

The user records an initial pass, and then the system or agent cleans it up:

- replace weak coordinate clicks with semantic targets
- remove dead time
- add preconditions
- normalize waits
- insert cues

This is likely one of the strongest long-term workflows for `action`.

## Why Recorded Sessions Matter

Recorded sessions solve a real product problem.

Many users know how to show the flow they want, but they do not want to author a
scene format from scratch.

If `action` can observe a manual run and convert it into a scenario draft, then:

- onboarding becomes much easier
- the runtime captures real truth from the product
- agents get a better starting point than a blank file
- deterministic reruns become possible after the initial demonstration

This is one of the most compelling directions in the product.

## Proposed Pipeline

The long-term pipeline should look like this:

1. run a live session
2. capture media plus trace
3. derive or refine a scenario from the trace
4. replay or rerun that scenario deterministically
5. compose a polished export from the captured or rerun artifacts

In short:

`capture -> trace -> scenario -> rerun -> compose`

Not every workflow needs every step, but this is the most powerful full loop.

## Trace-To-Scenario

The compiler should not only accept hand-authored scene input.

It should also eventually accept recorded traces as source material.

That implies two compiler inputs:

- `intent -> timeline`
- `trace -> scenario draft -> timeline`

The second path is important because it lets `action` learn from a real user-run
session without turning the runtime into a scene DSL.

## What The Trace Must Preserve

If we want recorded sessions to become reusable scenarios later, the trace needs
to preserve enough structure now.

That includes:

- window and surface identity
- target query and resolution result
- confidence levels
- click positions
- key presses and text entry
- timing boundaries
- state transitions
- artifacts created during the run

This is another reason the runtime matters more than the scene format.

## What Composition Consumes

The composition layer should consume:

- raw video capture
- screenshots
- runtime trace
- viewport and focus metadata
- cues or chapters
- optional voice and music timing

It should then produce:

- a render manifest
- renderer-specific instructions
- final output artifacts

## A Practical Product Reading

A useful way to think about `action` is:

- the runtime is the camera operator and automation system
- the trace is the shooting log
- the scenario is the shot list or repeatable script
- the composer is post-production

That framing keeps the architecture honest.

## Implication For Early Milestones

The first milestone should focus on capture and trace, not polished composition.

That is why the guided capture loop is the right first implementation target.

Once that exists, the system can support:

- direct deterministic demos
- manual guided recordings
- trace-derived scenario drafts
- polished exports later

## COMPUTER_USE_AGENT

# Computer Use Agent — Action Spec

## Context

`action` today is a guided demo workstation: it stages scenes, records sessions, and produces artifacts for post-production. The agent runtime (`ActionAgentRuntime`) handles WebSocket transport and dispatches a small set of deterministic actions (click, type, press-key, drag, recording).

A computer use agent requires a different loop: **observe → think → act → repeat** with autonomous goal pursuit, ongoing perception, and a much wider action surface.

This document describes the gap and the changes needed to close it.

---

## 1. Current State

### What Exists

| Layer | What | Limitation |
|-------|------|------------|
| **Actions** | `click`, `type`, `press-key`, `drag`, `start/stop-recording`, `show-cue`, `wait-for-condition` | No scroll, no context menu, no hotkey combos beyond simple modifiers |
| **Target Resolution** | `semantic`, `accessibility`, `dom`, `textual`, `anchor`, `coordinate` | Resolution is one-shot; no ongoing observation |
| **Perception** | Screenshots on demand, AX snapshots, recording | No continuous frame stream; perception is pull-only |
| **Agent Loop** | None | Session is scripted/guided; no autonomous iteration |
| **Memory** | Trace + artifact persistence only | No working memory, no context accumulation across steps |
| **Tool Surface** | `CaptureEngine` interface | Not exposed as agent tools; no tool-call protocol |

### What Is Missing for Computer Use

- Continuous screen observation (video stream or periodic frames)
- Rich element interaction (scroll, hover, context menu, double-click, text selection)
- Autonomous goal decomposition and retry
- Working memory and context carry-across
- Mouse cursor control with smooth motion
- Key sequences and system hotkeys
- Clipboard access (read/write)
- File system operations
- Process and window management
- Natural language instruction parsing
- Self-correction on failure

---

## 2. Perception Layer

### 2.1 Continuous Frame Stream

Today: screenshots are captured on demand via `captureScreenshot`.

Computer use requires: a periodic frame grab (e.g., every 1–2 seconds) that feeds the agent's vision input.

**Changes:**

- Add a `FrameStream` service in the native layer
  - Captures `CGImage` frames at a configurable interval (default: 1fps)
  - Pushes frames to the agent runtime via WebSocket or a shared buffer
  - Supports pause/resume so the agent only pays for frames when active
- Add `startVisionStream()` / `stopVisionStream()` to `CaptureEngine`
- Frames are small JPEG thumbnails at ~720p for token efficiency

### 2.2 Accessibility Tree Persistence

Today: AX snapshots are taken as discrete artifacts.

Computer use requires: a live, queryable AX tree that the agent can re-query on every step without re-capturing the whole screen.

**Changes:**

- Add an `AccessibilityMonitor` that polls AX tree every ~500ms when active
- Cache the tree in the agent runtime
- Provide `queryAccessibleElement(query: TargetQuery)` method that hits the cache first
- Fall back to a fresh AX snapshot only when the cache is stale (>2s) or query misses

### 2.3 Cursor and Surface Tracking

**Changes:**

- Add `cursorPosition()` to report current mouse coordinates in real time
- Add `activeWindowInfo()` to report frontmost app, window title, and bounds
- These feed into the agent's observation payload on each step

---

## 3. Action Surface Expansion

### 3.1 Interaction Actions

Add these to `ActionKind` in the protocol:

| New Action | Description |
|------------|-------------|
| `scroll` | Scroll a target or the active surface by a delta |
| `double-click` | Double-click at a point or on a target |
| `right-click` | Context menu at a point or on a target |
| `hover` | Move mouse to a point without clicking |
| `text-select` | Select text in a text field or document |
| `text-copy` | Copy selected text to clipboard |
| `text-paste` | Paste clipboard contents |
| `screenshot` | One-off screenshot |

### 3.2 System Actions

| New Action | Description |
|------------|-------------|
| `open-url` | Open a URL in the default browser |
| `open-file` | Open a file with its default application |
| `launch-app` | Launch an application by bundle ID or name |
| `quit-app` | Quit an application |
| `focus-app` | Bring an app's window to front |
| `get-clipboard` | Read current clipboard contents |
| `set-clipboard` | Write text to clipboard |
| `run-shell-command` | Execute a shell command and return output |

### 3.3 Interaction Execution

The existing `executeInteractionAction` in `packages/runtime/src/interaction/index.ts` handles the current action set via `runHost` calls to CLI commands. This pattern should be extended:

```
Action → InteractionExecutor → HostCLI
                         ↘ NativeAutomationBridge (for AX-dependent actions)
```

For `scroll`, `double-click`, `right-click`, `hover`: new host CLI commands.

For `get-clipboard` / `set-clipboard`: native macOS `NSPasteboard` calls.

For `focus-app`, `launch-app`, `quit-app`: `NSRunningApplication` and `NSWorkspace`.

### 3.4 Mouse Motion Path

Today `click-point` snaps the cursor. For computer use with UI agents:

- Add `move-to` command with optional duration for smooth motion
- Use `CGEvent` posting with `kCGHIDEventTap` for smooth cursor movement
- Configurable speed (fast for demos, slow for screen recording legibility)

---

## 4. Agent Loop

### 4.1 Cycle Architecture

```
AgentRuntime
  ↕ vision frames + AX tree
  Agent Loop (external or embedded)
  ↕ tool calls
  CaptureEngine
  ↕ AX + CGEvent
  Action.app / Native Layer
```

The agent loop itself can live:
- **Embedded** in `ActionAgentRuntime.swift` — simple, synchronous loop
- **External** via WebSocket RPC — the agent runs in a separate process (safer isolation)

Option B (external) is preferred: it keeps the native app lifecycle clean and allows the agent to be upgraded without rebuilding Action.app.

### 4.2 Tool Call Protocol

Add a `tools.list` and `tools.call` RPC surface to the WebSocket interface:

```typescript
// Request: list tools
{ "method": "tools.list" }

// Response:
{ "tools": [
  { "name": "screenshot", "description": "...", "parameters": {...} },
  { "name": "click", "description": "...", "parameters": {...} },
  ...
]}

// Request: call tool
{ "method": "tools.call", "params": { "name": "click", "args": { "target": {...} } } }

// Response:
{ "success": true, "result": {...} }
// or
{ "success": false, "error": "..." }
```

### 4.3 Observation Payload

On each loop iteration, the agent receives:

```typescript
interface AgentObservation {
  frame: string;           // base64 JPEG thumbnail
  axTree: AXNode[];         // cached accessibility tree
  cursorPosition: Point;
  activeWindow: SurfaceRef;
  recentActions: ActionTrace[];  // last 5 actions + outcomes
  sessionHistory: ActionTrace[]; // full history
}
```

### 4.4 Self-Correction

When an action fails (AX element not found, app not responding):

1. Increment failure counter on the step
2. Retry with relaxed target (e.g., fall back to coordinate click)
3. After 2 retries, mark step as `failed` and report to agent
4. Agent decides whether to skip, substitute, or abort

---

## 5. Memory and Context

### 5.1 Working Memory

Add a `MemoryStore` to the protocol:

```typescript
interface MemoryEntry {
  key: string;
  value: string;
  ttlMs?: number;
}

interface MemoryStore {
  set(entry: MemoryEntry): void;
  get(key: string): string | undefined;
  delete(key: string): void;
  clear(): void;
}
```

Use cases:
- Remember the last button clicked so the agent can say "I clicked the submit button"
- Store intermediate task results (e.g., "found the settings menu")
- Carry context across steps (e.g., "we are in the Safari preferences pane")

### 5.2 Session Context Carry-Over

Currently each session is stateless. For computer use:

- Add a `session.context: Record<string, unknown>` field
- The agent can write/read this across the session lifetime
- Context is persisted to `manifest.json` so interrupted sessions can resume

---

## 6. Native Layer Changes

### 6.1 ActionHostMain.swift

- Add a `handleToolCall(method: String, args: [String: Any]) -> Any?` entry point
- Route `tools.call` to the appropriate native handler or forward to `ActionAgentRuntime`

### 6.2 AccessibilityMonitor

New Swift class that:
- Creates an `AXUIElement` for the systemwide accessibility observer
- Polls at a configurable interval
- Returns a serialized AX tree as JSON

### 6.3 FrameStreamService

New Swift class that:
- Uses `CGDisplayStream` or periodic `CGWindowListCreateImage` to capture frames
- Compresses to JPEG and pushes via a delegate or notification

### 6.4 AutomationBridge

Refactor `ActionAgentCommandBridge.swift` to expose a cleaner `AutomationBridge` interface:

```swift
protocol AutomationBridge {
    func click(at point: CGPoint) async throws
    func type(text: String, delayMs: Int?) async throws
    func scroll(delta: CGPoint, in bounds: CGRect?) async throws
    func getClipboard() async throws -> String?
    func setClipboard(text: String) async throws
    func getCursorPosition() -> CGPoint
    func getFrontmostApp() async throws -> AppInfo
    func launchApp(bundleId: String) async throws
    func quitApp(bundleId: String) async throws
}
```

This protocol is implemented in `Action.app` (AppKit context) and called from the agent via XPC or direct Swift invocation.

---

## 7. Protocol Changes

### 7.1 New `ActionKind` values

```typescript
export type ActionKind =
  | "click"
  | "type"
  | "press-key"
  | "focus-window"
  | "open-app"
  | "drag"
  | "start-recording"
  | "stop-recording"
  | "show-cue"
  | "wait-for-condition"
  | "scroll"           // NEW
  | "double-click"      // NEW
  | "right-click"       // NEW
  | "hover"            // NEW
  | "text-select"      // NEW
  | "text-copy"        // NEW
  | "text-paste"       // NEW
  | "open-url"         // NEW
  | "open-file"        // NEW
  | "quit-app"         // NEW
  | "get-clipboard"    // NEW
  | "set-clipboard"    // NEW
  | "run-shell-command" // NEW
  | "screenshot";      // NEW (rename from captureScreenshot alias)
```

### 7.2 New `RuntimeAction.input` fields

```typescript
// scroll
{ "deltaX": number, "deltaY": number, "targetId"?: string }

// double-click / right-click
{ "point"?: Point, "targetId"?: string }

// hover
{ "point": Point }

// text-select
{ "start": number, "end": number, "targetId": string }

// open-url
{ "url": string }

// open-file
{ "path": string }

// quit-app
{ "bundleId": string }

// run-shell-command
{ "command": string, "timeoutMs"?: number }

// get-clipboard / set-clipboard
{ "text": string }  // for set-clipboard
// get-clipboard has no input
```

### 7.3 New `SurfaceRef` kinds

```typescript
// Extend SurfaceRef
{ id: string; kind: "desktop" | "window" | "browser-tab" | "region" | "menu" | "dialog"; label: string; bounds?: Bounds }
```

---

## 8. Agent-External vs Agent-Embedded

Two integration strategies:

### Option A: Embedded Agent Loop

The agent logic runs inside `ActionAgentRuntime.swift`, called via WebSocket messages from an external orchestrator.

- **Pros**: Simple IPC, shared memory
- **Cons**: Agent code is coupled to the app; hard to update agent independently

### Option B: External Agent (Recommended)

A separate agent process (Node.js, Python, or custom) connects to `ActionAgentRuntime` via WebSocket as a client. The agent sends `tools.call` messages and receives observation payloads.

- **Pros**: Agent can be updated independently; agent can run on a different machine; cleaner isolation
- **Cons**: Requires a stable WebSocket protocol with backpressure handling

**Recommendation**: Start with Option B using a JSON-RPC-over-WebSocket protocol. Define it in `packages/protocol/src/agent.ts`:

```typescript
export interface AgentMessage {
  jsonrpc: "2.0";
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

export interface AgentNotification {
  jsonrpc: "2.0";
  method: string;
  params: Record<string, unknown>;
}
```

Methods:
- `agent.observation` (notification from app → agent, pushed each loop tick)
- `tools.list` / `tools.call` (request/response)
- `memory.get` / `memory.set` / `memory.delete`
- `session.finish`

---

## 9. Security Considerations

Computer use implies autonomous system interaction. Key concerns:

| Concern | Mitigation |
|---------|------------|
| Unintended file access | Sandboxed to `~/action-sessions/` output dir; no arbitrary file read |
| Password / credential exposure | Never store secrets; agent sees only AX tree and screen frames |
| Unbounded loop | Agent loop must report a maximum step count; session times out |
| Click spam | Cooldown between actions (configurable, default 300ms) |
| Permission escalation | `requestPermissions()` must be user-gesture initiated |

The `Action.app` sandbox profile should be updated to reflect these constraints. For now, this is a local-only tool — no network-exposed agent by default.

---

## 10. Verification

### Smoke Tests for Computer Use Readiness

```bash
# Vision stream
$ curl -X POST ws://localhost:9234 --json '{ "method": "tools.call", "params": { "name": "startVisionStream", "args": {} } }'
$ # Should receive frame payloads every second

# AX tree query
$ curl -X POST ws://localhost:9234 --json '{ "method": "tools.call", "params": { "name": "queryAccessible", "args": { "query": { "role": "AXButton" } } } }'
$ # Should return list of buttons

# Continuous observation loop (5 steps)
$ curl -X POST ws://localhost:9234 --json '{ "method": "agent.startLoop", "params": { "goal": "Open Safari and go to example.com", "maxSteps": 5 } }'
$ # Should stream back 5 observation payloads with decreasing uncertainty
```

---

## 11. Priority Order

1. **Frame stream + AX cache** — foundation for all perception
2. **Expanded action surface** (scroll, right-click, double-click, hover)
3. **Tool call protocol over WebSocket** — makes the external agent possible
4. **Clipboard + shell commands** — unlocks most practical workflows
5. **Memory store** — enables context carry-over
6. **External agent loop** — the actual computer use brain
7. **Self-correction / retry** — closes the loop reliably
8. **Smooth mouse motion** — better demo output

---

## 12. Open Questions

- Should the agent runtime support **interrupt** mid-action (user says "stop")?
- Should there be a **dry-run** mode where the agent describes what it would do without executing?
- Do we want **multiple simultaneous agent sessions**? Today sessions are single.
- What is the **authorization model** for shell commands? Any agent-requested shell is a risk.
- Should we support a **headless variant** of Action.app for server-side computer use?

## LIVE_INSPECTION_RUNTIME

# Live Inspection Runtime

## Why This Matters

`action` should not stop at predetermined demo recording.

The stronger product direction is:

- inspect a live app, browser surface, or bounded region
- send the current state to a model or analysis tool
- get structured findings back
- decide whether to act, record, annotate, or keep inspecting

That is useful for:

- dev workflow capture
- UI critique and QA
- agent-assisted debugging
- exploratory automation before a scenario exists

## Keep

- native capture truth in the runtime
- AppKit-owned UI lifecycle in `Action.app`
- the app/agent split
- traces and artifacts as the durable session record

## Avoid

- baking a specific VLM vendor into the native engine
- turning the app into a chat client with hidden state
- vision-only action without observable targets or trace output
- mixing post-capture review with live runtime control

## Adapt

- treat vision analysis as an inspection provider, not as the runtime itself
- let the runtime own snapshots, context packaging, artifact storage, and action boundaries
- let provider adapters own external API calls and response normalization

## Decision

`action` should gain a **live inspection mode** that sits beside guided capture.

The runtime loop becomes:

`observe -> snapshot -> analyze -> inspect findings -> act or record -> trace`

## Fit With Current Architecture

This direction matches the repo's existing split well:

- `Action.app` owns native windows, overlays, permissions UX, and any always-on inspection HUD
- `ActionAgent` owns transport, orchestration, provider calls, and session state
- the native engine keeps providing screenshots, window bounds, AX data, and input primitives
- review remains a consumer of saved inspection sessions, not the owner of live inspection

The existing design already points this way:

- `observe` is a first-class tool family in [packages/mcp/src/index.ts](packages/mcp/src/index.ts)
- the architecture document already centers `observe`, `resolve`, and `act`
- there are already native inspection-style commands such as [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift#L2115)

## New Product Primitive

Add a first-class primitive:

### Inspection Session

An inspection session is a live runtime session where the main artifact is not only video.

It owns:

- active surface or viewport
- latest screenshot or sampled frame
- optional AX/DOM context
- model prompts and responses
- findings
- optional follow-up actions
- trace and artifacts

Suggested lifecycle:

- `created`
- `staging`
- `observing`
- `analyzing`
- `awaiting-decision`
- `acting`
- `recording`
- `completed`
- `failed`
- `cancelled`

## Proposed Capability Split

### Native Engine

Should provide:

- screenshot current viewport/window/screen
- window and surface metadata
- accessibility tree slices
- optional region selection and overlay framing
- deterministic input execution

Should not provide:

- direct model client logic
- prompt templating
- provider-specific parsing

### Agent Runtime

Should provide:

- inspection session creation
- snapshot packaging
- provider adapter selection
- request/response logging
- trace event emission
- finding normalization
- action gating

### Provider Adapters

Should provide:

- external API invocation
- auth and model selection
- response normalization into `action` finding types

Examples:

- local Moondream adapter
- OpenAI vision adapter
- local CLI adapter for custom workflows

## Minimal API Shape

The next useful surface is not “chat with the app.”

It is a small inspection API:

- `session.inspect.create`
- `observe.snapshot`
- `observe.axTree`
- `inspect.analyze`
- `inspect.findings.latest`
- `act.execute`
- `record.start`
- `record.stop`

`inspect.analyze` should accept:

- image artifact path
- target surface metadata
- optional AX payload
- prompt or preset id
- provider id

It should return structured findings, not only raw prose.

Suggested normalized finding fields:

- `id`
- `source`
- `summary`
- `severity`
- `kind`
- `bounds`
- `targetHint`
- `evidence`
- `recommendedAction`

## First Increment To Actually Build

Do not start with open-ended streaming vision.

Start with one bounded loop:

1. pick a target app window or viewport
2. capture a screenshot plus AX snapshot
3. send both to a provider adapter
4. store the response as session artifacts
5. show findings in Action
6. optionally let the operator or agent run a follow-up action

That gets the core value without forcing us to solve:

- continuous video analysis
- autonomous acting
- multi-provider prompt orchestration
- generalized browser/DOM fusion

## Recommended v0 Scope

Build **Inspect Current Surface** first.

Inputs:

- current focused app or selected viewport
- prompt preset such as `ui-critique`, `qa-pass`, or `interaction-audit`
- provider selection

Artifacts:

- screenshot
- optional AX snapshot JSON
- provider request JSON
- provider response JSON
- normalized findings JSON
- trace

UI outcome:

- findings list in the launcher review surface
- “Run action from finding” later, not in v0

## Why This Is Better Than “Just Ask A VLM”

If the model call lives outside the runtime, we lose the product.

The value of `action` is that it can:

- create a stable snapshot
- preserve inspection context
- bind findings to a concrete surface and time
- keep a trace of what was observed and what happened next
- turn inspection into a reusable workflow instead of a one-off screenshot prompt

## Suggested Next Build Order

1. add inspection session types and artifacts to the runtime/protocol
2. add a provider adapter interface in the agent/runtime layer
3. implement `inspect current surface` using screenshot + AX snapshot
4. render findings in the launcher review UI
5. add optional “act on finding” follow-up commands

For the precise implementation checklist, see
[RUNTIME_BUILD_CHECKLIST.md](docs/RUNTIME_BUILD_CHECKLIST.md).

## MILESTONE_GUIDED_CAPTURE_LOOP

# Guided Capture Loop

## Purpose

This is the first meaningful milestone for `action`.

The goal is not to finish the whole product. The goal is to prove that `action`
can run a polished, inspectable, native-first capture session end to end.

If this milestone works, we will have validated the most important live-system
assumptions:

- a session-oriented runtime
- a useful operator HUD
- a visible stage with a controlled viewport
- real recording lifecycle control
- deterministic actions against a native app
- artifacts and logs that make the run inspectable afterward

## Mission

Build a native macOS guided capture session where a user can:

1. choose a backdrop and target app
2. see a HUD that reflects session state and logs
3. stage a window inside a viewport
4. trigger a recording countdown
5. record a deterministic Calculator demo
6. save video, screenshot, and trace artifacts
7. replay the last run

This milestone is intentionally live-phase heavy. It validates the runtime and
engine before investing deeply in final-video composition.

## Why This Is First

This milestone gives us the highest-value proof earliest.

- It makes the system feel real immediately.
- It tests the runtime where most failure risk lives.
- It creates the traces and artifacts the composition layer will later consume.
- It gives us a visible product loop instead of isolated backend pieces.

If this is weak, composition will not save the product. If this is solid,
composition can evolve safely later.

## Precedent Review Requirement

Before implementing each major part of this milestone, review how the same area
worked in earlier iterations such as `vif` and `stage`.

For each of these feature areas, write down:

- `Keep`
- `Avoid`
- `Adapt`
- `Decision`

Apply that review to:

- HUD
- stage and viewport
- countdown and recording state
- Calculator scenario flow
- replay and artifact presentation

The purpose is to preserve the strong product instincts from prior work without
re-importing the old architectural problems.

## Scope

### Included

- macOS-only session flow
- native HUD window
- backdrop and viewport framing
- recording countdown
- clear recording-state visuals
- Calculator launch and focus
- click, key press, and type support
- session logs
- screenshot capture
- raw video capture
- replay of the most recent run

### Deferred

- browser flows
- Notes scenario
- subtitle generation
- chapter cards
- voiceover and music timing
- Remotion final export
- multi-window stage layouts
- vision-only target selection

## Success Criteria

The milestone is successful when all of the following are true:

- A user can start a guided session from a single control surface.
- The HUD remains visible and useful during the full run.
- The system can visibly count into recording.
- The viewport clearly indicates what is being captured.
- The area outside the viewport dims during countdown and recording.
- Calculator can be launched, focused, and fit into the viewport.
- The runtime can execute a short deterministic demo using both clicks and keys.
- Every major state transition and action appears in the HUD log.
- The session saves at least one video, one screenshot, and one trace file.
- The most recent run can be replayed from the HUD.

## Primary Demo Scenario

Calculator is the first target because it is simple, native, and good at proving
basic interaction primitives.

### Scenario

1. Start a new session.
2. Select a backdrop preset.
3. Open Calculator.
4. Fit Calculator into the viewport.
5. Trigger a `3, 2, 1` countdown.
6. Start recording.
7. Execute a short expression using both keyboard and click input.
8. Capture a screenshot during or after the interaction.
9. Stop recording automatically or through the HUD.
10. Save artifacts and offer replay.

### Suggested Interaction Sequence

- type `12`
- click `+`
- type `30`
- press `=`

This is enough to prove:

- target window selection
- focus control
- key input
- pointer movement and click
- action logging
- artifact capture

## User Experience Requirements

### HUD

The HUD is a first-class product surface, not a debug panel.

It should show:

- current session state
- elapsed time or recording timer
- current target app
- control buttons
- recent log events
- recent artifacts

Controls for v1 of the HUD:

- `Start`
- `Pause`
- `Stop`
- `Replay Last Run`
- `Quit`

The HUD should feel deliberate and presentable:

- compact
- readable
- elegant
- stable in position
- visually distinct from the captured viewport

There may be two HUD layers over time:

- a minimal native HUD for always-on capture state and immediate controls
- a richer TS-side HUD for logs, diagnostics, artifacts, and operator workflows

For this milestone, the TS HUD is an acceptable first implementation surface as
long as runtime truth still lives below it.

### Stage, Backdrop, and Viewport

The stage is the operator's framing surface.

It should support:

- a chosen backdrop treatment
- one primary viewport
- clear distinction between on-stage content and surrounding space
- window fitting that does not feel accidental

The viewport is the authoritative capture region for the live demo.

### Recording State

Recording must be unmistakable.

The system should provide:

- visible countdown
- dimming outside the viewport
- explicit recording indicator
- obvious transition from staging to recording

## Architectural Implications

This milestone is mostly about three layers:

### 1. Native Engine

Owns:

- window enumeration
- window movement and sizing
- ScreenCaptureKit session control
- native overlays for countdown or viewport emphasis
- input synthesis
- app launch/focus integration

### 2. Runtime

Owns:

- session creation
- lifecycle transitions
- command dispatch
- action execution sequencing
- trace collection
- artifact registration
- replay metadata

### 3. HUD Frontend

Owns:

- user controls
- session-state presentation
- logs view
- artifact list
- replay trigger

The composer is not the main concern in this milestone. The live system is.

## Session Lifecycle For This Milestone

The generic runtime lifecycle should be specialized into an operator-facing flow:

- `created`
- `staging`
- `countdown`
- `recording`
- `paused`
- `completing`
- `completed`
- `failed`
- `cancelled`

Notes:

- `staging` means the target is being prepared and framed.
- `countdown` is a visible pre-recording phase.
- `recording` means capture is live.
- `paused` should preserve enough session state to resume or stop cleanly.

The shared protocol can continue using the broader lifecycle, but the product
surface should expose this narrower guided-capture vocabulary.

## Runtime Events

The run should emit structured events that are useful both for the HUD and for
later composition.

Minimum event categories:

- session state changed
- backdrop selected
- viewport updated
- app launched
- window focused
- countdown tick
- recording started
- recording paused
- recording stopped
- action planned
- action started
- action completed
- action failed
- screenshot captured
- video artifact finalized
- replay requested

Every event should have:

- timestamp
- session id
- type
- human-readable summary
- structured payload

## Artifacts

Minimum artifacts for this milestone:

- raw screen capture video
- screenshot
- trace log
- session metadata

Recommended session folder layout:

```text
artifacts/sessions/<session-id>/
  session.json
  trace.json
  capture.mov
  screenshot-final.png
```

## Package Responsibilities

### `packages/protocol`

- session states
- action and observation types
- HUD event payloads
- artifact metadata types

### `packages/runtime`

- session manager
- lifecycle rules
- trace storage
- artifact registration
- guided-session orchestration

### `packages/cli`

- local operator commands for development
- session start/stop/replay wiring

### `packages/composer-core`

- not primary for this milestone
- may define the future shape of render-manifest inputs

### `native/engine`

- native capture control
- window fitting
- overlays
- app launch/focus
- input synthesis

## Delivery Plan

### Phase 1: Session Skeleton

- finalize milestone-specific lifecycle states
- add runtime event stream for HUD consumption
- define artifact directory layout

### Phase 2: HUD Shell

- create HUD window
- add controls
- add status area
- add scrolling event log
- add artifact list and replay control

### Phase 3: Stage and Viewport

- create backdrop surface
- define viewport region
- fit Calculator into viewport
- add non-captured dimmed surroundings

### Phase 4: Recording Control

- implement countdown
- implement start/stop recording
- implement screenshot capture
- save artifacts per session

### Phase 5: Deterministic Calculator Demo

- open Calculator
- focus window
- run click and keyboard actions
- record action traces in real time

### Phase 6: Replay

- make last run discoverable
- open or preview the latest capture from the HUD

## Definition Of Done

This milestone is done when:

- the full Calculator scenario runs from a single operator flow
- the HUD stays informative and responsive throughout
- recording state is visually clear
- artifacts are saved to a predictable session folder
- replay of the latest run works
- the trace is useful enough to debug failures afterward

## Follow-On Milestones

If this milestone lands well, the next likely milestones are:

1. manual website capture with trace recording
2. Notes scenario with richer typing and selection behavior
3. trace-to-scenario compilation
4. composer-driven polish from captured sessions

That sequence preserves the architectural idea that live capture creates the raw
truth, and composition upgrades presentation later.

## PRECEDENT_HUD_STAGE

# HUD And Stage Precedent Review

## Feature

HUD, backdrop, viewport, and recording-state presentation for the guided capture
milestone.

## Keep

- `vif`: the product feeling that the stage is visible, deliberate, and clearly
  in a recording mode when capture starts.
- `vif`: viewport-first framing with backdrop dimming outside the captured
  region.
- `vif`: a control surface that feels like part of the product, not a raw debug
  console.
- `stage`: clearer separation between operator controls and stage primitives
  such as backdrop and viewport.

## Avoid

- `vif`: HUD and overlay behavior becoming tightly coupled to ad hoc runner
  logic.
- `vif`: letting the UI invent state that diverges from runtime truth.
- `stage`: keeping the stage too abstract or too tool-like to feel like a real
  product surface.

## Adapt

- Keep the richer TS-side operator HUD, but make it render the runtime session
  state directly.
- Treat backdrop and viewport as first-class stage concepts, but avoid binding
  them to a specific renderer too early.
- Use native overlays later for always-on capture-state presence, while the TS
  HUD remains the richer inspection and control surface.

## Decision

- For this milestone, the TS HUD will become stage-aware: it should visibly show
  backdrop, viewport, countdown, recording state, and artifacts.
- The native side remains responsible for capture truth and will later gain the
  thin always-on stage overlay.
- The product contract stays viewport-first: the stage shows what is captured,
  and the rest of the scene is visually subordinate.

## Reference Weight

Blend leaning `vif` for product feel and `stage` for boundaries.

## PRECEDENT_REVIEW

# Precedent Review

## Purpose

`action` is a rewrite, not a fresh invention.

That means every meaningful feature should be implemented with awareness of prior
iterations such as `vif`, `stage`, and other reference products already named in
the vision docs.

The point is not to cargo-cult old code or old abstractions. The point is to
avoid relearning the same lessons and to preserve the parts that were genuinely
good.

## Primary References

There are two primary implementation precedents for this repo:

### `vif`

`vif` is the more mature reference.

Use it for:

- richer product instincts
- features that were already proven in practice
- examples of end-to-end flows that felt real
- areas where the UX had already become compelling

Treat it carefully because it also carries more historical complexity:

- broader product surface
- accumulated lifecycle complications
- architectural entanglement
- features that worked but were hard to reason about internally

### `stage`

`stage` is the less mature reference, but often the cleaner conceptual one.

Use it for:

- stronger boundaries
- cleaner framing of capabilities
- improved instincts around agent-facing primitives
- ideas that look more like a v2 architecture

Treat it carefully because it is also less proven:

- some concepts were still underdeveloped
- some reliability questions were unresolved
- some abstractions were cleaner than their implementation maturity

## How To Read The Two Together

When both references are relevant:

- use `vif` to understand what felt good and what actually mattered in practice
- use `stage` to understand how that idea wanted to be cleaned up architecturally
- do not inherit `vif` complexity just because it is more complete
- do not inherit `stage` abstractions just because they are cleaner on paper

In short:

- `vif` is often the better product reference
- `stage` is often the better architecture prompt
- `action` should combine the strongest parts of both without importing their
  weaknesses

## Additional Reference: Peekaboo

Peekaboo is a strong native implementation reference for:

- permission handling
- Swift-first macOS automation ownership
- CLI and agent surfaces over one underlying automation stack
- separating visual feedback concerns from the lowest-level automation core

It is not the primary product precedent for `action`, but it is highly relevant
when we are deciding how to structure:

- native permissions
- capture services
- macOS automation boundaries
- app/CLI/MCP sharing

Use Peekaboo mainly as an implementation precedent for native host architecture,
not as a reason to broaden `action` beyond the guided demo mission.

## Rule

Before implementing a substantial feature, do a short precedent review.

A substantial feature includes things like:

- HUD
- stage and viewport
- countdown and recording controls
- target resolution
- timeline/scenario format
- overlays and cues
- replay and artifact presentation
- composition/export behavior

## What A Precedent Review Should Ask

For the specific feature being built:

1. What did `vif` do that was genuinely good?
2. What did `stage` do that was genuinely good?
3. What failed in those implementations?
4. What should be preserved in spirit but re-implemented differently?
5. What should be explicitly rejected this time?

Also ask:

6. Is this feature better informed by `vif` as product precedent, `stage` as
   architecture precedent, or both?

The review does not need to be long. It does need to be explicit.

## Expected Output

For each substantial feature, produce a short note before or during
implementation with these headings:

### Keep

- behaviors, UX ideas, or implementation instincts worth preserving

### Avoid

- failure modes, overreach, or known weak abstractions

### Adapt

- ideas that were good but need a different architecture in `action`

### Decision

- what this repo will actually build now

### Reference Weight

- whether this feature leans more on `vif`, `stage`, or a blend of both

## Example: HUD

### Keep

- a persistent control surface
- visible logs and state
- polished feeling, not a debug-only panel
- recording controls that are always easy to reach

### Avoid

- HUD logic owning runtime state directly
- UI behavior diverging from runtime truth
- messy control flow tied to CLI lifecycle hacks

### Adapt

- preserve the operator-first feeling
- move state authority into the runtime session model
- let the HUD render events instead of inventing its own truth

### Decision

- HUD is a thin frontend over guided-session events and controls

## Working Agreement

When implementing features in this repo:

- review the relevant precedent first
- write down the keep/avoid/adapt/declaration summary
- then implement

This keeps the rewrite grounded without letting old architecture silently
control the new one.

## REVIEW_UX_V1

# Review UX V1 (Agent Notes)

## Goal
Turn session review into a fast, reliable "agent note" workflow:

1. seek quickly
2. anchor feedback precisely (point/range/region)
3. write actionable instruction
4. save and revisit notes

This is not a social commenting UI. It is a structured note system for an AI agent.

## Interaction Model

### 1) Single Composer
- One explicit composer entrypoint: `+ Feedback`
- Composer has anchor mode tabs:
  - `Point`: click timeline to stamp a single time
  - `Range`: drag timeline to set in/out
  - `Region`: drag on video frame to select area
- Composer always shows current anchor summary and short mode instructions.

### 2) Timeline As Primary Control
- Timeline must always support click and drag seek.
- Anchor creation overlays on top of seek behavior, not instead of it.
- In range mode, drag previews the range before commit.
- Timeline markers represent saved notes and jump playback on click.

### 3) Frame Region Selection
- Region mode is explicit and visible.
- Drag on frame creates a highlighted area with clear border.
- Region remains visible after selection and after save when focused.

### 4) Notes Rail
- Composer and saved notes live in a dedicated "notes rail".
- Saved notes are scrollable and selectable.
- Selecting a saved note focuses timeline + playback + region context.

## State Rules

- `isComposingFeedback` gates anchor creation.
- `anchorMode` controls source of anchor input:
  - timeline click for point
  - timeline drag for range
  - frame drag for region
- `Save` requires non-empty instruction.
- `Clear Anchors` only clears draft anchors, not saved notes.

## Quality Bar

- No hidden interaction modes.
- Every click/drag should produce immediate visual response.
- No ambiguous labels like "marking" without visible result.
- Primary actions should be discoverable without documentation.

## Follow-up (V1.1)

- Keyboard controls:
  - `N` open composer
  - `1/2/3` switch anchor mode
  - `Esc` cancel region mode
  - `Cmd+Enter` save note
- Inline marker hover previews.
- Optional snap-to-nearest-marker and frame-accurate stepping.

## RUNTIME_BUILD_CHECKLIST

# Runtime Build Checklist

This document is the practical implementation list for turning `action` into a
runtime that can observe, act, reflect, and record.

It is intentionally precise. Items here should be implementable as concrete
tasks, not aspirational themes.

## Product Contract

When this roadmap lands, `action` should support this loop:

1. select a live surface
2. inspect the current state
3. run reflection against that state
4. decide whether to act, record, annotate, or stop
5. preserve a full trace and artifacts

## Workstream 1: Shared Runtime Model

### 1.1 Session Vocabulary

- [ ] Decide whether to keep one session type with modes, or separate `capture`
  and `inspection` session types.
- [ ] Add a stable session mode enum such as `capture`, `inspection`, `hybrid`.
- [ ] Define reflection-specific phases and make them canonical across TS and
  Swift:
  - [ ] `observing`
  - [ ] `analyzing`
  - [ ] `awaiting-decision`
  - [ ] `acting`
- [ ] Define phase transition rules so invalid jumps are impossible.
- [ ] Define which phases allow recording, acting, replay, or dismissal.

### 1.2 Trace Model

- [ ] Add trace events for:
  - [ ] snapshot captured
  - [ ] AX snapshot captured
  - [ ] inspection requested
  - [ ] inspection response received
  - [ ] finding recorded
  - [ ] finding accepted or dismissed
  - [ ] follow-up action started
  - [ ] follow-up action completed
  - [ ] follow-up action failed
- [ ] Record control-origin events:
  - [ ] HUD button pressed
  - [ ] CLI command issued
  - [ ] MCP tool request issued
- [ ] Record provider metadata in the trace without leaking secrets.

### 1.3 Artifact Model

- [ ] Finalize artifact kinds for:
  - [ ] screenshot
  - [ ] raw capture
  - [ ] trace
  - [ ] AX snapshot
  - [ ] inspection request
  - [ ] inspection response
  - [ ] normalized findings
- [ ] Standardize per-session artifact paths.
- [ ] Add a session manifest file listing all artifacts and their roles.
- [ ] Add versioning for saved findings and inspection result formats.

## Workstream 2: Native Engine Capabilities

### 2.1 Surface Discovery

- [ ] Add a native API to enumerate observable surfaces:
  - [ ] running apps
  - [ ] top-level windows
  - [ ] active browser window if applicable
  - [ ] bounded region selection
- [ ] Add a stable surface identifier format.
- [ ] Add a native command to return the currently focused surface.

### 2.2 Snapshot Capture

- [ ] Add a native command to capture the current focused window screenshot.
- [ ] Add a native command to capture a selected viewport screenshot.
- [ ] Add a native command to capture a full screen screenshot without starting
  a recording session.
- [ ] Add timestamped, deterministic snapshot naming.
- [ ] Add geometry metadata to every snapshot artifact.

### 2.3 Accessibility Inspection

- [ ] Generalize the existing Calculator-only inspection commands into
  app-agnostic AX inspection.
- [ ] Add a native command to fetch an AX tree slice for a bundle id or surface
  id.
- [ ] Add a native command to fetch a focused AX element snapshot.
- [ ] Add bounds and role metadata normalization for AX nodes.
- [ ] Add size limits and pruning rules so AX payloads stay usable for model
  calls.

### 2.4 Live Overlay And Controls

- [ ] Keep an always-available native control surface whenever a live session is
  on screen.
- [ ] Make controls phase-aware for:
  - [ ] inspect
  - [ ] apply
  - [ ] start recording
  - [ ] interrupt
  - [ ] cancel
  - [ ] dismiss
- [ ] Add a visible reflecting or analyzing state in the native HUD.
- [ ] Add explicit control affordances for non-recording live sessions.
- [ ] Add an operator-safe way to stop a session that is waiting on external
  analysis.

### 2.5 Input And Acting

- [ ] Keep deterministic input primitives as the only execution path.
- [ ] Add generic click, type, keypress, drag, and focus commands to the
  runtime-facing API where missing.
- [ ] Add optional screenshot-before and screenshot-after hooks for actions.
- [ ] Add a way to bind a follow-up action to a finding target hint.

## Workstream 3: Agent Runtime Core

### 3.1 Session Registry

- [ ] Add a session registry in the agent/runtime layer.
- [ ] Track active session state in one place instead of distributing it across
  UI-only paths.
- [ ] Add explicit resource cleanup per session:
  - [ ] overlay stop files
  - [ ] recording stop files
  - [ ] child processes
  - [ ] temporary inspection request files

### 3.2 Snapshot Packaging

- [ ] Build a snapshot packaging service that can assemble:
  - [ ] screenshot path
  - [ ] viewport metadata
  - [ ] AX snapshot path
  - [ ] surface metadata
  - [ ] runtime notes
- [ ] Add payload size budgeting before a provider call.
- [ ] Add redaction hooks for sensitive text or window titles later.

### 3.3 Reflection Orchestration

- [ ] Add an inspection service in the runtime layer.
- [ ] It should:
  - [ ] create inspection requests
  - [ ] invoke a provider adapter
  - [ ] store raw request and response artifacts
  - [ ] normalize findings
  - [ ] emit trace events
  - [ ] transition the session between `observing`, `analyzing`, and
    `awaiting-decision`
- [ ] Add timeout and cancellation handling for provider calls.
- [ ] Add retry policy rules that avoid duplicate artifact corruption.

### 3.4 Action Gating

- [ ] Require an explicit decision point before executing a model-suggested
  action.
- [ ] Add a runtime policy switch:
  - [ ] operator approval required
  - [ ] agent approval required
  - [ ] auto-apply allowed
- [ ] Log the decision source in the trace.

## Workstream 4: Provider Adapter Layer

### 4.1 Adapter Interface

- [ ] Add a provider adapter interface in the runtime layer.
- [ ] Standardize adapter input:
  - [ ] prompt preset id
  - [ ] freeform prompt
  - [ ] image path
  - [ ] AX context path
  - [ ] surface metadata
- [ ] Standardize adapter output:
  - [ ] summary
  - [ ] findings
  - [ ] optional recommended actions
  - [ ] raw response reference

### 4.2 Local Moondream Adapter

- [ ] Add a local Moondream adapter.
- [ ] Read the Moondream install path from environment or config, not from the native app.
- [ ] Save the exact request payload sent to the model as an artifact.
- [ ] Save the raw response as an artifact.
- [ ] Normalize the response into the internal findings format.

### 4.3 Prompt Presets

- [ ] Define a preset registry for:
  - [ ] `ui-critique`
  - [ ] `qa-pass`
  - [ ] `interaction-audit`
  - [ ] `target-suggestion`
- [ ] Keep preset definitions in a single runtime-owned location.
- [ ] Add versioning so findings can be traced back to a prompt revision.

## Workstream 5: Frontend Surfaces

### 5.1 Launcher

- [ ] Add a top-level inspection workflow in `Action.app`.
- [ ] Add controls to:
  - [ ] inspect current surface
  - [ ] inspect selected app
  - [ ] inspect selected viewport
  - [ ] start recording from current session
- [ ] Add a findings list view.
- [ ] Add a raw context view:
  - [ ] screenshot preview
  - [ ] AX summary
  - [ ] provider summary
- [ ] Add a decision bar for:
  - [ ] apply suggested action
  - [ ] ignore finding
  - [ ] record next step
  - [ ] rerun inspection

### 5.2 Native HUD

- [ ] Keep HUD controls reachable during all live phases.
- [ ] Show when the runtime is:
  - [ ] observing
  - [ ] reflecting
  - [ ] waiting for a decision
  - [ ] acting
  - [ ] recording
- [ ] Make sure the HUD never shows a disabled dead-end state without a visible
  escape path.

### 5.3 TS HUD

- [ ] Add inspection session rendering to the TS HUD.
- [ ] Show latest findings inline with the current screenshot.
- [ ] Show trace events for reflection and action gating.
- [ ] Add artifact previews for inspection request, response, and findings JSON.

## Workstream 6: Agent-Facing Interfaces

### 6.1 CLI

- [ ] Add CLI commands for:
  - [ ] `inspect current-surface`
  - [ ] `inspect app --bundle-id ...`
  - [ ] `inspect viewport --x ... --y ... --width ... --height ...`
  - [ ] `inspect findings`
  - [ ] `session act`
  - [ ] `session record-start`
  - [ ] `session record-stop`
- [ ] Make CLI output distinguish startup acknowledgement from completed
  inspection or recording.

### 6.2 MCP

- [ ] Add MCP tools for:
  - [ ] create inspection session
  - [ ] capture snapshot
  - [ ] request analysis
  - [ ] list findings
  - [ ] execute action
  - [ ] start recording
  - [ ] stop recording
- [ ] Make MCP tools return session ids and artifact references, not only prose.

### 6.3 WebSocket Agent Protocol

- [ ] Expand the agent protocol beyond the current narrow native command set.
- [ ] Add methods for:
  - [ ] session creation
  - [ ] surface enumeration
  - [ ] snapshot capture
  - [ ] AX inspection
  - [ ] provider-backed analysis
  - [ ] findings retrieval
  - [ ] gated action execution

## Workstream 7: Session Storage And Review

### 7.1 Session Layout

- [ ] Standardize a session directory layout that works for both capture and
  inspection sessions.
- [ ] Add `session.json` with:
  - [ ] mode
  - [ ] lifecycle
  - [ ] target surface
  - [ ] provider info
  - [ ] key artifact paths

### 7.2 Findings Persistence

- [ ] Add `findings.json` as a first-class saved artifact.
- [ ] Add support for finding status:
  - [ ] open
  - [ ] accepted
  - [ ] dismissed
  - [ ] acted-on
- [ ] Add finding-to-action linkage so review can explain what happened next.

### 7.3 Review UI

- [ ] Extend the existing review surface to load inspection sessions, not only
  demo captures.
- [ ] Show inspection summary cards beside recordings in the library.
- [ ] Let a user reopen a session and see:
  - [ ] original snapshot
  - [ ] findings
  - [ ] follow-up actions
  - [ ] whether recording happened later

## Workstream 8: Reliability And Safety

### 8.1 Cancellation

- [ ] Ensure every live phase has a tested cancel path.
- [ ] Ensure cancellation writes a final session status and does not strand
  child processes.
- [ ] Ensure provider timeouts do not leave the UI in `analyzing` forever.

### 8.2 Error Handling

- [ ] Normalize native errors, provider errors, and runtime errors into one
  session-visible format.
- [ ] Record failures as trace events and artifacts where useful.
- [ ] Add user-visible recovery guidance for common failure classes.

### 8.3 Permissions

- [ ] Make inspection flows clearly report when Accessibility or Screen
  Recording permissions are missing.
- [ ] Distinguish which operations need which permission.

## Workstream 9: Testing

### 9.1 Protocol And Runtime Tests

- [ ] Add TypeScript tests for:
  - [ ] session phase transitions
  - [ ] finding normalization
  - [ ] artifact manifests
  - [ ] provider adapter contracts

### 9.2 Native Tests

- [ ] Add smoke tests for:
  - [ ] current surface screenshot
  - [ ] AX snapshot fetch
  - [ ] live HUD controls during inspect phases
  - [ ] inspection cancellation
  - [ ] recording start from an inspection session

### 9.3 End-To-End Tests

- [ ] Add one end-to-end inspection path:
  - [ ] stage Calculator or another stable app
  - [ ] capture screenshot
  - [ ] capture AX snapshot
  - [ ] run mock provider analysis
  - [ ] persist findings
  - [ ] apply one follow-up action
  - [ ] optionally record the result

## Recommended Build Order

This is the order that keeps the architecture practical.

### Phase A: Foundation

- [ ] finalize session mode and phase model
- [ ] finalize artifact and trace schema
- [ ] add session registry in the runtime

### Phase B: Native Observe

- [ ] implement surface enumeration
- [ ] implement focused surface screenshot
- [ ] implement generic AX snapshot
- [ ] keep HUD controls live during non-recording sessions

### Phase C: Reflection

- [ ] add provider adapter interface
- [ ] add local Moondream adapter
- [ ] add prompt preset registry
- [ ] add findings persistence

### Phase D: Decision And Action

- [ ] add action gating
- [ ] add finding-to-action execution
- [ ] add screenshot before and after action hooks

### Phase E: Record And Review

- [ ] start recording from an inspection session
- [ ] persist hybrid inspection-plus-recording sessions
- [ ] render findings in the launcher and TS HUD

## Done Criteria For The Vision

We are meaningfully on the intended path when all of the following are true:

- [ ] a live app surface can be inspected without starting a demo scenario
- [ ] a model-backed reflection step can run on the captured state
- [ ] findings are stored as first-class session artifacts
- [ ] a user or agent can choose whether to act on a finding
- [ ] a recording can begin from the same live runtime session
- [ ] the full loop is preserved as trace plus artifacts

## SURFACE_ADAPTER_PLAN

# Surface Adapter Plan

> Formalized as [ACT-001: Surface Adapter Architecture](decisions/ACT-001-surface-adapter-architecture.md).
> Keep ACT-001 as the source of truth for the decision/proposal record.

## Principle

Every surface starts with the macOS accessibility tree.

First-class surfaces get complementary semantic channels. Those channels should
make Action faster and more precise, but they should not replace AX as the
baseline source of UI truth.

In practice:

- AX tells Action what app/window/control exists in the OS.
- Native capture tells Action what is visible.
- Adapter-specific channels tell Action what the app means internally.
- Vision verifies visual outcomes when AX or semantic state is incomplete.

## Runtime Shape

Action should expose one runtime contract and many adapters.

```ts
interface SurfaceAdapter {
  id: string;
  label: string;
  priority: number;

  canHandle(surface: SurfaceRef): Promise<AdapterMatch>;
  observe(context: ObserveContext): Promise<SurfaceObservation>;
  resolve(query: TargetQuery, observation: SurfaceObservation): Promise<TargetCandidate[]>;
  act(action: RuntimeAction, target: TargetCandidate): Promise<ActionResult>;
  extract(query: ExtractionQuery, observation: SurfaceObservation): Promise<ExtractionResult>;
  captureHints(target: TargetCandidate): Promise<CaptureHint[]>;
  verify(result: ActionResult, context: VerifyContext): Promise<VerificationResult>;
}
```

The shared observation envelope should look roughly like this:

```ts
interface SurfaceObservation {
  surface: SurfaceRef;
  ax: AXSnapshot;
  native: NativeWindowState;
  semantic?: ChromeDomState | BrowserPageState | TerminalState | EditorState | SiteState;
  vision?: ScreenshotReflection;
  freshness: {
    axCapturedAt: string;
    semanticCapturedAt?: string;
    screenshotCapturedAt?: string;
  };
}
```

The target resolver should produce candidates with evidence, not just a point.

```ts
interface TargetCandidate {
  id: string;
  label: string;
  role?: string;
  rect?: Rect;
  confidence: number;
  stabilityKey?: string;
  evidence: TargetEvidence[];
  preferredActionChannel: "ax" | "dom" | "tmux" | "editor" | "native" | "hid";
  fallbackChannels: string[];
}
```

## Action Policy

The adapter should choose the safest available channel for each action.

Recommended order:

1. App-native semantic action, such as DOM value set, tmux send-keys, or editor command.
2. AX action, such as `AXPress`, `AXValue`, `AXSelectedText`, or settable focused value.
3. Process-directed key or text event.
4. HID event that may move focus or the real pointer.

When an action may disturb the user's current focus, Action should warn through
the overlay before doing it.

Post-action verification should use a different channel when possible. For
example, a DOM set should be verified by DOM state plus AX or screenshot.

## Adapter Families

## 1. Browser App Adapters

Browsers are first-class because a large share of user work happens inside
web apps, and AX alone is too lossy inside complex pages.

### Chrome

Channels:

- AX snapshot for window, omnibox, tabs, web area, and native Chrome controls.
- Chrome extension for DOM observe/act/extract.
- Optional Chrome DevTools Protocol for development and debugging flows.
- Native capture for screenshots, previews, and recording.

Core abilities:

- Inspect current tab URL/title/loading state.
- Return visible DOM nodes with roles, labels, text, rects, selectors, and image URLs.
- Resolve form fields, buttons, links, menus, image cards, and content regions.
- Set input and textarea values with browser events.
- Click page-local elements without moving the OS pointer.
- Return semantic crop hints for top-right preview or recording focus.

### Safari

Channels:

- AX snapshot for window, toolbar, web area, form controls, and page content.
- Safari extension later if the product needs Chrome-like DOM fidelity.
- AppleScript or Safari automation only where reliable.
- Native capture.

Core abilities:

- Browser-window awareness.
- URL/title extraction through AX or scripting.
- Basic target resolution and form interaction.
- Conservative fallbacks when Safari does not expose stable internals.

### Firefox

Channels:

- AX snapshot for browser shell and web area.
- Firefox extension for DOM observe/act/extract if we want parity with Chrome.
- Native capture.

Core abilities:

- Same conceptual model as Chrome, with a smaller initial scope.
- Good enough for users who do not want Chrome.

## 2. Browser Site Adapters And Recipes

Site adapters live inside the browser extension world. They should not be
separate native apps. They specialize the generic browser adapter for high-volume
web products.

Not every product deserves a bundled first-class adapter. The default path
should be:

1. generic browser adapter
2. user-authored or bundled browser recipe
3. first-class site adapter only when usage volume and workflow depth justify it

### GitHub

Why:

- Pull requests, issues, reviews, checks, diffs, and file browsing are common
agent workflows.

Extra semantics:

- PR title/status/checks/review state.
- File tree and diff hunks.
- Comment boxes and review submission controls.
- Repo/branch/commit context.

### Google Search And Docs-Like Surfaces

Why:

- Search, docs, sheets, and web forms appear in many demos.

Extra semantics:

- Search box and result list.
- Document title and editable region.
- Save/sync state when exposed.
- Selection and visible cursor context where possible.

### Midjourney Recipe

Why:

- It is a strong demo and dogfood target for background generation, visual
preview, and rendered result monitoring.
- It is probably too specific for the initial first-class adapter set.

Recipe semantics:

- Create prompt composer target.
- Submit control target.
- Job/result card targets.
- Prompt text associated with result cards.
- Image URL and crop hint extraction.

This should start as a bundled recipe on top of the Chrome companion extension,
not as a bespoke core adapter.

## 3. Terminal Adapters

Terminals are first-class because the user base lives in shells, and terminal
AX output is often weaker than the shell's own state.

### Terminal Base Adapter

Channels:

- AX snapshot for app/window/pane bounds.
- Native capture for terminal screenshots.
- Optional shell integration markers.
- Process/window metadata.

Core abilities:

- Identify terminal app, window title, and visible text region.
- Capture a visible pane region.
- Warn before focus-taking input.
- Detect when only HID/focus-based typing is available.

### tmux

Channels:

- `tmux list-sessions`, `list-windows`, `list-panes`.
- `tmux capture-pane`.
- `tmux send-keys`.
- `tmux display-message` for current command, cwd, and pane metadata.
- AX/native capture for the terminal window that hosts the pane.

Core abilities:

- Resolve a pane by session/window/pane id, title, cwd, or visible text.
- Send keys without using the OS pointer.
- Extract command output reliably.
- Know whether a command exited and with what status when shell integration is available.

### iTerm

Channels:

- AX snapshot for windows, tabs, split panes, and text areas.
- iTerm scripting API where available.
- tmux adapter when iTerm hosts tmux.
- Native capture.

Core abilities:

- Resolve window/tab/session.
- Read visible text where possible.
- Send text/keys through the safest available path.
- Capture exact pane bounds.

### Ghostty

Channels:

- AX snapshot and native capture.
- tmux/shell integration when present.
- App-specific hooks later if Ghostty exposes stable automation APIs.

Core abilities:

- Window/pane bounds.
- Visible terminal text via AX/capture.
- tmux-backed control when applicable.

### Warp

Channels:

- AX snapshot and native capture.
- Block-aware semantics if Warp exposes them through AX or local APIs.
- Shell integration where possible.

Core abilities:

- Resolve command blocks.
- Extract visible block output.
- Warn when input requires focus.

## 4. Coding Surface Adapters

Coding apps are first-class because Action's users spend most of their time in
editors and agent consoles.

### Cursor

Channels:

- AX snapshot for editor shell, command palette, sidebars, terminal panels, and chat.
- VS Code-compatible extension channel if available.
- Filesystem/workspace state.
- Native capture.

Core abilities:

- Identify active workspace, file, selection, editor region, terminal panel, and chat panel.
- Run editor commands through extension APIs where possible.
- Capture focused code regions.
- Avoid stealing focus unless the requested action truly requires it.

### VS Code

Channels:

- AX snapshot.
- VS Code extension API.
- Filesystem/workspace state.
- Native capture.

Core abilities:

- Active file/selection/diagnostics.
- Command palette actions.
- Terminal panel state.
- Extension-mediated text edits and navigation.

### Codex

Channels:

- AX snapshot for the desktop app UI.
- Local workspace and thread context when available.
- Native capture and overlay.

Core abilities:

- Understand chat/input/output regions.
- Track running commands and visible logs where exposed.
- Capture meaningful preview regions.
- Warn before actions that may interfere with the user's current Codex focus.

### Conductor

Channels:

- AX snapshot.
- Local app/project metadata if exposed.
- Native capture.

Core abilities:

- Identify active project/session.
- Resolve chat, task, and result regions.
- Capture agent progress and output state.

## 5. System And Long-Tail Adapters

### Finder And File Pickers

Why:

- Files, save dialogs, open dialogs, downloads, and permissions are frequent
automation edges.

Channels:

- AX snapshot.
- Filesystem APIs.
- Native capture.

Core abilities:

- Resolve file picker fields and buttons.
- Navigate known folders.
- Select files without fragile coordinate clicking when possible.

### System Dialogs And Permissions

Why:

- macOS permission dialogs and settings are unavoidable for capture and
automation products.

Channels:

- AX snapshot.
- System settings URLs.
- Native capture.

Core abilities:

- Detect permission state.
- Open correct settings pane.
- Explain when manual user action is required.

### Generic AX Adapter

This is the long-tail fallback for every other app.

Channels:

- AX snapshot.
- Native capture.
- Optional vision reflection.

Core abilities:

- Inspect app/window/control tree.
- Resolve buttons, text fields, menus, lists, and scroll areas.
- Prefer AX actions over coordinates.
- Use coordinate/HID fallback only with explicit risk labeling.

## 6. User-Authored Adapters

The adapter system should let users teach Action their own high-volume surfaces
without waiting for a bundled adapter release.

There should be three authoring levels.

### Level 1: Recipes

Recipes are declarative target and extraction definitions. They should be enough
for most site-specific and app-specific customizations.

Good fits:

- internal web apps
- niche SaaS tools
- personal dashboards
- demo targets like Midjourney
- simple editor or terminal workflows that mostly need better labels and crops

Example shape:

```json
{
  "id": "user.midjourney.create",
  "label": "Midjourney Create",
  "surface": {
    "kind": "browser-page",
    "urlMatches": ["https://www.midjourney.com/imagine*"]
  },
  "targets": {
    "prompt": {
      "dom": { "role": "textbox", "text": "What will you imagine?" },
      "ax": { "role": "AXTextArea" }
    },
    "latestResult": {
      "dom": { "nearTextTarget": "prompt", "image": true },
      "capture": { "padding": 32, "preferAspectRatio": "16:9" }
    }
  },
  "actions": {
    "submitPrompt": [
      { "setValue": "prompt" },
      { "key": "Enter" },
      { "waitFor": "latestResult" }
    ]
  }
}
```

Recipes should be inspectable, exportable, and safe by default. They can define
targets, fallback selectors, capture hints, waits, and verification checks. They
should not run arbitrary shell commands.

### Level 2: TypeScript Adapter Modules

TypeScript adapters implement a constrained subset of the adapter contract for
users who need logic, not just selectors.

Good fits:

- teams with complex internal tools
- workflow products with stable local APIs
- browser apps where extracting state requires page-specific logic

They should run in a sandboxed runtime with explicit capabilities:

- browser DOM access
- AX snapshot read access
- capture hint generation
- local filesystem read access only when granted
- no native input or shell by default

### Level 3: Native Capability Adapters

Native capability adapters are for integrations that need privileged local
behavior, such as deep terminal or editor control.

These should usually be bundled, reviewed, or explicitly installed because they
can affect the user's OS session.

Good fits:

- tmux
- terminal hosts
- editor extension bridges
- permission/settings flows

### Sharing Model

Adapters and recipes should be packageable as small packs:

- local user recipes
- team-shared packs
- bundled Action packs
- optional community packs later

Each pack should declare:

- surfaces matched
- capabilities requested
- actions it can perform
- whether actions are background-safe
- whether actions may steal focus
- verification strategy

## Initial Adapter Set

The first shippable set should be roughly 15 to 18 adapters:

1. Generic AX
2. Chrome
3. Chrome extension generic web
4. GitHub site adapter
5. Google search/docs-like site adapter
6. Safari
7. Firefox
8. Terminal base
9. tmux
10. iTerm
11. Ghostty
12. Warp
13. Cursor
14. VS Code
15. Codex
16. Conductor
17. Finder/file pickers
18. System dialogs/permissions

Bundled recipes can cover specific demo or workflow targets without promoting
them into core adapters. Midjourney is a good first bundled recipe because it
exercises browser DOM resolution, background action, result monitoring, image
extraction, and semantic preview crops.

This is enough to cover the highest-volume places while preserving a credible
long-tail story through AX.

## Milestones

### Milestone 1: Adapter Registry And Observation Envelope

- Add a runtime-level adapter registry.
- Normalize AX, native window, screenshot, and semantic observations into one envelope.
- Add target candidates with evidence, confidence, rects, and preferred action channel.
- Add action risk classification.

### Milestone 2: Chrome Companion Extension

- Build a minimal Manifest V3 extension.
- Add content-script DOM observe/resolve/act/extract.
- Add native messaging or local WebSocket pairing with Action.
- Use extension rects to drive native top-right semantic previews.
- Keep AX as the Chrome window and toolbar source of truth.

### Milestone 3: tmux And Terminal Family

- Add tmux observe/extract/send primitives.
- Add terminal host detection for iTerm, Ghostty, Warp, and Terminal.app.
- Map tmux pane geometry back to native capture regions.
- Warn when a terminal action requires focus-taking input.

### Milestone 4: Coding Surfaces

- Start with Cursor and VS Code because their extension story is strongest.
- Add active file, selection, diagnostics, terminal panel, command palette, and chat surface observations.
- Add Codex and Conductor as AX-first app adapters with optional local state hooks.

### Milestone 5: Recipe Authoring

- Add a declarative recipe format for browser and AX targets.
- Add local recipe loading, validation, and capability summaries.
- Ship a Midjourney recipe as dogfood, not as a core adapter.
- Add import/export for team-shared recipes.

### Milestone 6: Site Adapters

- Layer GitHub and Google-like flows on top of the browser adapter.
- Promote recipes to first-class site adapters only after repeated usage proves they deserve it.
- Keep site adapters small and evidence-driven.
- Avoid hard-coding pixel layouts when DOM or AX can provide stable targets.

### Milestone 7: Long-Tail Hardening

- Improve generic AX resolution.
- Add screenshot plus local VLM verification.
- Add better ambiguity reporting.
- Add "focus will be stolen" warnings for unsafe actions.

## Definition Of Done For A First-Class Adapter

An adapter is first-class when it can:

- Observe the current state from AX and at least one complementary channel.
- Resolve targets with evidence and confidence.
- Act through the safest available channel.
- Verify the result after acting.
- Provide capture hints for screenshots, zooms, and overlays.
- Explain when it cannot act without interfering with the user.
- Fall back cleanly to generic AX behavior.

## Product Rule

Action should be excellent in the places builders actually live, and still
competent everywhere else.

## V0

# v0 Scope

## Included

- macOS only
- Native session lifecycle
- Observe / resolve / act primitives
- Browser and app target resolution
- Raw screen capture plus cursor/click metadata
- Chapters, labels, subtitles
- Auto-zoom and click emphasis during composition
- Voice and background music tracks
- CLI and MCP frontends
- Remotion composition backend

## Deferred

- Full GUI editor
- Multi-platform support
- Vision-only autonomous clicking
- Complex collaborative timelines
- Multiple simultaneous app surfaces in one live session

## Target Resolution Order

1. semantic ids
2. accessibility or DOM matches
3. bounded text-based fuzzy match
4. calibrated anchor
5. coordinates

Automatic actions should only execute when confidence crosses an explicit threshold.

## VISION

# Vision

`action` is an agentic system for producing polished software demos and promotional videos on macOS.

It is designed for a workflow where an engineer, founder, or AI agent can say:

> Show the core features of this product clearly, stylishly, and repeatably.

And the system can turn that intent into a deterministic run, a trace of what happened, and a polished output that is ready to share.

## Why This Exists

Existing work in this space tends to split into a few categories:

- capture tools that are visually polished but not programmable enough
- automation tools that can click around but do not produce presentation-quality output
- DSL-driven systems that become fragile because execution, lifecycle, and rendering are all mixed together

`action` is meant to bridge those gaps.

It should feel like:

- a serious automation runtime
- a serious demo-production system
- a tool an agent can use confidently

## What We Learned From Prior Work

### From `vif`

Keep:

- ambition around browser/app automation plus media output
- promo/demo orientation
- support for overlays, audio, and export
- the insight that this is useful for AI-agent workflows

Do not keep:

- loosely bounded product surface
- CLI-owned lifecycle complexity
- runtime state spread across unrelated modules
- architectural drift caused by feature accumulation

### From `stage`

Keep:

- cleaner module instincts
- stronger agent-tool framing
- the desire for explicit capabilities and clearer boundaries

Do not keep:

- incomplete lifecycle/error handling
- underdeveloped reliability story
- early-stage abstractions that still need significant hardening

### From Recordly

Borrow:

- the render-time polish mindset
- auto zoom and stylish motion language
- cursor smoothing and emphasis
- project/artifact-oriented composition

Do not borrow:

- editor-first assumptions as the primary architecture
- GUI-centric runtime control

### From Stagehand

Borrow:

- the conceptual separation of `observe`, `act`, and `extract`
- conservative, inspectable target resolution
- agent-friendly interaction model

### From Peekaboo

Borrow:

- native-first Swift ownership of macOS automation concerns
- explicit permission handling as a first-class product concern
- thin consumer surfaces over a shared automation core
- the idea that visual feedback can be a distinct layer instead of being mixed into runtime truth

Do not borrow:

- a broad automation surface before the guided demo loop is solid
- product sprawl caused by trying to cover every macOS interaction mode too early

### From QuickRecorder and similar macOS-native tools

Borrow:

- native-first capture fidelity
- macOS-specific optimizations
- acceptance that cursor, capture, and media quality are better when treated as native concerns

### From Remotion

Borrow:

- rendering and templating as a backend capability
- separation of composition from capture/runtime concerns

Do not borrow:

- the temptation to make the rendering layer define the whole product

## Product Vision

The ideal end-state for `action` is:

1. an agent can inspect an app or website
2. resolve meaningful targets safely
3. execute a demo scenario deterministically
4. record raw media and rich metadata
5. automatically produce a polished output with zooms, cues, subtitles, and audio

The user should not need to hand-author every coordinate or every transition.

The user should be able to define intent, constraints, and style, while `action` handles the hard parts around:

- target resolution
- runtime stability
- capture fidelity
- metadata collection
- composition orchestration

## What `action` Should Be Great At

### 1. Agentic Demos

An AI agent should be able to:

- inspect available windows and surfaces
- resolve likely targets
- ask for confirmation when resolution is ambiguous
- execute a feature demo in a repeatable way

### 2. Product Storytelling

The output should feel closer to a polished product walkthrough than a raw screen recording.

That means:

- chapter cues
- focus guidance
- subtitles
- tasteful zooming and reframing
- cursor clarity
- music and narration support

### 3. Deterministic Runs

A run should leave behind a trace that explains:

- what was observed
- what targets were resolved
- what actions were taken
- what failed or was ambiguous
- what assets were produced

This is essential both for debugging and for agent trust.

### 4. Strong Native Fidelity

The system should feel designed for macOS, not merely compatible with it.

That includes:

- ScreenCaptureKit quality
- Accessibility API targeting
- native window handling
- native cursor and input behavior

## What We Explicitly Do Not Want

- a haunted runtime with hidden background state
- click automation that guesses recklessly
- a giant scene DSL that becomes the true implementation
- a framework that claims to be universal before it is reliable
- premature editor complexity
- a product that is visually polished but operationally fragile

## Design Taste

`action` should feel:

- deliberate
- inspectable
- native
- cinematic
- composable
- dependable

The cinematic part matters. This is not merely automation; it is automation in service of making good-looking software demos.

## v0 Aspiration

The first successful version of `action` should let a user or agent:

- define a short demo scenario
- run it against a macOS app or browser flow
- get a raw capture plus trace
- generate a polished edit with:
  - zooms
  - click emphasis
  - labels or chapters
  - subtitles
  - optional voice/music

That would already be meaningfully better than either a plain recorder or a plain automation tool.

## Strategic Direction

`action` should be built as a stable core with borrowable edges.

The system should own:

- runtime behavior
- session model
- targeting model
- trace model
- render manifest

And it should delegate where appropriate:

- Remotion for polished render backends
- FFmpeg or similar tools for specific media-processing tasks
- browser adapters for DOM-specific observation and action

This allows the product to move quickly without surrendering architectural control.

## Working Name

`action` is a good working name because it fits the cinema lexicon and reinforces the runtime emphasis.

It may or may not be the final public name. The architectural direction matters more than the branding for now.

## Fast-browser-experiment

# Fast browser experiment

Action's Chrome companion has an opt-in observation-bound execution path inspired by
[Jev Ultrafast](https://github.com/browser-use/jev-ultrafast). It uses the existing
Chrome companion bridge and an explicit tab ID. It does not change native Action
execution or Lattices app behavior.

## Run

Build the companion with `bun run chrome:companion:build` and reload the development
extension in the dedicated Action browser profile. The bridge must be running and
connected. This source change does not update an already loaded extension.

Create a trusted local policy module, for example:

```ts
import { createFastBrowserPolicy } from "@action/runtime";
export default createFastBrowserPolicy({
  baseURL: process.env.ACTION_FAST_MODEL_BASE_URL!, // API base, including /v1 if required
  apiKey: process.env.ACTION_FAST_MODEL_API_KEY!,
  model: process.env.ACTION_FAST_MODEL!,
  textModel: process.env.ACTION_FAST_TEXT_MODEL,
  // Define an independent, task-specific outcome assertion before starting.
  // Example for a goal whose outcome is reaching one exact article:
  verify: async (_goal, page) => page.url === process.env.ACTION_FAST_EXPECTED_URL,
});
```

From the Action product directory:

```sh
bun packages/cli/src/fast-browser.ts <tab-id> <policy-module-path> '<goal>'
```

The policy module is executable operator-supplied code. Never load a module named
by page content or model output. Model calls use an OpenAI-compatible JSON chat
completion endpoint. The caller selects models; no vendor or model is pinned.
This provider combines operation and target in one JSON response. It does not
implement TypeSafe's speculative heads or imply equivalent inference latency.

## Contract

- `action.fast.observe`, params `{ surface: { tabId } }`, returns an observation ID,
  URL, title, bounded visible text, and at most 80 controls with compatible operations.
- `action.fast.act`, params `{ surface: { tabId }, observationId, target, operation,
  text? }`, returns `executed`, `stale`, `invalid`, or `uncertain` and execution timing.
- Only CLICK and TYPE_TEXT are offered. Text generation is separate and invoked
  only for TYPE_TEXT. Password/file fields and unsupported input types are excluded.
- Each observation can be consumed once. A new observation replaces the previous
  one. Targets retain DOM node identity; execution never resolves a model selector.
- Before input, check document URL/viewport/form values, target semantics and nearby
  context, eligibility, current geometry, and occlusion. Unrelated changes outside
  the target's context do not automatically invalidate a decision.
- Confirmed stale rejections may retry from a fresh observation. Lost execution
  replies and uncertain mutations stop the loop. Executed means input was issued;
  it does not prove the application accepted it.
- DONE requires a fresh observation and the caller's independent verifier. False
  verification ends as `unverified`. The default budget is 20 decisions.

Each step emits observe, choose, text, and execute durations. Execution receipts are
emitted before another observation. Total elapsed time includes initial observation
and final verification, but excludes browser setup and policy module loading.
The snapshot also reports time inside the DOM reader. JSON traces can contain
field-derived/page information; store them appropriately for the task.

## Verify and measure

```sh
bun test packages/runtime/src/fast-browser.test.ts packages/runtime/src/providers/fast-browser-model.test.ts
bun run typecheck
bun run chrome:companion:build
# Supply a Playwright module path if it is not installed locally.
ACTION_PLAYWRIGHT_MODULE=/path/to/playwright \
ACTION_CHROME_EXECUTABLE=/path/to/chrome \
bun packages/chrome-companion/scripts/check-fast-actions.mjs
```

The browser checks run the actual content-script message handlers in an isolated
headless browser. They cover changed/replaced/covered/hidden/disabled/moved targets,
form changes, unrelated updates, duplicate requests, invented targets, and typing.
They do not exercise the installed extension's bridge or a live model. A
recorded presentation run is reproducible via
`packages/chrome-companion/scripts/demo-presentation.mjs` (dedicated fixture
browser, video artifact under `artifacts/presentation-demo-*`).

Compare identical tasks and model settings with the existing path, retaining failed
runs. Report independent completion, wrong actions, stale rejections, uncertain
execution, timings, and model cost separately. No speedup has been established by
these implementation/guard checks.

Limitations: common light-DOM controls only; no frames, shadow DOM, canvas, native
selects, scrolling, arbitrary keyboard widgets, or full page stabilization.
Text and target context are bounded and do not implement the full accessible-name
algorithm. The extension uses DOM click/value events, which may be rejected by sites
requiring trusted physical input. After executed input, the loop waits up to two seconds for a visible snapshot
change before choosing again. An unchanged snapshot blocks rather than repeating
input. Unrelated visible changes can also release this wait; it is not a general
page-ready signal. All decisions count toward the budget. One loop at a time per tab.


## Live Jev runner

`createJevPolicy` calls TypeSafe System One with the `jev-latest` alias. Operation,
click target, and typing target use parallel choice heads in one request. The
runtime consumes only the target head matching the selected operation and records
the concrete model version, confidence, probabilities, and usage. Typing content
comes from a separately configured text provider.

From the Action directory, with the extension connected to its local bridge:

```sh
# Inject credentials through your secret manager; do not put them in source.
# TYPESAFE_API_KEY is required. Typing also needs TEXT_MODEL,
# TEXT_MODEL_BASE_URL, and TEXT_MODEL_API_KEY.
bun scripts/demo-jev.ts <tab-id> <exact-result-url> '<goal>'
```

`TYPESAFE_MODEL` optionally overrides the alias. `ACTION_DEMO_OUTPUT` selects the
artifact directory. Use a fresh directory per attempt. The runner saves decisions,
execution receipts, timings, and an independently checked exact destination URL.

Live evidence on 2026-09-19: Jev resolved to `jev-1.13.0` and drove the installed
Action extension from Wikipedia's main page to Gödel's incompleteness theorems.
The corrected run took 2774 ms: TYPE_TEXT, CLICK, DONE, with the destination URL
verified. Google Gemini Flash Lite supplied the search text. The preceding run
repeated Search while navigation was pending; this prompted the progress wait and
its regression tests. This is a single task result, not a comparative benchmark.
The replay captures Chrome's actual rendered frames; desktop capture was unavailable
because the dedicated window remained on another macOS Space.


## Watchable mode

Set `ACTION_WATCH=1` for the single-search runner. The transport activates the
explicit tab and focuses its Chrome window. The executor shows a soft coral
disc pointer and target outline before input, revalidates after the movement,
and shows an input receipt. This is a synthetic Action pointer, not the OS
cursor. Confirmed clicks bloom ripple bubbles at the point of input; stale
rejections never produce a bubble or pulse. TYPE_TEXT enters text in real
progressive chunks, and each chunk plays a subtle WebAudio tick and outline
flash — sound marks characters actually written, never simulated replay.
`ACTION_SOUND=0` mutes ticks; `ACTION_VOLUME` (0–1, default 0.35) sets tick
level. Reduced-motion settings skip spatial animation and bubbles. Feedback
lives in an isolated, non-interactive closed shadow tree excluded from
observations and target resolution. Presentation time is included in execution
timing, so compare it separately from fast mode. Native recording captures it
when the Chrome window is on screen.

`bun scripts/demo-jev-ten.ts <tab-id>` runs ten Wikipedia searches with this mode,
independent exact-URL verification, per-search traces, and 2.2-second result holds.
It stops on failure or uncertainty and writes `summary.json` after every result.
Supply the same Jev and text-provider environment as the single-search runner.

Navigation receipts for same-tab links and form submission require a changed URL
before the next decision; changing autocomplete suggestions alone are insufficient.
Brief missing-content-script errors during navigation retry observations only.
Input is never replayed on a lost execution reply.

## Native-runtime.agent

# Native Runtime (Agent)

## Ownership Model

### `Action.app`

Owns:

- AppKit lifecycle
- launcher UI
- WebKit windows
- menus and app identity
- recording probe mode

Primary files:

- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- [ActionLauncherController.swift](native/engine/Sources/ActionLauncherController.swift)
- [ActionLauncherViewModel.swift](native/engine/Sources/ActionLauncherViewModel.swift)

### Agent Runtime

Owns:

- WebSocket listener
- request dispatch
- automation method surface
- launching the recording probe

Primary files:

- [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionAgentClient.swift](native/engine/CoreSources/ActionAgentClient.swift)
- [ActionAgentCommandBridge.swift](native/engine/Sources/ActionAgentCommandBridge.swift)

## Recording Rule

- Do not implement real recording directly in the headless agent path.
- Use [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift).
- The probe launches `Action.app` with `recording-probe` args.
- The probe runner performs the actual `WindowRecorder` call.

## WebKit Rule

- WebKit belongs to the app lifecycle.
- If a change touches browser windows, inspect the AppKit entry path before changing configuration.

## Debug Order

1. Confirm the signed app build exists.
2. Confirm whether the failure is app lifecycle, agent transport, or probe execution.
3. For recording, inspect `.mov`, `.finished`, and debug log together.
4. Do not trust initial `"recording"` replies as proof of completion.

## Overview.agent

# Overview (Agent)

## Project

- Name: `action`
- Type: monorepo with native macOS runtime focus
- Primary native surface: `Action.app`
- Primary automation surface: local WebSocket agent runtime

## Current Truth

- Native app lifecycle matters more than CLI convenience for WebKit and recording.
- `Action.app` is the owner of AppKit lifecycle, menus, WebKit, and permission UX.
- Recording stability currently depends on running capture in a fresh app instance via `recording-probe`.
- The agent is for transport and orchestration, not for pretending to be a full UI lifecycle host.

## Entry Points

- Root framing: [README.md](README.md)
- Native host main: [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- Agent runtime: [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- Recording probe launcher: [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- Recording probe app runner: [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)

## Use This Page For

- quick repo orientation
- understanding app-vs-agent ownership
- finding the files that currently define runtime truth

## Do Not Assume

- that command-mode execution owns the correct macOS UI lifecycle
- that the agent should directly host all AppKit-dependent behavior
- that older architecture docs always describe the latest capture implementation details

## Recording.agent

# Recording (Agent)

## Status

- Region recording: working through app-backed probe path
- App-window recording: working through app-backed probe path
- Success artifacts: `.mov` + `.finished`

## Control Flow

1. caller invokes `record-region` or `record-app-window`
2. host sends request to agent
3. agent calls [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
4. launcher runs `open -n Action.app --args recording-probe ...`
5. probe runner uses [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)
6. probe uses `WindowRecorder` inside a real AppKit lifecycle

## Files To Read

- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)

## Debugging Rules

- Initial `"recording"` response is startup ack only.
- Finished marker is the completion signal.
- If present, `--debug-log` should be inspected before changing capture configuration.
- If recording fails again, validate lifecycle assumptions before tweaking `ScreenCaptureKit` settings.

## Invariants

- Recording implementation should stay app-backed until a safer replacement exists.
- Probe mode must remain available from the signed app bundle.
- App lifecycle correctness is a recording dependency, not an optional detail.

## Remote-engine

# Remote engine

Action can drive another machine that runs a lattices host (LAT-013), such as
a Linux desktop running `lattices-host`. Runs, traces and artifacts stay on
this machine; the remote host does the observing and acting.

```sh
ACTION_REMOTE_HOST=archie bun packages/mcp/src/index.ts     # MCP server against archie
ACTION_REMOTE_HOST=archie:9400 ACTION_REMOTE_FPS=8 ...      # port and recording rate
```

`action.health` reports the host's platform and capabilities in
`diagnostics`. From there the usual tools work: `action.observe.snapshot`
(surface, screenshot, OCR on the host), `action.observe.ocr`,
`action.resolve.target` (by point, or by text through the host's fuzzy OCR
search), and `action.act.execute` (click, type, press-key, drag, scroll,
focus-window, open-app).

What stays native-only, with a clear error: `action.observe.ax` (Linux has
no accessibility tree here), `action.record.*` (guided sessions record
through the engine instead), the stage and backdrop overlays, and the
companion worker.

In code, `RemoteEngine` (`packages/runtime/src/remote.ts`) implements
`CaptureEngine` and `SurfaceEngine`; `remoteEngineFromEnv()` builds one from
the environment.

## Theming.agent

# Theming Action

> How to write a theme for Action's native app, and what the app will refuse to
> paint with. Written for an agent that has been asked to personalise the UI.

## The short version

Write a JSON file into `~/Library/Application Support/Action/Themes/`. The app
picks it up within a fraction of a second — no restart, no protocol call. Select
it in **Settings ▸ Appearance ▸ Palette**, or set it directly before launching the app (changing this default while Action is running requires a relaunch):

```bash
defaults write dev.lattices.Action Action.ThemeID "reading-room"
```

A theme is a **patch**, not a palette. Everything is optional, and what you do
not mention keeps the tuning it already had. The smallest useful theme is six
lines.

## The model

Action has four surfaces, and they are not variations of each other:

| Surface  | Where | Voice |
|----------|-------|-------|
| `chrome` | The launcher shell: rail, footer, cards, ledgers | Neutral. The frame around the work, not the work. |
| `field`  | Home | The brand's own: paper in light, graphite in dark. |
| `review` | The review screen | A cool neutral sheet, so the page never fights the thing being reviewed. |
| `hud`    | The capture HUD | A fixed dark instrument face. Deliberately the same in both appearances. |

Each of `chrome`, `field` and `review` is an `ActionSurface`: a ground, the
things that sit on it, the lines that divide it, the ink that goes on it, and
the two colours it speaks with.

```
canvas ─── the page
  band ─── a chrome band across an edge of it (rail, title bar, footer)
  panel ── a card laid on it          panelRaised ── the same card, hovered
  recess ─ a well cut into it         deep ───────── the block that stays dark
  edge · rule · grid · shadow ─────── the lines
  ink · inkSecondary · inkRow · inkMuted · inkMeta ── the ramp, darkest first
  onDeep · onDeepMeta ─────────────── what goes on `deep`
  accent · accentInk · accentSoft ─── runtime truth
  signal ──────────────────────────── the secondary voice, never competing
```

Two rules the palette encodes, and a theme should not break:

- **Coral means this Mac is being driven right now.** It is the same value in
  light and in dark on purpose. The colour that means "running" must not depend
  on the operator's appearance setting.
- **A recess sits *below* the canvas where a panel sits above it.** Panels are
  content on the surface; a recess is a window cut into it showing the machine's
  state. Inverting that inverts the hierarchy.

## Three levels of reach

Use the coarsest one that does the job. A file may use all three.

### 1. `seed` — regrow a whole surface

Give a surface a ground, an ink and an accent and the other eighteen slots are
computed:

```json
{
  "id": "dusk",
  "name": "Dusk",
  "extends": "action",
  "surfaces": {
    "field": {
      "seed": {
        "ground": { "light": "#EFEAE0", "dark": "#101415" },
        "ink":    { "light": "#1C2427", "dark": "#EFEAE0" },
        "accent": "#EF6A47",
        "signal": "#1FB9C6",
        "lift": 1.1
      }
    }
  }
}
```

Seed fields: `ground`, `ink`, `accent` (required); `signal`, `deep`, `lift`
(optional; `lift` defaults to 1 and scales how far apart the grounds sit).

The derivation works in **L\***, not in "mix N% toward white", because those are
not the same move on paper and on graphite. Seeded with Action's own ground and
ink it reproduces the shipped surface to within about three L\* on every ground and
every ink step. What it deliberately does *not* reproduce:

- `inkMuted` — Action's field tan is a decision, not a point on a ramp. Override
  it if you care about it. It is the single slot most worth overriding.
- `accentInk` — the derivation picks whichever of the ink and the ground the
  accent can actually carry. Action's own cream-on-coral is 2.8:1 and the
  derivation would pick the darker option instead.

### 2. `tokens` — patch named slots on a surface

```json
"surfaces": {
  "field": {
    "tokens": { "inkMuted": { "light": "#9C7452", "dark": "#7B8785" } }
  }
}
```

Any of the 21 slot names listed above. A name that is not a slot is reported as
an error rather than ignored.

### 3. `overrides` — patch one painted token

The last resort, for the one place a rule does not fit. Keys are the app-facing
token names (`fieldCanvas`, `runSelectionHover`, `hudCoral`, …) — the full list
is `ActionToken` in `native/engine/Sources/ActionTheme.swift`.

```json
"overrides": { "rowAlternate": { "light": "#00000008", "dark": "#FFFFFF0A" } }
```

## The rest of the file

```jsonc
{
  "id": "dusk",                 // required, unique; the value Action.ThemeID takes
  "name": "Dusk",               // shown in the picker
  "author": "…",
  "summary": "One sentence, shown under the picker.",
  "extends": "action",          // built-in theme to start from; defaults to "action"

  "status":  { "ok": "#2E8B57", "failed": "…", … },   // run outcomes + ledger washes
  "control": { "primaryTop": "…", "primaryBottom": "…" },
  "hud":     { "coral": "…", "coralHot": "…", "cyan": "…", "amber": "…", "polish": 1.0 },

  "metrics": {
    "cornerRadius": 8,          // cards and panels
    "cornerRadiusSmall": 6,     // chips, buttons, selection washes
    "hairline": 1,
    "density": 1.0,             // row heights and padding, 0.85 … 1.35
    "grain": 1.0,               // every texture alpha
    "shadowStrength": 1.0
  },

  "type": {
    "editorial": "Charter",     // "system" or a missing face falls back to New York
    "mono": "JetBrains Mono",   // a missing face falls back to the platform monospace
    "scale": 1.0                // 0.85 … 1.3, applied to the whole scale
  }
}
```

`extends` accepts built-in theme IDs only; file themes do not form inheritance chains.

`status` slots: `ok`, `running`, `failed`, `stopped`, `recording`, `paused`,
`rowAlternate`, `selection`, `selectionHover`, `actionChip`.

The HUD only accepts tints and a `polish` level. It does not accept its
machining, on purpose: a theme that could restyle the capture HUD could change
what "recording" looks like on a Mac somebody else is driving.

### Colour spelling

Two forms, both accepted anywhere a colour is:

```json
"accent": "#EF6A47"
"canvas": { "light": "#F3EBDD", "dark": "#14191A" }
```

`#RGB`, `#RRGGBB` and `#RRGGBBAA` all parse. A malformed value is an error that
names the key — it is never silently replaced with a default.

## What the app checks before it paints

Every theme is validated **in both appearances** before installation. This is
the half a human skips, because they are only looking at one mode.

**Contrast.** Twenty foreground/background pairs the app actually renders, each
against the ratio it needs — 4.5:1 for body text, 3.0:1 for status dots, chips
and large text. Alpha is composited onto the background first, so a muted ink
written as "ink at 55%" is scored as what is actually seen.

**Separation.** Five pairs of grounds that have to stay at least 1.2 L\* apart,
or the hierarchy they encode disappears — a card that is the same colour as the
page is not a card.

**Alarm distinction.** The accent and idle accent are compared with the failure
colour. Below 28 ΔE they are close enough that a 6pt dot or a 2pt rule in one
can be mistaken for the other, and you are told so. Only pairs your theme
actually moved are checked — an accent you inherited unchanged is the base
theme's decision, not yours. This check is advisory and never blocks
installation.

For contrast only, a result below three quarters of its target is an **error**;
other contrast failures are warnings. Separation and alarm findings are always
warnings.

- **Warnings** are shown in Settings ▸ Appearance and the theme still installs.
- **Errors** mean the theme is *not* installed. Action keeps painting with the
  built-in one and shows you why in the same place.

So the iteration loop is: write the file, look at Settings ▸ Appearance, fix what
it tells you, save again. The app reloads on every write.

## Worked examples

`themes/linea-dusk.json` — a complete imported palette. `themes/reading-room.json`
— metrics and type only, for a recording an audience watches from across a room.
Copy either into the themes folder to try it.

## Where things live

| | |
|---|---|
| `native/engine/Sources/ActionTheme.swift` | Surfaces, seeds, the derivation, the token list |
| `native/engine/Sources/ActionThemeBuiltin.swift` | The house theme, transcribed slot for slot |
| `native/engine/Sources/ActionThemeSpec.swift` | The file format, the merge, the validator |
| `native/engine/Sources/ActionThemeStore.swift` | Loading, watching, installing |
| `native/engine/Sources/StageHUDTheme.swift` | The façade views paint through |
| `themes/` | Worked examples |

---
Generated by [Dewey 0.3.6](https://github.com/arach/dewey) | Last updated: 2026-11-06