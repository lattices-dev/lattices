---
name: action
description: Drive native macOS surfaces with Action. Use when observing the screen, resolving targets, clicking or typing through Action.app, working an app off the user's screen on the agent layer, recording a capture, or choosing between Action-owned Chrome and the user's regular browser.
metadata:
  compatibility: Requires macOS with Action.app and the Action MCP server.
  author: arach
  homepage: https://lattices.dev/action
---

# Action

Action is native computer-use. Action.app owns AppKit, permissions, and
recording. Agents drive it through MCP. Do not reimplement capture or
accessibility.

When this skill is invoked, observe first, then act. Show the user what you
saw. Do not claim a recording finished until the finished marker or
`record_status` says it did.

Workspace tiling and tmux sessions belong to the `lattices` skill. Spatial
notes belong to `blink`.

## Choose the surface

| Need | Surface |
| --- | --- |
| Read public content without page interaction | HTTP retrieval, when sufficient; no browser or display needed. |
| Interact with a web page in the background | Action Browser's `browser_*` DOM tools on an Action-owned identity. Background opening does not establish desktop isolation. |
| Keep an app or browser on a private display | Action MCP `layer_*`, only after the private-layer preflight below. |
| Work in the user's existing app or regular Chrome | Native observe, resolve, act; input may affect focus or the pointer. |

Keep the requested surface throughout the task. A failed private layer does
not authorize an ordinary browser, and a failed CDP operation does not
authorize native input or foregrounding Chrome.

## Inspect, act, verify, close

1. Inspect the selected surface and retain its session, tab, and lease identity.
2. Act on targets from that observation. Refresh it after navigation or changes.
3. Verify the requested result with a fresh observation; a successful input
   response alone is not task completion. Show relevant visual evidence.
4. Close only resources this task owns and release its leases, including on
   failure. Confirm cleanup when the close response is uncertain.

## Private-layer preflight

Use the names in the active MCP `tools/list`. Current servers advertise
underscore names (`capabilities`, `layer_open`, `drive_begin`). Dotted
`action.*` names are compatibility aliases only when the server advertises them.

Before opening a private layer:

1. Run `lats action capabilities` for read-only runtime discovery.
2. Call MCP `capabilities` and inspect the active `tools/list`. Require
   `layer_open`, `layer_snapshot`, `layer_click`, `layer_type`, `layer_js`,
   and `layer_close` for the private-browser workflow.
3. Read the [agent-layer deployment and acceptance reference](https://github.com/arach/lattices/blob/main/products/action/docs/agent-layer.md)
   (source: `products/action/docs/agent-layer.md`). Verify the matched runtime
   and `acceptance.privateLayer.state: accepted` for this host and display
   configuration. Missing, stale, invalid, or unverified evidence means stop.
4. Check `safety.privateLayer`. If blocked, stop. Do not clear the quarantine,
   retry through another transport, rebuild on an installation target, or
   substitute a regular/background browser for requested isolation.
5. Check `layer_status` before opening. An existing layer may belong to another
   caller; opening would replace it. Do not replace it without user authority.
6. Check `lats action layer display-status`. Tasks require an already prepared
   persistent monitor. Missing or stale monitor state means stop; explicit
   `lats action layer prepare` is a setup operation that can change the desktop,
   not an automatic fallback. See the reference before provisioning.

Reconnect MCP after runtime updates and repeat discovery. An older server
without these fields is unverified. `health` reports permissions and runtime
health, not isolation. Controlled display QA needs authorization for that host;
ordinary task approval does not authorize it. CLI and raw WebSocket calls do
not replace MCP browser orchestration. Lattices workspace layers are a
separate window-group feature.

## Drive loop

1. Call `driver_identify` once when the connection does not already
   name the agent.
2. Call `drive_begin` with an agent identity and a short task.
   Background is the supported drive mode.
3. Pass the returned `leaseId` to observe and act calls.
4. Call `drive_note` before each beat so the supervision HUD shows
   the current step.
5. Call `drive_aim` to move the synthetic cursor and highlight a
   region, then act.
6. Prefer `observe_snapshot` and `resolve_target` before
   `act_execute`.
7. Call `drive_release` when the work ends.

`drive_play` runs a named list of beats (note, aim, wait, act) as
one sequence. `stage_set` declares a color drape plus the windows
that sit on it. Never write the desktop picture.

## Agent layer

A layer attaches a task to a prepared private monitor and shows it through a PiP viewer.
The physical desktop must pass the preflight above before this path is used.
For browser work, prefer Action-owned Chrome with `browser: true` and CDP:

```text
layer_open      { browser: true, url: "https://example.com", task: "Read the page" }
layer_snapshot  {}
layer_click     { x, y } in the last layer snapshot, or { label }
layer_type      { text }
layer_js        { code: "document.title" }
layer_close     { outcome: "done", summary: "Read the page" }
```

Use `layer_go` for navigation. The layer begins a drive lease unless you pass
an existing `leaseId`; `layer_close` releases a lease it created. A supplied
lease stays owned by its caller, who must release it. Do not begin a
second drive for it. Use `layer_snapshot` and `layer_*` primitives instead of
`observe_snapshot` and generic input on the user's screen. Snapshot coordinates
use the last layer image's crop and scale.

Retain `session` from `layer_open` and compare it with `layer_status` after a
reconnect or failure. Browser actions report `route: "devtools"` and
`pageTargetId`. Browser mode refuses missing CDP, unresolved targets,
browser-chrome coordinates, and unsupported shortcuts instead of falling
back to native input. Use `layer_go` rather than address-bar shortcuts. If the
session changed, stop; do not adopt another caller's layer or reuse its image.

For a native app, use `{ bundleId }` or `{ pid }`. To borrow selected windows,
add `windowId` or `windowTitle`; this preserves the app's other windows.
Native input can use temporary focus/pointer blinks. Those gestures are not
continuous focus isolation. Do not promise "nothing on your screen moves"
for a path that uses them. Ordinary `background: true` also does not provide
private-display isolation.

One layer runs at a time. Opening another closes the current layer first.
`layer_record` records the layer; `layer_pip` shows its viewer again.
The operator owns Pause / Resume, Stop, and Take over. If paused, wait for
resume. Stop and Take over gate further layer input during teardown and after
cleanup; closing does not clear that handoff. Report it and obtain fresh user
authority before explicitly opening another layer. Stop does not stop the
whole agent harness. Hide only hides the viewer; Agent locates the local opener,
not a conversation on another machine.

Close the layer when work ends, including failed setup. Check `layer_status`
if closure is unconfirmed. Never close a layer owned by another caller.
Borrowed windows return to recorded frames. Windows created on the layer are
closed; an unsaved-changes prompt can leave one open. MCP exit tears down its
owned layer. CLI layers are detached and require `layer close`.
Task closure leaves the persistent monitor connected. Only explicit
`lats action layer release` closes the task and disconnects the monitor;
provisioning, release, and recovery after a monitor-owner restart can change
the desktop topology and are separate from ordinary task interaction.

Acceptance must compare physical display mode, scale, arrangement, frontmost
app, pointer, and unrelated window frames throughout open, interaction, and
close. Restoring them after a disruption does not pass acceptance.

## Observe, resolve, act

Inspection:

```text
health
session_create
observe_snapshot
artifacts_list
```

Target-first input:

```text
observe_snapshot
resolve_target
act_execute
observe_snapshot
```

Prefer semantic, AX, or text queries over coordinates. Use coordinates only
when Action cannot resolve the target another way.

## Recording

```text
session_create
record_start
record_status
record_stop
artifacts_list
```

`record_start` is an acknowledgement only. Completion is the `.mov`
file, the `.finished` marker, and `record_status`. Keep
`recordingId`, `outputPath`, `stopFile`, and `finishedFile` until the run
is complete.

## Which browser

| Surface | Control |
| --- | --- |
| The user's regular Chrome | Open-only with `browser_open { mode: "regular" }`. Then native Action: snapshot, resolve, act. |
| An Action-owned Chrome identity | DOM tools over CDP: snapshot, click, fill, resize, screenshot. |
| An Action identity seeded from a real profile | DOM tools on sites the user is already signed in to, after a domain-allowlisted cookie import. |
| Action's Chrome on the agent layer | `layer_open { browser: true }`: a dedicated browser port and default `agent-layer` profile, with `layer_go` and `layer_js`. Supply `profile` for a chosen identity. |

Regular Chrome is not a DOM target. Chrome 136 and later ignore remote
debugging on the default profile. Seed an Action identity when the page
needs the user's login.

Action Browser's tools are the browser toolset of `lattices mcp`. Register the
binary rather than a checkout-specific server path:

```bash
claude mcp add lattices -s user -- lattices mcp
```

The Action Browser plugin carries its skill, not the server. If browser tools
are missing, check `lattices mcp --list`, then the harness's MCP configuration.

Cookie import requires `confirm: true` and a domain allowlist. Do not
submit purchases, publish, or delete without the user's authority.

## Live docs

1. https://lattices.dev/action
2. `products/action/docs/browser-profiles.md`
3. `products/action/docs/recording.md`
4. `products/action/docs/native-runtime.md`
5. `products/action/docs/agent-layer.md`
