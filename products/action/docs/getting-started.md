---
title: Getting started
description: Install Action.app, grant permissions, and check the local agent
order: 1
---

This page installs the released `Action.app` and checks that its agent runs.
To build Action from source, see [Build from source](#build-from-source).

## Prerequisites

- macOS on Apple Silicon.
- [Bun](https://bun.sh/docs/installation).
- The Lattices CLI. Install it with `bun add --global @lattices/lattices`.

## Install and launch

1. Install the app:

   ```sh
   lats action install
   ```

   The command downloads `Action.dmg` from the latest `action-v*` GitHub
   release and installs `/Applications/Action.app`. It does not need a source
   checkout. Add `--launch` to open the app after installation.

2. Launch the app:

   ```sh
   lats action launch
   ```

3. Grant Accessibility and Screen Recording to `Action.app` when macOS asks.
   Native control needs Accessibility. Screenshots and recording need Screen
   Recording.

4. Check the status:

   ```sh
   lats action status --json
   ```

   Expect `installed: true`, `running: true`, and `agentReachable: true`. The
   `agentUrl` is `ws://127.0.0.1:4319`.

If `agentReachable` is `false`, launch the app again with `lats action launch`.
`Action.app` starts its agent helper when it launches.

## Query the agent

```sh
lats action call ping
lats action call status
lats action call permissions.snapshot
```

`status` lists the supported methods, the protocol version, and the path of
the capability-token file. Parameters are a JSON object; the CLI sends each
value as a string:

```sh
lats action call capture.screenshotScreen '{"output":"/tmp/action-screen.png"}'
```

See [API](/action/docs/api) for every method.

## Connect an agent

The app alone does not include the MCP server. To connect Claude Code, Codex,
or another MCP harness, install the matching runtime bundle and configure it as
described in [Agent setup](/action/docs/agent-setup). After that, verify the
install:

```sh
lats action capabilities
```

Expect `runtimeParity.state` to be `matched-source-digest`. A version number
alone does not prove that the app and runtime match.

## Quit

```sh
lats action quit
```

This quits the Action launcher. Prepared [agent-layer](/action/docs/agent-layer)
displays stay connected until you release them explicitly.

## Build from source

Use this path only on a development host. Requirements are macOS 14 or newer,
Bun, and a Swift 6.2 toolchain. Without a developer signing identity, the build
uses ad hoc signing, and permission checks are not stable across rebuilds.

From `products/action` in a Lattices checkout:

1. Install dependencies:

   ```sh
   bun install
   ```

2. Build the signed app:

   ```sh
   bun run native:app:build
   ```

   The build writes `native/dist/Action.app`, including the agent helper.

3. Launch the app:

   ```sh
   bun run native:launch
   ```

   The launch command rebuilds only if the app is missing or older than its
   sources. After a native change, use `bun run native:relaunch`.

4. Check the bundle and permissions:

   ```sh
   bun run native:verify
   bun run native:permissions:status
   ```

5. With permissions granted, run the capture smoke checks:

   ```sh
   bun run native:test:screenshot
   bun run native:test:record
   ```

   The recording check waits for completion and reports the video, the
   `.finished` marker, and the debug log.

`bun run native:doctor` builds, signs, verifies, and reports permissions in one
step. It changes the native build. Do not run it as a read-only check on an
installation target. From the Lattices repository root, `bun run action:launch`
and `bun run action:dev` call the same launch and relaunch scripts.

## Recording is asynchronous

A recording start reply means that startup was accepted. It does not mean that
the recording finished. Completion is the movie file plus a `.finished` marker.
See [Recording](/action/docs/recording).

## Next steps

- [Concepts](/action/docs/concepts)
- [Native runtime](/action/docs/native-runtime)
- [Browser](/action/docs/browser)
