---
title: Overview
description: Voice queues and plays spoken updates from agents and scripts. Its macOS app, Voice.app, is a separate process from Lattices.
---

Voice is the Lattices family product for spoken output. Agents and scripts
send text. Voice queues the text, renders audio, and plays it with an optional
readalong HUD. Playback continues after the requesting process disconnects.

Voice is both the product name and the macOS app name. It keeps some
identifiers from its earlier Speech name. See [Stable identifiers](#stable-identifiers).

## What Voice owns

Voice.app is a menu bar app (`LSUIElement`) with its own process, settings, and
local RPC server. Voice.app owns:

- the speech queue and job state;
- synthesis through the configured provider;
- audio playback and the playback HUD;
- voice preferences and provider credentials;
- the authenticated RPC server on `~/.lattices/run/speech.sock`.

Lattices is a client of Voice.app. Lattices does not own the queue or the
Voice.app process.

## Independent lifecycle

Voice.app starts, runs, and quits independently of Lattices.

- Quitting Lattices does not quit Voice.app or clear its queue.
- Quitting Voice.app does not quit Lattices.
- If Voice.app is not running, Lattices speech output requests fail with an
  error. Lattices does not use a fallback voice.

## Voice output and Lattices voice input are separate

The family `voice` domain covers two directions. Different processes serve
each direction.

| Direction | Commands | Process | Address |
| --- | --- | --- | --- |
| Output (speaking) | `voice.say`, `voice.stop`, `voice.pause`, `voice.list`, and related verbs | Voice.app | `~/.lattices/run/speech.sock` |
| Input (listening) | `voice.listen`, `voice.stopListening`, `voice.simulate` | Lattices menu bar app | `~/.lattices/run/voice.sock` |
| Agent API gateway | All `voice.*` verbs | Lattices core daemon | `~/.lattices/run/lattices.sock` |

`lats voice say` and the other output commands call the Lattices core daemon
over `lattices.sock`. The daemon renames each output verb to its `speech.*` method and
forwards the request to Voice.app over `speech.sock`. Dictation and spoken commands
stay in Lattices. Voice.app has no microphone runtime.

For the listening side, see [Lattices voice](/lattices/docs/voice).

### Private connection

Voice 0.3.0 and Lattices 0.15.1 use private Unix sockets in
`~/.lattices/run`.

| Direction | Endpoint |
| --- | --- |
| Output | `speech.sock`, owned by Voice.app |
| Input | `voice.sock`, the Vox runtime hosted in the Lattices menu bar app |
| `voice.*` routing | `lattices.sock`, the Lattices core daemon |

The routing and the independent lifecycles do not change. Voice.app opens
`127.0.0.1:9397` only when it starts with `LATTICES_SPEECH_TCP=1`. Remote
machines reach Voice only through the opt-in Lattices tailnet gateway, with an
approved grant such as `speech:speech.enqueue`. See [API](/voice/docs/api#private-connection).

## Providers

| Provider id | Where it runs | Requirement |
| --- | --- | --- |
| `system` | macOS system voices | None. This is the default provider. |
| `phonon` | On this Mac, on the Apple Neural Engine | Apple silicon. Voice.app downloads the model (137 MB) on the first Phonon request. |
| `openai` | OpenAI cloud | Credentials in Voice settings |
| `elevenlabs` | ElevenLabs cloud | Credentials in Voice settings |

Voice.app renders Phonon in-process through Gradium's Phonon 31m, an Apache 2.0
model with 38 English voices. Phonon does not use Vox or a Python runtime. Its
speaking rate is fixed, so `rate` does not apply. Current builds leave Kokoro
out, and a `kokoro` request fails with a message that says so. Voice.app keeps provider credentials in
the macOS Keychain.

## Stable identifiers

Voice.app keeps identifiers from its earlier Speech name. Existing installs and
clients depend on these values, so they do not change:

| Identifier | Value |
| --- | --- |
| Bundle ID | `dev.lattices.Speech` |
| RPC methods | `speech.*` |
| RPC socket | `~/.lattices/run/speech.sock` |
| Capability token file | `~/Library/Application Support/Speech/RPC/capability` |
| Keychain service | `dev.lattices.app.voice` |

## Next steps

- [Quickstart](/voice/docs/quickstart): install Voice.app and speak a first line.
- [CLI](/voice/docs/cli): the commands that reach Voice and their playback semantics.
- [API](/voice/docs/api): the direct `speech.*` RPC reference.
