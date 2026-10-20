---
title: Quickstart
description: Install Voice.app, confirm that Lattices can reach it, and speak a first line.
---

## Prerequisites

- macOS 26 or later.
- Apple silicon, if you use the `kokoro` provider.
- The Lattices CLI and menu bar app. See the
  [Lattices quickstart](/lattices/docs/quickstart).

## Install Voice.app

1. Start the Lattices menu bar app:

   ```sh
   lats app
   ```

2. In the Lattices menu, choose **Apps › Voice › Install**.

   Lattices downloads `Speech.dmg` from the latest `speech-v*` GitHub
   release. The installer checks the bundle ID, the Developer ID signature,
   and Gatekeeper assessment before it installs the app. The installer runs
   on Bun. If Bun is missing, the menu shows **Needs Bun** and an
   **Install Bun…** item.

3. If Voice.app is installed but not running, choose **Apps › Voice › Open**.

Result: the Voice icon appears in the menu bar.

## Check the connection

```sh
lats voice status
```

The `Voice helper` line shows `running` when Lattices can reach Voice.app.
Otherwise it shows one of these error codes:

| Error code | Meaning | Recovery |
| --- | --- | --- |
| `helper_not_installed` | Voice.app is not on this Mac. | Choose **Apps › Voice › Install** in the Lattices menu. |
| `helper_unreachable` | Voice.app is installed but not running. | Choose **Apps › Voice › Open**. |
| `helper_unauthorized` | Voice.app is running, but the request did not carry the capability token. | Retry through `lats`, which sends the token. A custom client must send the token. See [API](/speech/docs/api). |

## Speak

```sh
lats voice say "Build finished"
```

The command prints the job state and job id, for example `queued <id>`. The
command returns when Voice.app accepts the job, not when playback ends.

To use the on-device Kokoro provider:

```sh
lats voice say "The tests passed" --provider kokoro
```

The first Kokoro request downloads the model and voice assets. Later requests
render locally.

## Choose a default voice

```sh
lats voice list
lats voice select af_heart --provider kokoro
```

`select` sets the voice that a provider uses when a request names no voice.
Voice settings show the same choice.

## Build from source

To build Voice.app from the monorepo, follow **Build from source** in
[`products/voice/README.md`](https://github.com/lattices-dev/lattices/tree/main/products/voice#readme).
Packaging writes `products/voice/.artifacts/Voice.app` and does not install or
launch it.
