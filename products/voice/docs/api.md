---
title: API
description: The speech.* WebSocket RPC that Voice.app serves over private speech.sock, its capability token, and the Lattices voice.* gateway.
---

Voice.app serves an authenticated JSON-over-WebSocket RPC on
`~/.lattices/run/speech.sock`. Clients can call Voice.app directly, or call the
Lattices core daemon on `~/.lattices/run/lattices.sock`, which forwards `voice.*` output
verbs to Voice.app.

## Choose a path

| Path | Address | Method names | Use when |
| --- | --- | --- | --- |
| Lattices gateway | `~/.lattices/run/lattices.sock` | `voice.*` (or `speech.*`, forwarded unchanged) | You already use the Lattices agent API. |
| Direct | `~/.lattices/run/speech.sock` | `speech.*` | You need Voice without the Lattices daemon. |

Both paths require the capability token.

"Lattices gateway" here means the core daemon's `voice.*` forwarding on the same
machine. It is not the opt-in tailnet gateway for remote
access.

## Authentication

Voice.app creates a random 32-byte token each time it starts. Voice.app writes
the base64 token to:

```text
~/Library/Application Support/Speech/RPC/capability
```

The directory has mode `0700`. The file has mode `0600`. Voice.app removes the
file when it quits. A missing file means that Voice.app is not running.

A client must send the token in the WebSocket upgrade request:

```text
x-lattices-speech-token: <token>
```

Voice.app refuses `speech.*` access when any of these conditions is true:

- the header is missing, or appears more than once;
- the token does not match;
- the handshake contains an `Origin` header. Browser pages cannot connect.

An unauthorized `speech.*` call returns the error
`Speech access requires the local capability`. Voice.app also withholds
`speech.*` events from unauthorized connections.

The Lattices daemon checks the same token over `lattices.sock` before it forwards a
`voice.*` output verb. The Lattices CLI reads the file and sends the header
automatically.

## Private connection

Voice 0.3.0 and Lattices 0.15.1 use the private sockets below.
Upgrade the app and its clients together.

- Voice.app listens on `~/.lattices/run/speech.sock` and accepts only peers
  with the same user ID. It writes a connection token to
  `~/.lattices/run/speech.token`.
- A direct client sends `Host: localhost` and either `x-lattices-token` with the
  connection token or `x-lattices-speech-token` with the capability token
  described above. `Origin` is still refused.
- Port 9397 opens only when Voice.app starts with `LATTICES_SPEECH_TCP=1`.
- The Lattices daemon path moves to `~/.lattices/run/lattices.sock`. `lats`
  finds both sockets and tokens for you.
- From another machine, Voice is reachable only through the Lattices tailnet
  gateway (`lats gateway start --tailnet`). The client pairs with exact grants,
  for example `lats --host HOST pair --grant speech:speech.enqueue`, and a
  person on the host approves the request. The gateway exposes `speech.status`,
  `speech.voices`, `speech.enqueue`, `speech.pause`, `speech.resume`,
  `speech.seek`, `speech.stop`, `speech.next` and `speech.preferredVoice.set`.
  Voice's native playback reservation and events stay local. The gateway
  does not forward core `voice.*` aliases. Remote calls use
  `gateway.call` with `{ "product": "speech", "method": "speech.enqueue", "params": { "text": "…" } }`.

See [Private IPC and the gateway](/lattices/docs/concepts#private-ipc-and-the-gateway).

## Wire format

The wire format matches the Lattices daemon.

```json
{ "id": "1", "method": "speech.enqueue", "params": { "text": "Build finished" } }
```

```json
{ "id": "1", "result": { "id": "…", "state": "queued", "…": "…" }, "error": null }
```

Events have this shape:

```json
{ "event": "speech.changed", "data": { "current": null, "queued": [], "recent": [] } }
```

## Methods

| Method | Gateway verb | Params | Returns |
| --- | --- | --- | --- |
| `speech.enqueue` | `voice.say` | `text` (required), `provider`, `model`, `voice`, `rate`, `instructions`, `voiceSettings`, `cachePolicy`, `source` | `SpeechJob` |
| `speech.status` | part of `voice.status` | none | `SpeechStatus` |
| `speech.pause` | `voice.pause` | `id` | `SpeechStatus` |
| `speech.resume` | `voice.resume` | `id` | `SpeechStatus` |
| `speech.seek` | `voice.seek` | `seconds` (required), `id` | `SpeechStatus` |
| `speech.stop` | `voice.stop` | `id` | `SpeechStatus` |
| `speech.next` | `voice.skip` | `id` | `SpeechStatus` |
| `speech.voices` | `voice.list` | none | `[SpeechVoice]` |
| `speech.preferredVoice.set` | `voice.select` | `voice` (required; empty clears), `provider` | `SpeechPreferredVoice` |
| `speech.playback.reserve` | `voice.lease` | none | `true` |

For the control methods, `id` is optional. If you send `id`, it must match the
active job. Otherwise the call fails with `Speech job <id> is not the active job`.

### `speech.enqueue` parameters

| Param | Type | Notes |
| --- | --- | --- |
| `text` | string | Required. At most 8,000 characters. |
| `provider` | string | `system` (default), `kokoro`, `openai`, or `elevenlabs`. |
| `model` | string | Provider model override. |
| `voice` | string | Voice id from `speech.voices`. If omitted, Voice.app uses the provider's preferred voice. |
| `rate` | double | 0.25 to 4.0. Default 1.0. |
| `instructions` | string | Delivery instructions for providers that accept them. At most 1,000 characters. |
| `voiceSettings` | object | `stability`, `similarity`, `style`, `useSpeakerBoost`. |
| `cachePolicy` | string | `reuse` (default) or `fresh`. |
| `source` | object | `kind`, `label`, `taskId`, `sessionId`. URLs are refused. |

`speech.enqueue` returns the job with its actual state. The state is never
`completed` at enqueue time. Voice.app does not fetch remote audio and does
not open source links.

### Playback lease

`speech.playback.reserve` reserves the speaker for the calling connection.
While a lease is held, Voice.app pauses the playing job and defers new
playback. Only one connection can hold the lease. Another connection gets the
error `Another voice session is speaking`.

Voice.app has no release method. The lease ends when the connection closes.
Through the gateway, `voice.release` closes the client's helper connection,
which ends the lease.

## Models

**`SpeechJob`**: `id`, `state`, `text`, `provider`, `model`, `voice`,
`source`, `error`, `progress` (0 to 1), `currentTime` (seconds), `duration`
(seconds).

Job states: `queued`, `generating`, `playing`, `paused`, `completed`,
`cancelled`, `failed`.

**`SpeechStatus`**: `current` (active job or null), `queued`, `failure` (kept
until dismissed), `recent` (up to 8 finished jobs), `preferredVoices`.

**`SpeechVoice`**: `id`, `label`, `provider`, `available`, `default`.

**`SpeechPreferredVoice`**: `provider`, `voice`, plus `label` and `available`
in the `speech.preferredVoice.set` result.

## Events

Voice.app broadcasts `speech.changed` with a `SpeechStatus` payload when the
queue changes. The Lattices daemon relays the event under both names:
`speech.changed` and `voice.changed`.

## Gateway errors

When the daemon cannot forward a request, it returns an error string that
starts with a machine code: `helper_not_installed`, `helper_unreachable`, or
`helper_unauthorized`. See [CLI errors](/voice/docs/cli#errors).

## MCP

The Lattices MCP server does not register speech tools. Use the CLI or this
RPC.
