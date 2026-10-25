---
title: For agents
description: How an agent should give spoken updates through Voice, check that Voice.app is reachable, and stay inside the output boundary.
---

Voice plays text out loud for agents and scripts. Use it for short spoken
updates, such as a finished build or a question that needs the user's
attention. Voice does not listen. Dictation and spoken commands belong to
[Lattices voice](/lattices/docs/voice).

## Scope

| Owned by Voice | Not owned by Voice |
| --- | --- |
| The speech queue, job state, and playback | The microphone, dictation, and spoken commands |
| Voice and provider choice | Window, session, and workspace control |
| The playback HUD | Visible notes. Use [Canvas](/canvas/docs/agents) |

Voice has no CLI of its own. Agents use `lats voice` output commands. The
Lattices daemon forwards them to Voice.app.

## First check

Run this before you speak. It does not make a sound.

```sh
lats voice status --json
```

Read the `helper` section. If Voice.app is running, the section shows the
queue. If not, it shows one of these codes:

| Code | What to do |
| --- | --- |
| `helper_not_installed` | Tell the user to choose **Apps › Voice › Install** in the Lattices menu. Do not install it yourself. |
| `helper_unreachable` | Tell the user to choose **Apps › Voice › Open**. |
| `helper_unauthorized` | Use `lats`, which sends the capability token. Do not read or copy the token into a custom client unless the user asks for one. |

Lattices does not use a fallback voice. A failed `say` is silent.

## First success

Speak one short line:

```sh
lats voice say "Tests passed" --json
```

Expected result: a job with an id and a state such as `queued`. The command
returns when Voice.app accepts the job, not when playback ends. The state is
never `completed` in this result.

To stop speech that you started:

```sh
lats voice stop
```

`stop` clears the whole queue, including jobs from other callers. `skip` ends
only the active job. `lats voice stop` does not stop listening. Use
`lats voice stopListening` for that.

## Rules for spoken updates

1. Speak only when the user asked for spoken updates, or when a long task ends
   and the user is away from the screen.
2. Keep each line short. Put details in the terminal or in a note.
3. Do not read secrets, tokens, file contents, or long logs out loud.
4. Do not change the default voice with `lats voice select` unless the user
   asks. The choice is a saved user preference.
5. Respect the limits: 8,000 characters per job and 32 jobs in the queue.

## Choose a surface

| Need | Use |
| --- | --- |
| Speak from a shell or agent terminal | `lats voice say` |
| Speak from a client that already uses the Lattices agent API | `voice.say` on the Lattices daemon. See [API](/voice/docs/api#choose-a-path). |
| Speak without the Lattices daemon | `speech.enqueue` directly on Voice.app, with the capability token. See [API](/voice/docs/api#authentication). |
| Speak from another machine | Use the opt-in tailnet gateway with a grant such as `speech:speech.enqueue`. See [API](/voice/docs/api#private-connection). |

Voice 0.3.0 and Lattices 0.15.1 use private sockets in `~/.lattices/run`.
Install matching app and CLI versions. `lats` handles authentication for you.

## Read next

- [Quickstart](/voice/docs/quickstart): install Voice.app and speak a first line.
- [CLI](/voice/docs/cli): every command that reaches Voice and its playback semantics.
- [API](/voice/docs/api): the `speech.*` RPC, authentication, and events.
