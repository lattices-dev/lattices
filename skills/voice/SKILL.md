---
name: voice
description: The Lattices voice domain. Use when speaking out loud to the user (voice.say, stop, list, select), simulating a voice command, listing voice intents, checking the voice runtime, or turning spoken window management into the same canonical mutations as the lattices skill.
compatibility: Requires macOS with a running Lattices menu bar app and matching CLI. Speaking also requires Voice.app.
metadata:
  author: arach
  homepage: https://lattices.dev/lattices/docs/voice
---

# Voice

The `voice` domain covers both directions. Listening (spoken commands) runs in
the Lattices daemon. Speaking runs in the separate Voice.app helper, which can
be bundled with Lattices or installed independently.

Lattices hosts an in-process voice runtime. Spoken commands are another client of the
same execution layer as the CLI and daemon. Spoken commands must resolve
into the same canonical mutations as the `lattices` skill
(`windows.place`, `layers.activate`, `spaces.optimize`).

When this skill is invoked, run the command. Summarize the matched intent
and the result. Do not invent intent names or slot values.

## Prerequisite

```bash
lats voice status
```

If the daemon is down, start it with `lats app`. Lattices 0.15.1 uses
`voice.sock` and `lattices.sock` under `~/.lattices/run`; Speech 0.3.0 uses
`speech.sock`. Each service requires its matching token. Install Lattices app
and CLI 0.15.1 together. The CLI handles discovery and authentication.

Capability file:

`~/Library/Application Support/Lattices/Voice/hudson-voice-runtime.json`

Override the voice port only for compatibility tests with
`LATTICES_VOICE_PORT`. Version 0.15.1 opens a voice TCP listener only
with the explicit `LATTICES_VOICE_ALLOW_LEGACY_TCP=1` compatibility setting.

## Speaking

```bash
lats voice say "Build finished"
lats voice stop              # stop speaking and clear the queue
lats voice list              # voices, with availability
lats voice select <id>       # default voice for later say calls
```

`voice.say` returns once the job is queued, not when speech ends. If the
Voice helper is missing, calls fail with `helper_not_installed`; install it
from Lattices › Apps. If it is installed but not running, they fail with
`helper_unreachable`; open Voice from Lattices › Apps. There is no fallback.

## Agent surface

Agents do not hold the microphone. They simulate speech through the CLI:

```bash
lats voice intents
lats voice simulate "tile this left"
lats voice simulate "focus chrome" --dry-run
```

`lats voice stopListening` stops capture. `lats voice stop` stops
speaking (the Voice helper's output), not listening.

`--dry-run` parses and does not execute. Read `lats voice intents`
before sending a novel phrase.

Equivalent daemon calls:

```bash
lats call voice.status
lats call voice.simulate '{"text":"tile this left","execute":true}'
lats call intents.list
lats call intents.run '{"intent":"tile_window","slots":{"position":"left"},"rawText":"put this on the left","source":"agent"}'
```

## What people say

Humans open the voice window with **Hyper+D**, hold **Option** to talk,
and release to stop.

| Phrase | Result |
| --- | --- |
| "Tile this left" | `windows.place` left |
| "Focus Safari" | Focus that app |
| "Find all vox windows" | Search |
| "Launch the vox project" | Session launch |
| "Switch to layer 2" | `layers.activate` |
| "Scan the screen" | OCR scan |
| "List all windows" | Window list |

Category words such as "terminals", "browsers", and "editors" expand to
real app names before search.

## Policy

- Local intent matching runs first. Provider-backed interpretation is
  optional (Settings > Voice).
- Do not skip the local matcher and send every phrase to an LLM.
- Voice search uses the same backend as `lats search`.
- Keep `wid` in structured actions. In speech the user says an app name;
  the JSON action uses the window id from a snapshot.
- Advisor learning, when a suggestion is used after a local miss, is
  appended to `~/.lattices/advisor-learning.jsonl`.

## Live docs

1. `lats voice intents`
2. https://lattices.dev/docs/voice
3. https://lattices.dev/docs/agents
4. `docs/voice-command-protocol.md` in this repository
