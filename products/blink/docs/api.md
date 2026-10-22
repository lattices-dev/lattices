---
title: Agent socket API
description: The implemented JSON-RPC methods and events on Canvas's local Unix socket.
---

# Agent socket API

The running Canvas app serves a small JSON-RPC 2.0 API on a local Unix domain
socket. Use it to read live panel state, present a note, save and restore desks,
and receive change events.

This page documents only the methods that Canvas implements today. The broader
design in [Agent API proposal](https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/agent-api.md) is proposed and is not
built. Do not call a method from that proposal unless it is listed here.

For most work, prefer the [`canvas` CLI](/canvas/docs/cli). The CLI works when the
app is closed. The socket works only while the app is running.

## Connection

| Property | Value |
|---|---|
| Transport | Unix domain socket, `SOCK_STREAM` |
| Path | `~/Library/Application Support/Blink/blink.sock`, or the first nonempty `$CANVAS_HOME/blink.sock` / `$BLINK_HOME/blink.sock` override |
| Access control | File mode `0600`. Only the user who runs Canvas can connect. There is no token. |
| Framing | One JSON object per line, terminated by `\n`, in both directions |
| Protocol | JSON-RPC 2.0. Every request must include `"jsonrpc": "2.0"` and a string `method`. |
| Lifetime | Canvas creates the socket at launch and removes it at quit. |

The client and the app must use the same home directory. If the socket file does
not exist, Canvas is not running with that home. The CLI reports this condition
as `Blink is not running with the same BLINK_HOME (missing blink.sock)`.

### Private access

Canvas 2.3.0 keeps this socket path and protocol, with no token. It enforces
the following checks.

- Canvas creates its home directory with mode `0700` and refuses symlinks in the
  path.
- The app accepts a connection only from a peer with the same user ID.
- The CLI refuses a socket, or a socket directory, that another user owns or
  that is group- or world-accessible.

Canvas's agent socket does not move into `~/.lattices/run` or open a TCP port.
Canvas's paired iOS note sync remains a separate Multipeer Connectivity service.
A paired tailnet client can call a reviewed subset of agent methods through the
opt-in Lattices gateway using the product identifier `blink`, one exact grant
per method: `system.hello`,
`placements.list`, `notes.list` and `notes.get` to read, and `notes.present`,
`desk.save` and `desk.restore` to act. Canvas event streams stay local. See
[Private IPC and the gateway](/lattices/docs/concepts#private-ipc-and-the-gateway).

Example with `nc`:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"system.hello"}' \
  | nc -U "$HOME/Library/Application Support/Blink/blink.sock"
```

## Methods

| Method | Params | Result |
|---|---|---|
| `system.hello` | none | `{ "protocol": "2.0", "version": "<app version>", "app": "Blink" }` |
| `placements.list` | none | Array of open panels (see below). |
| `notes.list` | none | Array of `{ "id", "title", "updated" }`. `updated` is ISO 8601. |
| `notes.get` | `id` (string, required), `content` (bool, optional) | `{ "id", "title", "frontmatter" }`, plus `content` when `content` is `true`. `frontmatter` holds the foreign frontmatter lines that Canvas does not own. |
| `notes.present` | `id` (string, required), `content` (string), `slot` (integer), `style` (string) | `{ "id" }` |
| `desk.save` | `name` (string, required) | `{ "name", "updated", "panels" }`. `panels` is the panel count. |
| `desk.restore` | `name` (string, required) | `{ "name", "updated", "panels" }` |
| `events.subscribe` | `topics` (optional) | `{ "subscribed": <topics> }` |

### placements.list

Each entry describes one open panel:

```json
{
  "id": "standup",
  "frame": { "x": 980, "y": 412, "width": 460, "height": 260 },
  "screen": 1,
  "mode": "read",
  "shaded": false,
  "focused": true,
  "z": 0,
  "slot": 6
}
```

- `frame` is in AppKit screen coordinates (origin at the bottom left of the main
  display). This differs from `blink desk open`, which takes display-local
  coordinates from the top left.
- `screen` is a one-based display index.
- `z` is the front-to-back order. `0` is the frontmost panel.
- `slot` is `null` when the panel has no grid slot.

### notes.present

`notes.present` creates the note if it does not exist, then opens or focuses its
panel.

- Canvas converts `id` to a slug.
- `content` replaces the whole body. If you omit it, the body does not change.
- `slot` sets `blink.slot`. `style` sets `blink.style`. Other presentation keys
  do not change.
- Canvas records the writer as `agent-socket` in `blink.lastWriter` and in the
  edit ledger.

The CLI command `blink present` covers more presentation fields and does not
need the running app.

### desk.save and desk.restore

`desk.save` captures the open panels into `desks/<name>.json`. `desk.restore`
reopens the panels in that file at their saved frames. A desk name must be 1 to
80 characters of letters, digits, `-`, or `_`.

`blink desk save <name>` and `blink desk restore <name>` call these methods.
`blink desk ls`, `blink desk show`, and `blink desk rm` read and delete the desk
files directly and do not use the socket.

### events.subscribe

After `events.subscribe`, the app sends notifications on the same connection.
Notifications have no `id`:

```json
{ "jsonrpc": "2.0", "method": "panel.moved", "params": { "id": "standup" } }
```

| Event | Sent when |
|---|---|
| `note.created` | A note is created. |
| `note.updated` | A note's content or metadata changes. |
| `note.deleted` | A note is deleted. |
| `panel.moved` | A panel moves, including a slot move. |
| `panel.resized` | A panel is resized. |

Canvas does not filter by `topics` today. A subscribed connection receives every
event in this table. Each event carries only the note `id`. Call `notes.get` or
`placements.list` to read the new state.

## Errors

Errors use the JSON-RPC error object:

```json
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32004, "message": "Note not found" } }
```

| Code | Meaning |
|---|---|
| `-32600` | The line is not a valid JSON-RPC 2.0 request. The reply `id` is `null`. |
| `-32601` | The method does not exist. |
| `-32602` | A required parameter is missing. |
| `-32004` | `notes.get` did not find the note. |
| `-32000` | Another failure, such as an invalid desk name or a missing desk. The message gives the cause. |

## Not implemented

These items appear in the [proposal](https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/agent-api.md) and do not exist:

- Authentication tokens, capability negotiation, and version ranges beyond
  `system.hello`.
- Topic filtering and richer event payloads.
- `auto` placement, collision routing, scenes, and `tidy`. See
  [Placement](/canvas/docs/placement).
- An MCP server or SDK. See
  [Agent integration proposal](https://github.com/lattices-dev/lattices/blob/main/products/blink/docs/agent-integration.md).
