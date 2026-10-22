# lattices-host

Expose a Linux desktop to other lattices machines, so a Mac (or an agent on
one) can list, place, see and drive its windows over your tailnet. This is
[LAT-013](../../docs/proposals/LAT-013-linux-host.md).

It speaks the Mac daemon's protocol: the same `{id, method, params}` envelope,
the same LAT-012 method names, and the same response shapes. Point the CLI at
it and the usual commands work:

```sh
lats --host archie pair                         # once per client machine; approve on archie
lats --host archie call host.describe
lats --host archie call windows.list
lats --host archie call windows.place '{"app":"firefox","placement":"left"}'
LATTICES_DAEMON_HOST=archie lats call capture.still '{"maxWidth":1280}'
```

## Run it

Needs Bun, a Hyprland session, and Tailscale.

```sh
bun packages/host-linux/src/main.ts             # private Unix sockets in ~/.lattices/run
bun packages/host-linux/src/main.ts --describe  # print capabilities and exit
lats gateway start --tailnet                    # remote access on the tailnet address, port 9399
```

Or as a systemd user service: see `systemd/lattices-host.service`.

### Which build is running?

Both **host.describe.build** and **daemon.status.build** contain:

    { "version": "0.1.0", "commit": "<full Git revision>", "dirty": false }

The existing top-level version stays intact. The version comes from this
package's package.json, not a second hard-coded constant. A source run snapshots
HEAD and the host package's tracked/untracked dirty state **once at startup**;
editing the checkout or moving HEAD later cannot make an old process report
new code. If Git metadata is absent/unreadable, commit and dirty are null,
rather than a fabricated revision.

For a relocatable build with its identity embedded:

    bun packages/host-linux/scripts/build.ts
    bun packages/host-linux/dist/lattices-host.js --describe

Or inside the package: bun run build. Pass an output file as the script's first
argument to put it elsewhere. Building requires a known source commit and
preserves dirty: true when building uncommitted work. The emitted bundle can
run without Git/a checkout; optionally compile **that bundle** with
bun build --compile to make a standalone executable with the same identity.

Clients should compare build.commit as well as build.version; null is unknown,
not current. These fields cannot retrospectively identify an older running host
that predates this change. Deploy/restart only after its clients are ready for
the pairing protocol; do not restart the everyday host just to obtain metadata.

## Visiting cursor

Paired devices with `input.trackpad` can open the signed, encrypted `/visit`
WebSocket described in [docs/visit.md](../../docs/visit.md). A coral visitor
label moves across physical screens; `LATS-*`, headless, mirrored and other
virtual outputs are excluded. Quickshell is required for the overlay, and
wtype handles keystrokes and text. No new pairing capability is needed.

Ordinary visitor motion leaves the host pointer alone. Clicks and scrolling
move it to the visitor, and it stays there so `input:follow_mouse=1` preserves
the clicked window's keyboard focus. Dragging follows the visitor while a
button is held. Ending a visit releases held buttons and restores the host's
starting pointer position. Returning past the entry edge, disconnecting,
leaving, or six seconds without an authenticated frame ends the visit.

The host starts `quickshell -p packages/host-linux/visitor` on the first visit.
A private unix socket in `$XDG_RUNTIME_DIR` carries newline JSON positions on
one connection, coalescing updates if the reader falls behind. The overlay
hides immediately at the end and its process stops after one idle minute.
It does not modify the Omarchy shell or compositor configuration.

To test, run the host and its gateway, then point the test client at the
gateway from a tailnet machine:

```sh
bun packages/host-linux/src/main.ts
lats gateway start --tailnet
bun packages/host-linux/src/main.ts visit-test --host archie:9399 \
  --identity /tmp/lattices-visit-client.json --name mini
```

Approve its printed device ID in the notification, or on the host with
`lats call bridge.pairing.approve '{"deviceID":"…"}'`. The client
enters on the left and moves in a slow square, with encrypted pings every two
seconds. It remembers its key at `--identity`, so repeated runs reuse one
pairing. Without that flag it uses `~/.lattices/host/visit-test-key.json`.

`LATTICES_VISITOR_RUNTIME_DIR` optionally isolates the overlay's socket and
Quickshell runtime files; the default is the graphical session's runtime
directory. Run the host from the graphical session so its Hyprland and
Wayland environment variables are available.

## Omarchy tray

### Workspace navigation

`lats spaces` lists the displays and their spaces. `lats space next`, `prev`,
`previous`, or a positive workspace id calls `spaces.focus`. Relative switches
use Hyprland’s existing-workspace traversal; `previous` returns to the former
workspace. A numeric id can create an empty workspace. `--dry-run` returns a
plan without switching, and `--json` returns the receipt.

The RPC accepts `{ workspace: <id | "e+1" | "e-1" | "previous">, dryRun?: true }`.
It requires act scope for remote clients and never accepts arbitrary dispatcher
text. Invalid targets fail before contacting the compositor.

The tray is a small StatusNotifierItem and dbusmenu on the session D-Bus.
Omarchy's existing Quickshell tray renders it (inside the tray drawer unless
you pin it). Nothing is installed into `/usr/share/omarchy`, and no shell or
monitor configuration is changed.

Install from this checkout, inside the graphical session:

```sh
bun install --cwd packages/host-linux --ignore-scripts --omit optional
bun packages/host-linux/scripts/install-tray.ts
```

The installer renders units into `packages/host-linux/.systemd/`, with literal
paths to this checkout and the current Bun executable, and links them through
the systemd user manager. Keep this checkout in place. It enables and starts
`lattices-tray.service` with `graphical-session.target`, and links
`lattices-host.service` for the menu's Start/Stop controls. It leaves the host
disabled at login until you choose to enable it. Existing units from another
location are refused rather than replaced. Re-run the installer after moving
the checkout or changing the Bun executable (remove the old unit links first
if the checkout moved).

For a foreground run:

```sh
bun packages/host-linux/src/main.ts tray
```

The menu contains Bring Cursor Home, host and companion pairing status,
Start/Stop Host, and Quit. The lattice icon is monochrome. Quit exits only
the tray, leaving the host running; start it again with
`systemctl --user start lattices-tray`.

State refreshes when the menu opens and on systemd host unit changes.
The tray re-registers when Quickshell's tray watcher restarts. There is no
background polling. Pairing status reads the host's existing trust records.
If a host is already running outside `lattices-host.service`, Stop Host is
disabled: quit that foreground host before starting the managed service.

Bring Cursor Home also works without either the tray or the network host:

```sh
bun packages/host-linux/src/main.ts mouse-home
lattices-host mouse-home                 # if the package's bin is on PATH
lats --host archie call mouse.home       # when this host version is running
```

From the command line it first ends any visiting cursor on every host running
on this machine (see `docs/visit.md`), and reports that as `visits` in its
receipt. The `mouse.home` RPC leaves visits alone.

The target is the focused real
monitor, otherwise the first real monitor, excluding LATS/headless/virtual,
disabled and mirrored outputs. Coordinates account for scaling and rotation.
It tries `hyprctl dispatch movecursor X Y`, with the Lua cursor dispatcher
fallback required by Hyprland 0.55+.

`dbus-next` is the one direct dependency: it serves the notifier/menu and
talks to the systemd user manager without a GUI toolkit. The install command
omits its optional native Unix-FD addon and disables install scripts; these
interfaces use the JavaScript Unix-socket transport and need no native addon.

Remove the autostart and linked units with:

```sh
systemctl --user disable --now lattices-tray
systemctl --user stop lattices-host
rm ~/.config/systemd/user/lattices-tray.service ~/.config/systemd/user/lattices-host.service
systemctl --user daemon-reload
```

## Who can connect

The desktop runtime listens only on private Unix sockets in
`~/.lattices/run` (`lattices.sock` and `companion.sock`, each with a private
token). It opens no network port. Remote access is the separate, opt-in
gateway described in [packages/gateway](../gateway/README.md):

1. On the host: `lats gateway start --tailnet`. The gateway binds only this
   machine's verified Tailscale address, port 9399. Every connection is
   checked with `tailscale whois`: by default only devices owned by this
   machine's Tailscale user get in. Widen it with `--allow-user <id|login>`
   or `--allow-tag tag:name`. Loopback gets nothing through the gateway.
2. From the client: `lats --host archie pair` (or `--read-only`, or
   `--drive`). The CLI makes an X25519 key and id for this machine and calls
   `clients.pair`. It prints a code; wait.
3. On the host: `lats gateway clients`, check the code and the requested
   grants, then `lats gateway approve <clientID>` or `deny`. Approval runs
   only over the gateway's local socket, so a client cannot approve itself.
   Undecided requests are denied after two minutes.
4. Every later connection is signed: the WebSocket upgrade carries
   `x-lattices-device-id`, `-timestamp`, `-nonce` and `-signature`, an
   HMAC-SHA256 keyed by HKDF-SHA256 over the X25519 shared secret, over
   `GET`, the path, client id, timestamp, nonce and the empty body's hash.
   Timestamps must be within 2 minutes; a nonce is accepted once.

The gateway stores exact `product:method` grants. Its scopes (`read`,
`screen`, `act`, `drive`, `shell`) and their shorthands are in the gateway
README. Its trust records live in `~/.lattices/gateway`. The client side lives
in the device identity (`~/.lattices/identity/device.json`, see
`docs/security-identity.md`) and `~/.lattices/paired-hosts.json`
(each host's public key and the scopes it granted), keyed by `address:port`
and matched by the host's tailnet name too, so `--host archie` and
`--host 100.x.y.z` share a pairing. This works the same from macOS or Linux.

## What it can do

`host.describe` reports what this machine actually has. Each capability turns
on its methods; missing tools just hide them.

| Capability | Backend | Methods |
| --- | --- | --- |
| `windows.read`, `windows.place`, `spaces.read` | `hyprctl` (Lua dispatchers on 0.55+, legacy strings before) | `windows.list/get/search/resolve/focus/place/move/moveBack`, `spaces.list`, `desktop.snapshot`, `layers.list/members/create/assign/unassign/rename/delete/layout/activate/switch/reveal` |


| `displays.virtual` | `hyprctl output create headless` plus a monitor rule (`eval hl.monitor` on 0.55+) | `displays.create`, `displays.remove` |

| `capture.still` | `grim` | `capture.screenshotDisplay/Window/Region`, `capture.still` (inline JPEG) |
| `capture.live` | `wayvnc`, started on demand on the host's address | `capture.live` returns a `vnc://` URL for Screen Sharing |
| `input.keys` | `wtype` | `computer.typeText`, `computer.pressKey`, `computer.hotkey` |
| `input.pointer` | Wayland `zwlr_virtual_pointer_v1`, spoken directly; no root, no uinput | `computer.click/doubleClick/rightClick/drag/scroll/aim` |
| `sessions.tmux` | `tmux` | `tmux.list`, `sessions.launch/kill/detach`, `terminals.capture`, `computer.typeText` with `session` |
| `ocr` | `tesseract` on a grim capture (2x for `ocr.*`) | `computer.observe`, `ocr.read` (lines with screen boxes), `ocr.find` (fuzzy, tolerates misreads) |
| `capture.record` | grim frames at 1-15 fps, encoded by `ffmpeg` on stop | `capture.record` (`start`, `pause`, `resume`, `stop`, `status`) |
| `apps.open` | the compositor's exec dispatcher | `apps.open` waits for the new window |

Virtual displays are headless outputs (`virtual: true` in every Display). The
host records the ones it creates in `~/.lattices/host-displays.json` and only
removes those (`managed: true` in `host.describe`). An output made by hand stays
yours unless you hand it over with `displays.create {name, adopt: true}`.

`files.read` returns files under `~/.lattices/captures` in base64 chunks, so a
remote client can fetch the recordings and captures it asked for. Action's
`RemoteEngine` (LAT-013 phase 3) drives this host through these methods.

Every executed `computer.*` action emits a `computer.acted` event:
`{kind, label, point, to, wid, element, displayIndex, ratio, toRatio, at}`.
`point` is in global logical pixels, and `ratio` is that point within display
`displayIndex` (0-1), so a viewer can draw it on that display's
`capture.still`. Keyboard actions have no point; they carry the target or
focused window's display. Labels never include typed text. Subscribe with
`events.subscribe {events: ["computer.acted"]}`.

`computer.*` input methods stage by default and act only with
`treatment: "execute"`, as on the Mac. Mac modifier names are mapped:
`command` and `control` become ctrl, `option` becomes alt, `super`/`meta`/`win`
the logo key.

Events: Hyprland's event socket becomes `windows.changed` and
`spaces.changed`, pushed to every connected client.

## The iOS companion

lattices-host also speaks the companion bridge the iOS app uses with a Mac
(the same routes and security), so a Linux machine joins the phone's fleet
without app changes. The bridge listens on private `companion.sock`; the
gateway relays it on the tailnet.

1. Start the gateway (`lats gateway start --tailnet`), then add the host in
   the app by address: `archie:9399` over Tailscale. There is no LAN listener
   or Bonjour advertisement.
2. The host shows a notification, "Pair <device>?", with the device's code.
   Check the code matches the phone and approve. You can also approve on the
   host: `lats call bridge.status`, then
   `lats call bridge.pairing.approve '{"deviceID":"..."}'`. Requests nobody
   decides are denied after two minutes.
3. Every later request is signed and encrypted with keys from that pairing.
   `bridge.devices.revoke` forgets a device.

The deck shows the windows (switcher and layout preview), workspaces,
system telemetry, a placement cockpit, the screen preview and the trackpad.
Actions: `layout.placeFrontmost`, `switch.focusItem`, `keys.send`,
`keys.type`, `clipboard.pasteFromDevice`, `window.dragBy`,
`spaces.focusIndex`, `spaces.focusRelative`, `displays.focus`. Mac-only
bridge actions (voice, Talkie, layers) answer "Not available on Linux".

The bridge serves with the device identity
(`~/.lattices/identity/device.json`). Its trusted devices live in
`~/.lattices/host/bridge-devices.json` (0600). `--no-bridge` turns it off.

## Tests

```sh
bun test --cwd packages/host-linux
```

### Health is not an empty change stream

The additive fields in **host.describe** distinguish a healthy, quiet desktop
from a host that cannot observe it:

- **eventStream**: source (hyprland), state (not_started, connecting, connected,
  unavailable, disconnected or stopped), reason (null when connected), and
  lastEventAt (ISO timestamp; null until the first actual event).
- **events.desktop** is advertised only while socket2 is connected. The
  events.subscribe / events.unsubscribe methods still exist when it is not:
  clients can subscribe to **host.healthChanged** to see stream state changes.
- **capabilityHealth** maps capability names to available and reason. Missing
  grim/wtype/etc., a failing desktop query, or an absent Wayland protocol
  removes the capability and hides dependent methods in api.schema.

A null lastEventAt with state connected means no event has been observed yet,
not that observation is broken. Disconnection immediately removes events.desktop
and publishes host.healthChanged. Query host.describe again after that event.

Startup probes only read the desktop and Wayland registry; they do not capture,
send input, start VNC or modify a window. Probes run at startup or an explicit
refresh, never periodically. If the compositor becomes unreachable between
startup and a describe call, describe still returns health, not a failed RPC.

Socket2 state is logged once per distinct status/reason (no recurring retry
noise). Recovery watches the runtime/Hyprland socket directories and reconnects
when socket2 is created/replaced. There is no reconnect timer or polling loop.
A stopped subscription closes its socket and all filesystem watchers.

## Layers and layouts

The local Linux app's Layers page and the CLI share `~/.lattices/workspace.json`.
Create, assign, remove, rename and delete save pinned windows without losing
unrelated config fields. The first write backs up an existing file. Layer layout
choices port the Mac algorithm: In place, Auto, Columns and Master stack.

`layers.activate` and `layers.switch` accept `layer`/`name` or `index`, with
`focus` or `tile` mode and optional `dryRun: true`. They affect the focused
display's current desktop. Nonmembers go to `special:lattices`; `layers.reveal`
restores them to the desktop they came from when it is showing. The app window
and pinned desktop windows stay visible. `layers-stage-linux.json` retains
parked windows and the active layer across host restarts. `layers.changed`
notifies subscribers after editing or switching.

`layers.layout` accepts `{ layer, layout }`, where layout is `none`, `auto`,
`columns` or `master-stack`. Launch mode, undo, Mac app hiding and project
companion rules are unavailable. Saved window pins keep their original window
and process; reopened windows can be added again. App rules use Linux window
classes. `LATTICES_WORKSPACE_DIR` can select a separate development workspace.

## Virtual computer use

The local app's **Overview → Virtual space** view starts a headless Sway desktop
and previews it without switching the physical desktop. Its worker has a private
Wayland socket, runtime directory, D-Bus session and persistent virtual pointer.
No physical display or input device is attached. Wayland apps still run as the current
user and share its filesystem; this is a separate desktop session.

`lats app preview show|hide|toggle` controls a separate, watch-only floating
viewer (also available through **Agent view** in the sidebar). These commands
change local viewing only; they do not start, stop or send input to the virtual
desktop. The same virtual session remains available while the viewer is hidden.

Install `sway`, `grim`, `wtype` and `dbus-run-session`. OCR also needs `tesseract`.
For a portable development runtime, `LATTICES_VIRTUAL_SWAY` names the Sway binary
(with `swaymsg` beside it), and `LATTICES_VIRTUAL_LIBRARY_PATH` supplies its library
path. Normal installations need neither variable.

| Method | Parameters / result |
|--------|---------------------|
| `computer.virtual.start` | Optional `width`, `height`; default 1280 × 800, range 640 × 480 to 2560 × 1600 |
| `computer.virtual.status` | Availability, running state, dimensions and virtual windows with their own `wid` values |
| `computer.virtual.launch` | `app`: `browser`, `terminal` or an executable on PATH; optional `args` for an executable |
| `computer.virtual.capture` | Whole desktop PNG in base64 with width, height and timestamp |
| `computer.virtual.stop` | Closes the virtual apps, compositor and private D-Bus session |

The browser preset uses Chromium or Chrome with a separate persistent profile in
`~/.lattices/virtual-space/browser`; terminal uses `foot`. Start, launch, stop and
input require the existing `drive` scope for remote clients. Status, capture and
observe are read operations.

Add `space: "virtual"` to `computer.click`, `doubleClick`, `rightClick`, `aim`,
`scroll`, `drag`, `typeText`, `pressKey`, `hotkey` or `observe`. Leaving `space`
out targets the physical desktop. Any other explicit value is rejected. Input
stages by default; `treatment: "execute"` runs it. Virtual targets resolve only
against the virtual window list. `xRatio`/`yRatio` address that desktop or a target
window; drag uses absolute `fromX`/`fromY` and `toX`/`toY`. Observe returns OCR for
the whole virtual desktop and optionally its PNG (`image: true`); it does not
crop to a target window or region. Host tmux sessions cannot be input targets.

```sh
lats call computer.virtual.start
lats call computer.virtual.launch '{"app":"browser"}'
lats call computer.click '{"space":"virtual","xRatio":0.5,"yRatio":0.5,"treatment":"execute"}'
lats call computer.typeText '{"space":"virtual","text":"hello","treatment":"execute"}'
lats call computer.observe '{"space":"virtual","image":true}'
lats call computer.virtual.stop
```

`virtual.changed` announces starts, launches, stops and failures. The app previews
at two frames per second only while the virtual view is visible. The virtual
desktop belongs to the host; closing the app leaves it running. Stopping the host
also stops the virtual session. Existing physical windows are not moved into it.

### Virtual action caller deadlines

Virtual input uses an end-to-end deadline, not just a worker timeout. RPC callers
must include an absolute Unix-millisecond deadline in the request envelope for
executed virtual input and virtual app launch:

    {"id":"click-1","method":"computer.click","deadline":1792123000000,"params":{"space":"virtual","x":100,"y":100,"treatment":"execute"}}

Use Date.now() + budgetMs, not the example timestamp. CLI daemonCallTo, the
published CUA SDK transport, and the Linux app backend supply this automatically.
A transport mutation without a deadline is rejected before it can be queued.
The host clamps the caller's deadline to its shorter internal limit, carries it
to the worker, and cancels queued requests when their connection closes.

The app's 5-second input budget therefore expires in the worker too, even when
OCR is still running. The worker acknowledges cancellation of unstarted input.
Already-started work or unconfirmed cancellation reports **outcome uncertain;
do not retry blindly**. Known mutation clients wait a bounded 1.5-second receipt
grace after the action deadline; this is cancellation/receipt time, not extra
permission to start input. On a network failure without an authoritative receipt,
other clients must also treat the outcome as uncertain. Caller/server clocks must
be synchronized for absolute deadlines.
