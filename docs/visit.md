# Visiting cursor

A visit lends one machine's mouse and keyboard to another without moving the
other machine's own cursor. Push the pointer past the edge that faces a paired
host and it parks there, frozen. From then on your mouse drives a coral
**visitor** on the host, labelled with your machine's name, the way a screen
share shows a second cursor. Your keys type on the host. Nothing on the host
asks for a new permission: the visit rides the companion bridge's pairing, and
needs the `input.trackpad` capability that pairing already grants.

A visit ends when:

- the visitor goes back off the edge it came in by;
- you press **⌃⌥⌘ Home**, or pick Bring Cursor Home from the menu bar;
- the channel drops, or either side stops hearing from the other for 6 seconds.

Your own cursor never left, so ending a visit can't strand it.

## Channel

`GET /visit` on the bridge port (5287) upgrades to a WebSocket. The upgrade
request carries the same signed headers as every protected bridge request
(`X-Lattices-Device-Id`, `-Timestamp`, `-Nonce`, `-Signature`), signed over
method `GET`, path `/visit` and an empty body. The host checks them, and that
the device holds `input.trackpad`, before upgrading. Otherwise it answers
401 or 403 as for any other route.

Every frame after that is a **binary** message: a ChaChaPoly sealed box in its
combined form (12-byte nonce, ciphertext, 16-byte tag). There's no base64. The
key is the device's encryption key, the one bridge bodies already use. The AAD
is the UTF-8 of:

```
visit\n<direction>\n<device id>\n<upgrade nonce>\n<seq>
```

`direction` is `up` from the visiting device and `down` from the host. `seq`
starts at 0 in each direction and goes up by one per frame. A frame that
doesn't open, or arrives out of sequence, closes the socket with code 1008.

The plaintext is one JSON object with a type in `t`.

### Up (visiting device → host)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `enter` | `name`, `edge`, `at` | Start a visit. `edge` is the side of the host's screens the visitor comes in by (`left`, `right`, `top`, `bottom`). `at` (0–1) is the position along that edge. `name` labels the visitor. |
| `move` | `dx`, `dy` | Relative motion in the device's points. |
| `button` | `button`, `down` | `left`, `right` or `middle`, pressed or released. |
| `scroll` | `dx`, `dy` | Pixels. Positive `dy` scrolls down, positive `dx` scrolls right. |
| `key` | `key`, `mods` | One keystroke. `key` is an XKB keysym name (`Return`, `a`, `Left`, `F5`); `mods` lists any of `ctrl`, `shift`, `alt`, `super`. The Mac sends ⌘ as `super`. |
| `text` | `text` | Characters to type as they are. |
| `ping` | | Sent every 2 seconds. |
| `leave` | | End the visit. |

### Down (host → visiting device)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `ready` | `x`, `y` | The visitor is drawn at this host position. |
| `exit` | `edge`, `at` | The visitor went back off `edge` at `at` (0–1). The device ends the visit and puts its own cursor at the matching point of its edge. |
| `pong` | | Answers `ping`. |
| `error` | `message` | Something failed. The visit goes on unless the socket closes. |

## On the host

- **Area.** The visitor moves over the host's real screens. Virtual outputs, such
  as Lattices' own `LATS-*`, are left out, the same set Bring Cursor Home picks
  from. The edge in `enter` is the edge of that area.
- **Two cursors.** The host's own cursor stays where it is while the visitor
  moves. For a button press or a scroll, the real pointer goes to the visitor so
  the input lands there. Keyboard focus must end up where the visitor clicked.
  When the visit ends, the host's cursor goes back to where it was.
- **Release.** If the visit ends while a button is held, the host releases it.

## On the Mac

- Sharing is armed from the menu bar and only taps the mouse while it's armed.
  Crossing needs a deliberate push past the edge, not just touching it.
- During a visit the cursor is detached from the mouse
  (`CGAssociateMouseAndMouseCursorPosition`). A session event tap swallows mouse
  and key events and forwards them, so nothing on the Mac reacts.
- ⌃⌥⌘ Home ends the visit from inside that tap, so it works however the channel
  is doing.

## Machines

Open **Workspace → Machines** (`hosts` remains a page-name alias). The page
merges visit pairings and Lattices hosts by name or
address. Selecting a Lattices host retains its still, live view and window list.
Opening the page does not arm visiting. Connections and status
reads stop when the page is hidden; arrangement safety timers remain independent.

Drag displays and machines on the scaled arrangement canvas. A machine owns only
the stretch of an edge touched by its rectangle; several machines can share a
side. `Side` is a shortcut that puts a machine beside the outermost display.
Older side-only pairings migrate without replacing their trust keys. Newly added
machines remain unplaced until arranged.

Moving a local display edits a draft. **Apply** starts a 15-second trial; **Keep**
accepts it and **Revert** restores the previous origins. Leaving Machines does not
cancel the rollback timer. Display configuration is never changed by a drag.

Every display, including the main display, has an **Elsewhere** checkbox. Drop a
machine onto an elsewhere display to record what it shows. Pushing toward that
display visits its assigned machine, using the same deliberate push threshold.

**Add machine** adds a Lattices host, pairs a visit host, or does both. Lattices
hosts are stored in `~/.lattices/hosts.json`; visit pairing still requires approval
on the other machine. Monitor geometry from `host.describe` is cached for offline
arrangement. Hosts without display information use a generic 1920 × 1080 screen.

The bundle app can receive visits through its companion bridge. **Let other
machines visit this Mac** is off by default. Enabling it enables the existing
bridge. `/visit` requires signed, replay-checked authentication and the paired
`input.trackpad` capability. Its encrypted binary frames bind direction, device,
upgrade nonce and sequence. One visitor is accepted at a time; disabling visits,
disconnecting, leaving, or a six-second heartbeat timeout releases held buttons
and restores the host cursor. No Mac deployment or remote setup is automatic.

```bash
lats hosts add arts-mini arts-mini
lats visit place archie 3440 0
lats visit side archie left
lats visit elsewhere 2 arts-mini
lats visit host on        # bundle: explicitly allow receiving visits
lats visit forget archie
lats mouse home           # ends the visit and returns the cursor
```

Visit bridge reachability is checked on page appearance, Refresh and state
changes, with no recurring probe timer. Display-to-machine labels are stored by
display UUID. Arrangement coordinates use the same top-left global point space
as `CGDisplayBounds`. The exit fraction is measured along the touching span,
not the whole local display. No pairing or visiting starts on page open.
