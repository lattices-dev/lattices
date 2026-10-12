# Agent layer

Action's agent layer attaches an app or Action-owned browser to a prepared,
persistent virtual monitor. The monitor and each task have separate lifetimes.
Use MCP for the complete browser workflow.

## Prepare the monitor once

Provision the monitor explicitly when the user is ready for a display topology
change. Preparation creates the virtual display and may change macOS modes,
arrangement, or window placement; it does not promise an unchanged desktop.
Check capabilities and quarantine first. Preparation never clears quarantine.

```bash
lats action layer display-status
lats action layer prepare --width 1440 --height 900
```

`display-status` is read-only. `prepare` reuses an existing live monitor when
the requested size matches, or when no size is supplied. A new monitor defaults
to 1440×900. A different size requires explicit release and preparation; an
ordinary task must not silently resize or recreate the monitor.

Once prepared, `layer open` attaches a task without connecting another display.
`layer close` restores that task's windows and leaves the monitor connected.
When the user wants to disconnect the monitor, use `lats action layer release`;
it first closes the task, then releases the persistent display. Release can
also change the desktop topology. A restart, crashed monitor owner, or missing
monitor requires explicit preparation again, not automatic recovery during
the next task.

## Check capabilities before opening

Run `lats action capabilities`, then call `capabilities` on the active MCP
connection. Check its `tools/list` for `layer_open`, `layer_snapshot`,
`layer_click`, `layer_type`, `layer_js`, and `layer_close`.
Use `lats action layer display-status` to confirm a prepared monitor is active.
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
Check `layer_status` before the first open too: opening replaces an existing
layer. Do not replace another caller's layer without user authority.

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

Read-only lookup is `lats action capabilities` or MCP `capabilities`, under
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
- Keeps one layer at a time. Opening a second layer closes the first, so its windows go back before the new app moves.

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
`layer release` explicitly closes any task and then stops the persistent
monitor owner. It must not disconnect the monitor when task closure fails.

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
