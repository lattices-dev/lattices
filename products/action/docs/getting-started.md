# Getting Started

This is the shortest path to a useful local dev loop for `action`.

## Prerequisites

- macOS on Apple Silicon
- Bun
- Swift/Xcode native build tooling
- willingness to grant Accessibility and Screen Recording permissions for native automation tests

## Install

```bash
bun install
```

## Build The Native App

```bash
bun run native:app:build
```

This produces a signed app bundle at:

`native/dist/Action.app`

## Check Native Health

On an authorized development host, use the doctor wrapper before debugging capture:

```bash
bun run native:doctor
```

This command changes the native build. Do not use it as read-only preflight on
an installation target; install a matched app/runtime with rollback there.
For private layers, read [Agent layer](agent-layer.md) and verify capabilities,
host quarantine, and desktop-preservation acceptance before opening.

The development-host doctor command:

- builds the app if needed
- signs it
- verifies signature state
- reports current Accessibility and Screen Recording status

## Launch The App

```bash
bun run native:launch
```

Rebuild and relaunch after a native change:

```bash
bun run native:relaunch
```

From the Lattices repo root, `bun run action:launch` and `bun run action:dev` call the same scripts.

## Useful Smoke Commands

Check permissions:

```bash
bun run native:permissions:status
```

Request permissions:

```bash
bun run native:permissions:request
```

Run a screenshot smoke test:

```bash
bun run native:test:screenshot
```

Run a recording smoke test:

```bash
bun run native:test:record
```

## Important Runtime Note

Recording is asynchronous.

The initial CLI response means recording startup was accepted. Completion is
represented by the artifact plus a finished marker file written later by the
recording path.

If you are debugging recording, inspect:

- the `.mov` output
- the `.finished` marker
- the debug log passed through `--debug-log`

## Where To Read Next

- [docs/native-runtime.md](docs/native-runtime.md)
- [docs/recording.md](docs/recording.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
