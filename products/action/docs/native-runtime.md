# Native Runtime

This page describes the runtime split that currently makes `action` behave like
a real macOS app instead of a command wrapper pretending to be one.

## The Split

There are two native roles:

## `Action.app`

Owns:

- AppKit lifecycle
- menus and app-switcher behavior
- WebKit windows
- launcher UI
- permission UX
- recording probe execution

Main file:

- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)

## Local Agent Runtime

Owns:

- WebSocket transport
- automation-facing request handling
- local runtime methods
- bridge-friendly command orchestration

Main files:

- [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionAgentClient.swift](native/engine/CoreSources/ActionAgentClient.swift)
- [ActionAgentCommandBridge.swift](native/engine/Sources/ActionAgentCommandBridge.swift)

## Why This Exists

Two important failures pushed the design here:

### 1. WebKit

WebKit behaved unreliably when UI modes were entered through the wrong runtime
path. The fix was to let AppKit own the UI lifecycle cleanly.

### 2. ScreenCaptureKit Recording

Recording was not reliable when attempted inside the wrong lifecycle context.
The stable path now launches a fresh `Action.app` instance in `recording-probe`
mode for the actual capture work.

The lesson is simple:

**AppKit-dependent work should run inside a real app lifecycle.**

## Current Execution Flow

For normal operator usage:

1. `Action.app` launches
2. launcher UI comes up
3. local agent is started if needed
4. UI talks to the agent for runtime state and automation methods

For recording:

1. command or UI requests recording
2. host talks to the local agent
3. agent launches `Action.app` again in `recording-probe` mode
4. probe performs the actual `ScreenCaptureKit` recording
5. artifacts and finished markers are written

## Important Boundaries

Keep these rules intact:

- do not move WebKit lifecycle back into a fake headless command path
- do not move recording implementation back into the plain headless agent path
- keep the agent useful for orchestration and transport
- keep AppKit-owned concerns in the app process

## Private-layer discovery

Use `lats action capabilities` and the active MCP `capabilities` / `tools/list`
for build provenance and routing. Check host quarantine before opening a private
display. Native support, runtime health, and version strings do not establish
physical desktop preservation. See [Agent layer](agent-layer.md).

`native:doctor` builds and signs. Run it on an authorized development host.
On an installation target, preserve the installed bundle and rollback; deploy
a matched app and MCP runtime instead of rebuilding implicitly. Reconnect MCP
after runtime changes.

To assemble a matched runtime candidate on the development host, use:

```bash
bun scripts/package-agent-runtime.ts --app /path/Action.app --output /new/action-runtime --instructions-root /path/to/lattices-docs-checkout
```

The command verifies the signed app's recorded MCP source fingerprint, bundles
the source and locked production dependencies, and includes the selected layer
docs and Action skill. It rejects a mismatched pair or existing output and does
not install anything. `runtime-provenance.json` records the artifact identities
and marks host desktop-isolation acceptance as uncertified. Keep the previous
runtime for rollback and preserve host quarantine when installing a candidate.

The extracted archive contains sibling `bin/` and `products/` directories.
Set `ACTION_ROOT=<extract>/products/action`, not the extraction root, and keep
`bin/host-pairing.ts` in place; the runtime imports that canonical dependency.

## Scripts And Helpers

Call native work through package.json scripts from `products/action`:

```bash
bun run native:app:build
bun run native:doctor
bun run native:launch
bun run native:relaunch
bun run native:host -- status
bun run native:test:screenshot
bun run native:test:record
```

The scripts wrap helpers in [native/engine/scripts](native/engine/scripts). The most important wrappers are:

- `build-app.sh`
- `doctor.sh`
- `run-app-host.sh`
- `test-screenshot.sh`
- `test-record.sh`
