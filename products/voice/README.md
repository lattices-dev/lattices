<p><a href="../../README.md">← Lattices</a> &nbsp; / &nbsp; Speech</p>

<picture>
  <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="assets/readme/hero-mobile-dark.svg">
  <source media="(max-width: 600px) and (prefers-color-scheme: light)" srcset="assets/readme/hero-mobile-light.svg">
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/hero-light.svg">
  <img src="assets/readme/hero-light.svg" width="1200" alt="Speech. Speech playback for agents.">
</picture>

<p align="center">
  <a href="https://lattices.dev/speech">Product page ↗</a> &nbsp; · &nbsp;
  <a href="#install-and-run">Get started</a> &nbsp; · &nbsp;
  <a href="../../docs/voice.md">Documentation</a> &nbsp; · &nbsp;
  <a href="../../skills/voice/SKILL.md">Agent skill</a>
</p>

Speech queues and plays spoken updates from agents and scripts, with an optional readalong HUD. The macOS app is called **Voice**.

<table><tr>
<td width="33%" valign="top"><strong>Persistent queue</strong><br>Playback continues after the requesting agent or script disconnects.</td>
<td width="33%" valign="top"><strong>Voice providers</strong><br>Use system voices, local Kokoro, or configured OpenAI and ElevenLabs providers.</td>
<td width="33%" valign="top"><strong>Playback controls</strong><br>Pause, resume, seek, or skip queued readouts through the Lattices CLI.</td>
</tr></table>

## Install and run

Requires macOS 26+. Kokoro's Neural Engine renderer requires Apple silicon.
Install the Lattices CLI with Bun and start the menu bar app:

```sh
bun add --global @lattices/lattices
lattices app
```

In the Lattices **Apps** menu, choose **Voice** to install or open the helper.
Voice has its own process and settings. Quitting Lattices does not quit Voice
or clear its queue.

With Lattices and Voice running:

```sh
lattices voice status
lattices voice list
lattices voice say "Build finished"
lattices voice say "The tests passed" --provider kokoro
```

The default provider is `system`. Kokoro downloads its model and required voice
assets on first use, then renders locally through FluidAudio's `KokoroAne`.
OpenAI and ElevenLabs are also available with credentials configured in Voice
settings. Credentials stay in the macOS Keychain.

## Use with Lattices

The CLI executable in this checkout is `lattices`. Its `voice` commands call
the core daemon, which forwards speech output to Voice. The helper keeps the
older `speech.*` RPC names and `dev.lattices.Speech` bundle identifier for
compatibility with existing clients.

| Surface | Address | Owner |
| --- | --- | --- |
| Agent API, including `voice.*` | `ws://127.0.0.1:9399` | Lattices core |
| Dictation and live voice sessions | `ws://127.0.0.1:9398` | Lattices core |
| Speech queue and playback, `speech.*` | `ws://127.0.0.1:9397` | Voice helper |

For example, `voice.say` forwards to `speech.enqueue`, and `voice.list`
forwards to `speech.voices`. A successful enqueue returns a job ID and state;
it does not mean playback has finished.

```sh
lattices voice pause
lattices voice resume
lattices voice seek 5
lattices voice skip
lattices voice stop
lattices voice select af_heart --provider kokoro
```

`voice.stop` stops playback and clears the queue. Dictation stays in Lattices:
`lattices voice listen` starts capture, and `lattices voice stopListening`
stops capture and runs the transcript. Voice's Swift package contains the
speech-output runtime, not the microphone runtime.

Direct RPC clients authenticate with the `x-lattices-speech-token` WebSocket
header. Voice creates the token at
`~/Library/Application Support/Speech/RPC/capability` while running; the
Lattices CLI reads and sends it automatically. Output requests report
`helper_not_installed`, `helper_unreachable`, or `helper_unauthorized` when the
helper cannot serve them. Use the Apps menu to install or open Voice, then
retry through the CLI.

This product exposes a WebSocket RPC server. The repository's root MCP server
currently registers browser tools; speech clients use the CLI or RPC described
here.

## Architecture

Paths below are relative to `products/voice/`.

```text
Sources/Speech/       app entry point, settings, HUD, queue, synthesis, RPC
Tests/SpeechTests/    queue, provider, socket, migration, and Kokoro tests
tools/package.sh     local app bundle, signing, and optional DMG packaging
assets/              app icon
Package.swift        Voice executable and Hudson/FluidAudio dependencies
build.json           build features consumed by the packaging script
Info.plist           app identity and minimum macOS version
SOURCE-PROVENANCE.json  imported-source provenance
```

`SpeechQueue.swift` owns job state. `HudsonSpeechRuntime.swift` connects the
queue to Hudson's providers, cache, and audio player. `SpeechKokoroRuntime.swift`
renders Kokoro in-process on the Neural Engine. `SpeechRpc.swift` defines the
API, and `DaemonServer.swift` serves authenticated local connections.

<details>
<summary><strong>Build from source</strong></summary>

Use Bun and a Swift 6.2 toolchain on macOS 26+. SwiftPM fetches Hudson over SSH,
so the build needs access to the Hudson repository named in
[Package.swift](Package.swift). Run these commands from the monorepo root:

```sh
HUDSONKIT_WITH_VOICE=0 swift build --package-path products/voice
HUDSONKIT_WITH_VOICE=0 swift test --package-path products/voice
bash products/voice/tools/package.sh
```

`HUDSONKIT_WITH_VOICE=0` excludes Hudson's dictation dependencies from this
speech-output app. The packaging script sets it from [build.json](build.json)
and produces `products/voice/.artifacts/Voice.app`, with an ad hoc signature by
default. Packaging does not install, launch, notarize, or publish the app.

To run the local artifact, quit any other Voice instance first, then use:

```sh
open products/voice/.artifacts/Voice.app
```

The packaging script refuses to overwrite an existing artifact. Set
`SPEECH_ARTIFACT_DIR` to a new output directory for another build. Real-model
Kokoro tests are opt-in through `VOICE_KOKORO_LIVE=1`; ordinary tests skip those
downloads and renders.

</details>

## Documentation

Voice has no product-local `docs/` directory yet. The current references are:

- [Voice commands and API](../../docs/voice.md)
- [Spoken-command protocol](../../docs/voice-command-protocol.md)
- [Agent integration](../../docs/agents.md)
- [Voice agent skill](../../skills/voice/SKILL.md)
- [Product development contract](AGENTS.md)
- [Site page](https://lattices.dev/speech), still published under the Speech name

---

<p align="center">
<a href="../../README.md">Lattices</a> · <a href="../action/README.md">Action</a> · <a href="../blink/README.md">Blink</a> · <a href="../voice/README.md">Speech / Voice</a></p>
