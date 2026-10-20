---
title: CLI
description: The lats voice commands that reach Speech, how the Lattices daemon forwards them to Voice.app, and what each playback command does.
---

Speech has no CLI of its own. The Lattices CLI sends speech output commands
through the Lattices core daemon. This page describes the commands that reach
Speech and their playback behavior. For the full `lats voice` reference,
including listening and spoken commands, see
[Lattices voice](/lattices/docs/voice).

## Request path

```text
lats voice say "…"
  → Lattices core daemon   lattices.sock   voice.say
  → Voice.app (Speech)     speech.sock   speech.enqueue
```

The CLI reads the capability token from
`~/Library/Application Support/Speech/RPC/capability` and sends it in the
WebSocket handshake to the daemon. The daemon forwards output verbs only for
clients that present the token.

In Speech 0.3.0 and Lattices 0.15.1, both hops use private Unix sockets,
`~/.lattices/run/lattices.sock` and `~/.lattices/run/speech.sock`. The CLI finds
them and their tokens for you. The command set does not change.

The CLI binary is also installed as
`lattices`. Both names run the same commands.

## Commands that reach Speech

| Command | Daemon verb | Voice.app method | Result |
| --- | --- | --- | --- |
| `lats voice say <text> [--voice <id>] [--provider <id>] [--rate <n>]` | `voice.say` | `speech.enqueue` | The new job, with its id and state |
| `lats voice stop` | `voice.stop` | `speech.stop` | Queue status |
| `lats voice pause` | `voice.pause` | `speech.pause` | Queue status |
| `lats voice resume` | `voice.resume` | `speech.resume` | Queue status |
| `lats voice seek <seconds>` | `voice.seek` | `speech.seek` | Queue status |
| `lats voice skip` | `voice.skip` | `speech.next` | Queue status |
| `lats voice list` | `voice.list` | `speech.voices` | Voices, with availability |
| `lats voice select <voice> [--provider <id>]` | `voice.select` | `speech.preferredVoice.set` | The saved preference |
| `lats voice status` | `voice.status` | `speech.status` | Lattices listening state, plus a `helper` section with the Voice.app queue |

Add `--json` to any command for machine-readable output.

`lats voice listen`, `stopListening`, `simulate`, and `intents` do not reach
Speech. Lattices serves those commands itself.

## Playback semantics

- **`say` queues.** `say` returns when Voice.app accepts the job. The returned
  state reflects the job at that moment and is never `completed`. Jobs play
  in order.
- **The queue outlives the caller.** A job keeps playing after the CLI process
  exits.
- **`stop` clears the queue.** `stop` stops the active job and cancels every
  queued job.
- **`skip` keeps the queue.** `skip` ends the active job and starts the next
  queued job.
- **`pause`, `resume`, and `seek` act on the active job only.** `pause` fails
  with `Nothing is playing` when no job plays. `resume` fails with
  `Nothing is paused` when no job is paused. `seek` takes a position in
  seconds from the start of the job.
- **`select` sets a per-provider default.** The voice applies to later `say`
  requests for that provider that name no voice.
- **`--rate`** must be between 0.25 and 4.0. The default is 1.0.

`lats voice stop` stops speech output. `lats voice stop` does not stop voice
capture. To stop capture, use `lats voice stopListening`.

## Limits

| Limit | Value |
| --- | --- |
| Text per job | 8,000 characters |
| Jobs in the queue | 32 |
| Recent finished jobs kept in status | 8 |

## Errors

If Lattices cannot reach Voice.app, output commands fail with one of these
codes. Lattices does not fall back to another voice.

| Error code | Meaning | Recovery |
| --- | --- | --- |
| `helper_not_installed` | Voice.app is not on this Mac. | In the Lattices menu, choose **Apps › Voice › Install**. |
| `helper_unreachable` | Voice.app is installed but not running. | Choose **Apps › Voice › Open**. |
| `helper_unauthorized` | Voice.app is running, but the client did not send the capability token. | Use `lats`, or send the token from your client. See [API](/speech/docs/api). |
| `voice_stop_changed` | `voice.stop` was called while Lattices was listening and nothing was speaking. | Use `lats voice stopListening` to stop capture. |
