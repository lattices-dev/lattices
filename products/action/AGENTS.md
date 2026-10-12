# action

> Native-first macOS demo automation with an AppKit UI and a local agent runtime

## Critical Context

**IMPORTANT:** Read these rules before making any changes:

- Migration is complete: the original Action main history was merged into arach/lattices at products/action on August 27, 2026 (import commit b1ad511adf509c0c60d7f3edce7cd15257601db2). Use arach/lattices for ongoing development; arach/action is historical.
- On Arach's Mac, /Users/arach/dev/action is a compatibility symlink to /Users/arach/dev/lattices/products/action. Both paths share the Lattices Git checkout and its uncommitted work. Verify the Git root and status before changing files.
- Read ../../AGENTS.md for Lattices workspace rules before applying these product instructions. Keep Action.app, its local agent, and its recording lifecycle independent from the Lattices menu bar app.
- Private layers: read docs/agent-layer.md. Check CLI/MCP capabilities, native/source provenance, host quarantine and `acceptance.privateLayer.state=accepted` before opening. MCP `layer_open {browser:true}` binds a CDP-only session; input failures never authorize native fallback. Reconnect after updates. Version and raw WS methods do not prove feature parity.
- Persistent monitor: `layer prepare` explicitly connects a display and may change desktop topology. Tasks attach with `layer open`; `layer close` restores task windows but leaves the monitor connected. Only explicit `layer release` disconnects it. Check `layer display-status`; never provision or release silently during a task.
- Installation targets use a matched signed app and MCP runtime with rollback. `native:doctor` rebuilds; use it only on an authorized development host.
- Use bun as the JavaScript package manager for this repo.
- Action lives at `products/action/` inside the Lattices monorepo. Run product-local commands from this directory or use the root `action:*` scripts.
- The public product page and published Action documentation live at `https://lattices.dev/action`; source links point into `arach/lattices`.
- Action releases use `action-vX.Y.Z` tags so they cannot collide with Lattices app tags.
- The native product lives in native/engine and builds a signed Action.app bundle.
- Action.app owns AppKit lifecycle, menus, WebKit, permissions UX, and the recording probe path.
- The local Action agent exposes WebSocket methods and should not own fragile AppKit lifecycle responsibilities directly.
- ScreenCaptureKit recording is currently stabilized by launching a fresh Action.app instance in recording-probe mode.
- Recording commands should be treated as asynchronous: the initial CLI reply acknowledges startup, while completion is represented by a finished marker file.
- The repo still contains older design docs in docs/*.md that describe architecture and product direction beyond the Dewey quickstart set.

## Project Structure

| Component | Path | Purpose |
|-----------|------|---------|
| Root | `README.md` | |
| Dewey | `dewey.config.ts` | |
| Native | `native/engine/` | |
| AppHost | `native/engine/Sources/ActionHostMain.swift` | |
| AgentRuntime | `native/engine/CoreSources/ActionAgentRuntime.swift` | |
| RecordingProbe | `native/engine/Sources/RecordingProbeAppRunner.swift` | |
| Launcher | `native/engine/Sources/ActionLauncherViewModel.swift` | |
| Docs | `docs/` | |

## Quick Navigation

- Working with **webkit**? → Read docs/native-runtime.md and native/engine/Sources/ActionHostMain.swift for the AppKit-owned UI lifecycle.
- Working with **record**? → Read docs/recording.md and native/engine/CoreSources/ActionRecordingProbeLauncher.swift before changing recording behavior.
- Working with **agent**? → Read docs/native-runtime.md and native/engine/CoreSources/ActionAgentRuntime.swift for the current app/agent split.
- Working with **permission**? → Check native/engine/Sources/ActionLauncherViewModel.swift and the native wrapper scripts in native/engine/scripts/.
- Working with **build**? → On the authorized development host, use native/engine/scripts/build-app.sh. `native:doctor` rebuilds; it is not read-only installation-target QA.

## Overview

# Overview

`action` is a native-first macOS demo automation project.

It is aimed at a workflow where a human operator or an AI agent can:

- inspect an app, browser surface, or bounded region
- execute deterministic actions
- record raw capture plus structured runtime traces
- turn those traces into polished demo or promo outputs later

## What Exists Today

The current repo is early, but it already has a meaningful native core:

- a signed `Action.app` bundle
- a real AppKit launcher with menus and WebKit support
- a local `Action` agent runtime reachable over WebSocket
- native screenshot and recording commands
- permission and diagnostics wrappers for local development

The strongest proof point right now is native capture:

- screenshot flows work
- `ScreenCaptureKit` recording now works through a real app lifecycle path

## Current Architecture Direction

The project is deliberately split into two responsibilities:

- `Action.app` owns AppKit lifecycle, menus, WebKit, settings, and permission UX
- the local agent owns transport, automation-facing methods, and runtime orchestration

This split exists because UI lifecycle and automation lifecycle are not the same
problem on macOS. Earlier experiments showed that trying to make a command-style
runtime also own WebKit and recording behavior leads to brittle failures.

## Repository Shape

- [README.md](README.md): top-level project framing
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): deeper product and systems architecture
- [docs/VISION.md](docs/VISION.md): product intent and precedent learnings
- [native/engine](native/engine): Swift native engine, app host, local agent, and scripts
- [packages](packages): JS-side tooling and operator surfaces

## What Matters Most Right Now

At this stage, the most important technical goal is reliable native capture.

That means:

- real AppKit lifecycle correctness
- stable `ScreenCaptureKit` recording behavior
- clear artifacts and finished markers
- preserving a clean boundary between UI-owned behavior and agent-owned behavior

## Getting-started

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

## Native-runtime

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

## Recording

# Recording

Recording is the most important runtime path in this project.

This page documents how it currently works and what assumptions should remain
true while the product is still being hardened.

## What Is Stable Right Now

The native recording path now succeeds for:

- bounded region recording
- app-window recording

The successful path produces:

- a `.mov` file
- a `.finished` marker file
- an optional debug log if `--debug-log` is supplied

## The Key Discovery

The main recording bug was not just a bad capture configuration.

The deeper issue was lifecycle ownership:

- `ScreenCaptureKit` recording was unreliable or crash-prone when hosted from the
  wrong runtime path
- a minimal real AppKit app lifecycle succeeded with the same capture logic

That is why the current solution uses a dedicated `recording-probe` mode inside
`Action.app`.

## Current Recording Path

For a region recording request:

1. host command accepts the request
2. host sends a recording method to the local agent
3. agent launches `Action.app` with `recording-probe`
4. probe runner creates a tiny AppKit window and starts recording
5. recording continues until the stop file appears
6. probe writes the finished marker and exits

Core files:

- [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)
- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)

## Testing Recording

The wrapper script is:

```bash
bun run native:test:record
```

For lower-level testing, `run-app-host.sh` can call recording commands
directly.

## Important Caveat

The initial CLI reply usually means:

`recording started successfully`

It does **not** mean:

`recording completed successfully`

Completion is represented by the finished marker file.

## What To Preserve

- real AppKit lifecycle for actual recording work
- stop-file and finished-file based orchestration
- debug-log passthrough for probe runs
- clean app/agent separation even if the app is doing the final recording work

## What To Avoid

- pushing real recording back into a plain headless lifecycle
- assuming a WebSocket ack is equivalent to a completed recording
- removing the probe path before a better lifecycle-safe replacement exists

## ARCHITECTURE

# Architecture

`action` is a ground-up rewrite for agentic macOS demo automation.

It exists because `vif` and `stage` both produced valuable learnings, but neither is the right long-term core:

- `vif` proved there is real value in combining capture, browser/app automation, overlays, audio, and export.
- `stage` proved the architecture should be cleaner, more session-oriented, and more explicit about primitives.
- Both also showed a failure mode: if the scene format, CLI behavior, and runtime lifecycle get tangled together, the tool becomes hard to reason about and easy to break.

The central architectural decision for `action` is:

**The runtime is the product. The scene format is a compiled input, not the architecture.**

Another useful way to say the same thing:

**`action` is an action runtime that can observe, act, reflect, and record.**

## Goals

- Provide a deterministic, session-based runtime for observing apps and browsers, resolving targets, executing actions, reflecting on what happened, and recording structured traces.
- Support agent-authored demo and promo workflows without relying on hidden heuristics or magical state.
- Separate live automation from final composition so polished output can improve without destabilizing the runtime.
- Lean fully into macOS-native fidelity instead of designing for fake cross-platform flexibility.

## Non-Goals

- Not a generic automation framework for every operating system
- Not an Electron-first runtime
- Not a GUI editor in v0
- Not a vision-only “click whatever looks right” system
- Not a scene DSL that owns business logic and runtime state
- Not a VM/container-first automation stack for host UI, browser, or capture
  work

## Core Layers

`action` should be implemented as a small number of strict layers.

### 1. Native Engine

Swift-based macOS engine responsible for:

- ScreenCaptureKit capture
- Accessibility inspection
- Input synthesis
- Window enumeration and positioning
- Overlay windows when needed during live capture
- Audio session and telemetry primitives

The engine should be treated as a capability provider, not the place where product workflows live.

The native layer should be split into separate processes:

- `Action.app`: normal AppKit lifecycle, WebKit, menus, settings, permissions UX
- `ActionAgent`: headless local service exposing WebSocket and local IPC surfaces
- `ActionCLI`: thin operational client that talks to the agent, not directly to UI

This separation is not optional. UI lifecycle and agent lifecycle have different
constraints, and combining them leads to brittle behavior.

### Remote Workers

Remote VMs and containers can still be useful for auxiliary work such as
isolated command execution, rendering, browser-free tests, or heavyweight model
jobs. They should not own the core Action browser, Accessibility, AppKit, or
ScreenCaptureKit paths because those capabilities depend on the user's macOS
host, permissions, windows, and dedicated local Chrome profiles.

### 2. Runtime

The runtime is the heart of the system. It owns:

- session creation and teardown
- lifecycle transitions
- current surfaces and active targets
- observations and resolution logic
- action execution
- reflection and inspection workflows
- traces and artifacts

All mutable run state belongs to a concrete session. Avoid hidden globals and avoid lifecycle behavior that relies on shell cleanup or broad process-kill patterns.

### 3. Compiler

The compiler converts author intent into an executable timeline.

It should:

- validate scene/input structure
- normalize high-level user intent into explicit runtime actions
- attach fallbacks and preconditions
- separate narrative cues from execution steps
- produce an inspectable timeline before execution

The compiler should eventually support more than one input source:

- hand-authored scenario intent
- recorded runtime traces converted into scenario drafts

This matters because one of the most valuable workflows is likely to be:

1. a user demonstrates a flow manually
2. the runtime captures media plus trace
3. `action` derives a reusable scenario from that run
4. the system reruns or polishes it later

### 4. Composer

Composition is a separate phase from capture and execution.

The composer should:

- transform raw captures and runtime traces into a render manifest
- infer or apply zooms, cursor polish, subtitles, callouts, chapter cards, and audio timing
- delegate actual rendering to a backend such as Remotion

This separation is essential. Styling, transitions, and branding should be able to evolve independently from action execution.

The composer should not own live app control, session lifecycle, or target
resolution. It is post-capture orchestration, not the runtime.

### 5. Frontends

Frontends must stay thin.

- CLI: operational control and local authoring workflows
- MCP: agent-facing execution surface
- TS HUD: richer operator console for logs, diagnostics, artifacts, scenario control, and reflection output
- native HUD: minimal always-on capture companion tied closely to runtime truth and immediate controls

They should call the same runtime interfaces, not implement separate behavior.

The HUD split should be deliberate:

- the native HUD should stay minimal and capture-adjacent
- the TS HUD can carry more product richness and operator affordances
- neither HUD should become the owner of runtime truth
- if a HUD is on screen during a live session, it should expose explicit controls instead of acting like passive decoration

## Core Primitives

`action` should keep its vocabulary small and stable.

### Session

One automation run with:

- stable id
- explicit lifecycle
- owned resources
- trace output
- artifact list

Suggested lifecycle:

- `created`
- `preflight`
- `ready`
- `running`
- `paused`
- `completing`
- `completed`
- `failed`
- `cancelled`

### Surface

A place where the runtime can observe or act.

Examples:

- desktop
- app window
- browser tab
- bounded region

### Observation

A typed fact gathered from the engine or browser adapter.

Examples:

- window bounds
- DOM node snapshot
- AX element
- cursor position
- recording state
- audio level

### Reflection

A structured interpretation of current state or recent action.

Examples:

- UI critique from a model provider
- QA finding attached to a screenshot
- target suggestion derived from vision plus AX context
- operator-facing summary of what changed after an action

Reflection is not the same thing as raw observation.

- observations are facts gathered from the system
- reflections are interpretations produced from those facts

The runtime should own reflection sessions, prompts, findings, and artifacts, but
provider-specific model clients should stay outside the native engine. See
[LIVE_INSPECTION_RUNTIME.md](docs/LIVE_INSPECTION_RUNTIME.md).

### Target

A stable reference to something actionable.

Target resolution should support:

- semantic ids
- AX/DOM-based resolution
- bounded text/role matching
- calibrated anchors
- coordinates as last resort

### Action

A deterministic atomic operation.

Examples:

- click
- type
- press key
- focus window
- open app
- start recording
- stop recording
- show cue
- wait for condition

### Cue

A narrative or editorial element that matters to the viewer.

Examples:

- label
- chapter marker
- subtitle
- callout
- caption

### Effect

A render-time presentation element, not necessarily a live overlay.

Examples:

- auto zoom
- smart reframe
- cursor emphasis
- background dimming
- click pulse
- transition

### Artifact

Anything the run produces.

Examples:

- screenshot
- raw capture
- trace log
- focus metadata
- subtitle file
- final rendered video

## Target Resolution

Target picking is a v0 feature, not a nice-to-have.

The system must not normalize blind coordinate clicking as the default interaction model.

Recommended resolution order:

1. semantic target
2. exact accessibility or DOM match
3. bounded fuzzy text/role match
4. calibrated anchor
5. coordinate fallback

Recommended API shape:

- `observe()`
- `target.resolve(query, context)`
- `act(action, target)`

And the resolver must be conservative:

- return confidence
- return ambiguity explicitly
- avoid guessing when multiple candidates are plausible
- allow human or agent inspection before acting

## Execution Model

There are two major phases.

### Live Phase

The runtime:

- prepares the environment
- resolves targets
- executes actions
- captures raw media
- records metadata and trace events

### Compose Phase

The composer:

- consumes raw media and trace data
- computes polish such as zooms and cursor motion
- aligns narration, subtitles, music, and chapter cues
- renders exports via a backend

This split is a hard requirement. It keeps the runtime reliable and the output quality flexible.

## Scene Model

Scenes should describe intent, not be forced to contain all operational detail.

Good scenes should express:

- goal
- context
- surfaces
- targets
- sequence
- narration
- style
- export preferences

The compiler should lower those into an executable timeline with explicit dependencies and fallbacks.

## Render Backend Boundary

`action` should define its own render manifest and allow multiple composition backends.

Near-term plan:

- `composer-core`: manifest schema and transformation logic
- `composer-remotion`: first production backend

This allows `action` to borrow high-quality composition capabilities from tools like Remotion without turning React video rendering into the core product architecture.

## Operational Design Rules

- No daemon mystery states
- No hidden global runtime state
- No broad shell cleanup as the main lifecycle mechanism
- No UI-only source of truth
- No premature cross-platform abstraction
- No scene format that bypasses runtime primitives

## Proposed Package Boundaries

- `packages/protocol`
- `packages/runtime`
- `packages/compiler`
- `packages/composer-core`
- `packages/composer-remotion`
- `packages/cli`
- `packages/mcp`
- `native/engine`

## v0 Definition of Done

`action` v0 should feel solid before it feels broad.

That means:

- explicit session lifecycle
- reliable target resolution
- deterministic action execution
- raw capture plus trace metadata
- polished but backend-driven composition
- clean CLI and MCP surfaces

If v0 cannot reliably observe, resolve, act, record, and compose a basic feature demo on macOS, it is not done.

## AX_BACKGROUND_AUTOMATION

# AX Background Automation

Action should treat macOS Accessibility as the default path for host-native
automation.

The product goal is not to create a second hardware cursor. The goal is to act
through semantic app surfaces while presenting a visual cursor/caret overlay
that explains what is happening.

## Model

For a target app, Action should prefer:

1. read the AX tree
2. resolve a specific element
3. use semantic AX actions or settable attributes
4. show a non-interactive overlay describing the action
5. verify by reading AX state again

The overlay is presentation only. It must not be treated as the input channel.

## Action Ladder

Use the least attention-taking primitive that can complete the task:

1. `observe`: AX tree, window bounds, screenshot.
2. `semantic`: `AXPress`, `AXShowMenu`, set `AXValue`, set `AXSelectedText`.
3. `target-focus`: set `AXFocused`, then send direct app/process events if the
   app requires a focused control.
4. `app-api`: Chrome DevTools Protocol, AppleScript, Shortcuts, or app-specific
   APIs when they are more deterministic than generic AX.
5. `attention`: activate/raise an app, system hotkeys, pointer warping, or HID
   events.

The runtime should record which tier was used for every action.

## Warning Policy

`observe` and `semantic` actions can run silently with the top-right trace.

`target-focus` actions should show a subtle amber notice:

> Target focus may change inside {app}.

`attention` actions should require an explicit, visible warning before execution:

> Action needs foreground control of {app} and may move focus or the pointer.

The user should be able to cancel or defer attention-taking actions.

## Current Daily App Findings

Use:

```bash
bun run native:ax:audit
```

The audit is read-only. It snapshots AX nodes for daily apps and reports:

- roles
- available AX actions
- settable attributes
- pressable elements
- text-like writable controls
- whether the frontmost app changed during the audit

Early local findings:

- Chrome exposes many `AXPress` controls and an `AXTextField` for the omnibox.
- iTerm exposes titlebar/search controls plus a large terminal `AXTextArea`.
- Codex currently exposes a coarse Electron shell: mostly groups and titlebar
  buttons, not a rich editor/input AX tree in this sample.
- Cursor should be audited when running; the script intentionally does not
  launch apps because launching can itself become attention-taking behavior.

## CAPTURE_CONTROLS_PRECEDENT

# Capture Controls Precedent

## Keep

- a countdown that is obvious before capture starts
- controls that stay reachable while the take is live
- runtime-owned truth for recording state and interruption

## Avoid

- a HUD that shows buttons without a real control path behind them
- fake pause states when native capture is not actually paused
- interruption paths that leave recording hanging without a stop marker

## Adapt

- use the native stage HUD as the immediate operator surface
- keep the control channel file-based so the overlay and runner stay loosely coupled
- treat interrupt as a clean stop/cancel path instead of pretending the take can be paused safely

## Decision

- the guided native session will surface countdown skip/cancel before capture starts
- the live take will surface an interrupt control that stops recording cleanly
- cancelled runs will report cancellation explicitly instead of pretending they completed

## Reference Weight

Blend of `vif` product feel and `stage` runtime-boundary discipline.

## COMPOSITION_AND_SCENARIOS

# Composition And Scenarios

## Purpose

This document explains what "composition" means in `action`, and how it relates
to agentic automation, manual capture, and reusable scenarios.

The key point is simple:

**Composition happens after capture.**

It is not the runtime. It is not the session controller. It is not the source of
truth for what happened.

## Core Idea

`action` should separate three concerns:

1. live interaction and capture
2. scenario representation
3. final presentation

Those are related, but they should not be fused into one system.

### Live Interaction And Capture

This is the runtime phase.

It includes:

- observing windows, surfaces, and targets
- acting through clicks, typing, focus changes, and waits
- recording video and screenshots
- collecting structured traces

This is where truth is created.

### Scenario Representation

A scenario is a reusable, inspectable description of what should happen.

It may be authored:

- directly by a human
- directly by an agent
- derived from a recorded session
- derived from a hybrid of user actions plus later cleanup

This is where intent is organized.

### Final Presentation

This is the composition phase.

It includes:

- zooms
- reframing
- cursor emphasis
- chapter cards
- subtitles
- narration timing
- music
- transitions

This is where polish is applied.

## What Composer-Core Should Mean

`composer-core` should be a narrow package.

It should own:

- render-manifest types
- composition-friendly timing structures
- focus-window descriptions
- chapter and subtitle placement data
- effect definitions that can be consumed by a renderer

It should not own:

- live app control
- target resolution
- session lifecycle
- capture start/stop
- HUD control
- input synthesis

That means `composer-core` is not "the video editor." It is the contract between
the runtime's artifacts and a rendering backend such as Remotion.

## Agentic First Still Holds

This architecture is still agentic first.

The agent-facing value comes from:

- stable targets
- deterministic runs
- inspectable traces
- reusable scenarios

The important shift is that the agent should not be forced to author everything
up front.

There are at least three valid ways to create a scenario.

## Three Scenario Sources

### 1. Authored Scenario

A human or agent writes the intended sequence before execution.

Example:

- open Calculator
- type `12`
- click `+`
- type `30`
- press `=`

This is the most direct "agentic automation" mode.

### 2. Recorded Session

A human drives the product manually while `action` records:

- video
- focus changes
- target resolutions
- clicks
- keys
- timing
- window state

Later, `action` can convert that into a structured scenario draft.

This is the mode you were pointing at: a user navigates a website or UI, and the
system turns the observed session into something reusable.

### 3. Hybrid Scenario

The user records an initial pass, and then the system or agent cleans it up:

- replace weak coordinate clicks with semantic targets
- remove dead time
- add preconditions
- normalize waits
- insert cues

This is likely one of the strongest long-term workflows for `action`.

## Why Recorded Sessions Matter

Recorded sessions solve a real product problem.

Many users know how to show the flow they want, but they do not want to author a
scene format from scratch.

If `action` can observe a manual run and convert it into a scenario draft, then:

- onboarding becomes much easier
- the runtime captures real truth from the product
- agents get a better starting point than a blank file
- deterministic reruns become possible after the initial demonstration

This is one of the most compelling directions in the product.

## Proposed Pipeline

The long-term pipeline should look like this:

1. run a live session
2. capture media plus trace
3. derive or refine a scenario from the trace
4. replay or rerun that scenario deterministically
5. compose a polished export from the captured or rerun artifacts

In short:

`capture -> trace -> scenario -> rerun -> compose`

Not every workflow needs every step, but this is the most powerful full loop.

## Trace-To-Scenario

The compiler should not only accept hand-authored scene input.

It should also eventually accept recorded traces as source material.

That implies two compiler inputs:

- `intent -> timeline`
- `trace -> scenario draft -> timeline`

The second path is important because it lets `action` learn from a real user-run
session without turning the runtime into a scene DSL.

## What The Trace Must Preserve

If we want recorded sessions to become reusable scenarios later, the trace needs
to preserve enough structure now.

That includes:

- window and surface identity
- target query and resolution result
- confidence levels
- click positions
- key presses and text entry
- timing boundaries
- state transitions
- artifacts created during the run

This is another reason the runtime matters more than the scene format.

## What Composition Consumes

The composition layer should consume:

- raw video capture
- screenshots
- runtime trace
- viewport and focus metadata
- cues or chapters
- optional voice and music timing

It should then produce:

- a render manifest
- renderer-specific instructions
- final output artifacts

## A Practical Product Reading

A useful way to think about `action` is:

- the runtime is the camera operator and automation system
- the trace is the shooting log
- the scenario is the shot list or repeatable script
- the composer is post-production

That framing keeps the architecture honest.

## Implication For Early Milestones

The first milestone should focus on capture and trace, not polished composition.

That is why the guided capture loop is the right first implementation target.

Once that exists, the system can support:

- direct deterministic demos
- manual guided recordings
- trace-derived scenario drafts
- polished exports later

## COMPUTER_USE_AGENT

# Computer Use Agent — Action Spec

## Context

`action` today is a guided demo workstation: it stages scenes, records sessions, and produces artifacts for post-production. The agent runtime (`ActionAgentRuntime`) handles WebSocket transport and dispatches a small set of deterministic actions (click, type, press-key, drag, recording).

A computer use agent requires a different loop: **observe → think → act → repeat** with autonomous goal pursuit, ongoing perception, and a much wider action surface.

This document describes the gap and the changes needed to close it.

---

## 1. Current State

### What Exists

| Layer | What | Limitation |
|-------|------|------------|
| **Actions** | `click`, `type`, `press-key`, `drag`, `start/stop-recording`, `show-cue`, `wait-for-condition` | No scroll, no context menu, no hotkey combos beyond simple modifiers |
| **Target Resolution** | `semantic`, `accessibility`, `dom`, `textual`, `anchor`, `coordinate` | Resolution is one-shot; no ongoing observation |
| **Perception** | Screenshots on demand, AX snapshots, recording | No continuous frame stream; perception is pull-only |
| **Agent Loop** | None | Session is scripted/guided; no autonomous iteration |
| **Memory** | Trace + artifact persistence only | No working memory, no context accumulation across steps |
| **Tool Surface** | `CaptureEngine` interface | Not exposed as agent tools; no tool-call protocol |

### What Is Missing for Computer Use

- Continuous screen observation (video stream or periodic frames)
- Rich element interaction (scroll, hover, context menu, double-click, text selection)
- Autonomous goal decomposition and retry
- Working memory and context carry-across
- Mouse cursor control with smooth motion
- Key sequences and system hotkeys
- Clipboard access (read/write)
- File system operations
- Process and window management
- Natural language instruction parsing
- Self-correction on failure

---

## 2. Perception Layer

### 2.1 Continuous Frame Stream

Today: screenshots are captured on demand via `captureScreenshot`.

Computer use requires: a periodic frame grab (e.g., every 1–2 seconds) that feeds the agent's vision input.

**Changes:**

- Add a `FrameStream` service in the native layer
  - Captures `CGImage` frames at a configurable interval (default: 1fps)
  - Pushes frames to the agent runtime via WebSocket or a shared buffer
  - Supports pause/resume so the agent only pays for frames when active
- Add `startVisionStream()` / `stopVisionStream()` to `CaptureEngine`
- Frames are small JPEG thumbnails at ~720p for token efficiency

### 2.2 Accessibility Tree Persistence

Today: AX snapshots are taken as discrete artifacts.

Computer use requires: a live, queryable AX tree that the agent can re-query on every step without re-capturing the whole screen.

**Changes:**

- Add an `AccessibilityMonitor` that polls AX tree every ~500ms when active
- Cache the tree in the agent runtime
- Provide `queryAccessibleElement(query: TargetQuery)` method that hits the cache first
- Fall back to a fresh AX snapshot only when the cache is stale (>2s) or query misses

### 2.3 Cursor and Surface Tracking

**Changes:**

- Add `cursorPosition()` to report current mouse coordinates in real time
- Add `activeWindowInfo()` to report frontmost app, window title, and bounds
- These feed into the agent's observation payload on each step

---

## 3. Action Surface Expansion

### 3.1 Interaction Actions

Add these to `ActionKind` in the protocol:

| New Action | Description |
|------------|-------------|
| `scroll` | Scroll a target or the active surface by a delta |
| `double-click` | Double-click at a point or on a target |
| `right-click` | Context menu at a point or on a target |
| `hover` | Move mouse to a point without clicking |
| `text-select` | Select text in a text field or document |
| `text-copy` | Copy selected text to clipboard |
| `text-paste` | Paste clipboard contents |
| `screenshot` | One-off screenshot |

### 3.2 System Actions

| New Action | Description |
|------------|-------------|
| `open-url` | Open a URL in the default browser |
| `open-file` | Open a file with its default application |
| `launch-app` | Launch an application by bundle ID or name |
| `quit-app` | Quit an application |
| `focus-app` | Bring an app's window to front |
| `get-clipboard` | Read current clipboard contents |
| `set-clipboard` | Write text to clipboard |
| `run-shell-command` | Execute a shell command and return output |

### 3.3 Interaction Execution

The existing `executeInteractionAction` in `packages/runtime/src/interaction/index.ts` handles the current action set via `runHost` calls to CLI commands. This pattern should be extended:

```
Action → InteractionExecutor → HostCLI
                         ↘ NativeAutomationBridge (for AX-dependent actions)
```

For `scroll`, `double-click`, `right-click`, `hover`: new host CLI commands.

For `get-clipboard` / `set-clipboard`: native macOS `NSPasteboard` calls.

For `focus-app`, `launch-app`, `quit-app`: `NSRunningApplication` and `NSWorkspace`.

### 3.4 Mouse Motion Path

Today `click-point` snaps the cursor. For computer use with UI agents:

- Add `move-to` command with optional duration for smooth motion
- Use `CGEvent` posting with `kCGHIDEventTap` for smooth cursor movement
- Configurable speed (fast for demos, slow for screen recording legibility)

---

## 4. Agent Loop

### 4.1 Cycle Architecture

```
AgentRuntime
  ↕ vision frames + AX tree
  Agent Loop (external or embedded)
  ↕ tool calls
  CaptureEngine
  ↕ AX + CGEvent
  Action.app / Native Layer
```

The agent loop itself can live:
- **Embedded** in `ActionAgentRuntime.swift` — simple, synchronous loop
- **External** via WebSocket RPC — the agent runs in a separate process (safer isolation)

Option B (external) is preferred: it keeps the native app lifecycle clean and allows the agent to be upgraded without rebuilding Action.app.

### 4.2 Tool Call Protocol

Add a `tools.list` and `tools.call` RPC surface to the WebSocket interface:

```typescript
// Request: list tools
{ "method": "tools.list" }

// Response:
{ "tools": [
  { "name": "screenshot", "description": "...", "parameters": {...} },
  { "name": "click", "description": "...", "parameters": {...} },
  ...
]}

// Request: call tool
{ "method": "tools.call", "params": { "name": "click", "args": { "target": {...} } } }

// Response:
{ "success": true, "result": {...} }
// or
{ "success": false, "error": "..." }
```

### 4.3 Observation Payload

On each loop iteration, the agent receives:

```typescript
interface AgentObservation {
  frame: string;           // base64 JPEG thumbnail
  axTree: AXNode[];         // cached accessibility tree
  cursorPosition: Point;
  activeWindow: SurfaceRef;
  recentActions: ActionTrace[];  // last 5 actions + outcomes
  sessionHistory: ActionTrace[]; // full history
}
```

### 4.4 Self-Correction

When an action fails (AX element not found, app not responding):

1. Increment failure counter on the step
2. Retry with relaxed target (e.g., fall back to coordinate click)
3. After 2 retries, mark step as `failed` and report to agent
4. Agent decides whether to skip, substitute, or abort

---

## 5. Memory and Context

### 5.1 Working Memory

Add a `MemoryStore` to the protocol:

```typescript
interface MemoryEntry {
  key: string;
  value: string;
  ttlMs?: number;
}

interface MemoryStore {
  set(entry: MemoryEntry): void;
  get(key: string): string | undefined;
  delete(key: string): void;
  clear(): void;
}
```

Use cases:
- Remember the last button clicked so the agent can say "I clicked the submit button"
- Store intermediate task results (e.g., "found the settings menu")
- Carry context across steps (e.g., "we are in the Safari preferences pane")

### 5.2 Session Context Carry-Over

Currently each session is stateless. For computer use:

- Add a `session.context: Record<string, unknown>` field
- The agent can write/read this across the session lifetime
- Context is persisted to `manifest.json` so interrupted sessions can resume

---

## 6. Native Layer Changes

### 6.1 ActionHostMain.swift

- Add a `handleToolCall(method: String, args: [String: Any]) -> Any?` entry point
- Route `tools.call` to the appropriate native handler or forward to `ActionAgentRuntime`

### 6.2 AccessibilityMonitor

New Swift class that:
- Creates an `AXUIElement` for the systemwide accessibility observer
- Polls at a configurable interval
- Returns a serialized AX tree as JSON

### 6.3 FrameStreamService

New Swift class that:
- Uses `CGDisplayStream` or periodic `CGWindowListCreateImage` to capture frames
- Compresses to JPEG and pushes via a delegate or notification

### 6.4 AutomationBridge

Refactor `ActionAgentCommandBridge.swift` to expose a cleaner `AutomationBridge` interface:

```swift
protocol AutomationBridge {
    func click(at point: CGPoint) async throws
    func type(text: String, delayMs: Int?) async throws
    func scroll(delta: CGPoint, in bounds: CGRect?) async throws
    func getClipboard() async throws -> String?
    func setClipboard(text: String) async throws
    func getCursorPosition() -> CGPoint
    func getFrontmostApp() async throws -> AppInfo
    func launchApp(bundleId: String) async throws
    func quitApp(bundleId: String) async throws
}
```

This protocol is implemented in `Action.app` (AppKit context) and called from the agent via XPC or direct Swift invocation.

---

## 7. Protocol Changes

### 7.1 New `ActionKind` values

```typescript
export type ActionKind =
  | "click"
  | "type"
  | "press-key"
  | "focus-window"
  | "open-app"
  | "drag"
  | "start-recording"
  | "stop-recording"
  | "show-cue"
  | "wait-for-condition"
  | "scroll"           // NEW
  | "double-click"      // NEW
  | "right-click"       // NEW
  | "hover"            // NEW
  | "text-select"      // NEW
  | "text-copy"        // NEW
  | "text-paste"       // NEW
  | "open-url"         // NEW
  | "open-file"        // NEW
  | "quit-app"         // NEW
  | "get-clipboard"    // NEW
  | "set-clipboard"    // NEW
  | "run-shell-command" // NEW
  | "screenshot";      // NEW (rename from captureScreenshot alias)
```

### 7.2 New `RuntimeAction.input` fields

```typescript
// scroll
{ "deltaX": number, "deltaY": number, "targetId"?: string }

// double-click / right-click
{ "point"?: Point, "targetId"?: string }

// hover
{ "point": Point }

// text-select
{ "start": number, "end": number, "targetId": string }

// open-url
{ "url": string }

// open-file
{ "path": string }

// quit-app
{ "bundleId": string }

// run-shell-command
{ "command": string, "timeoutMs"?: number }

// get-clipboard / set-clipboard
{ "text": string }  // for set-clipboard
// get-clipboard has no input
```

### 7.3 New `SurfaceRef` kinds

```typescript
// Extend SurfaceRef
{ id: string; kind: "desktop" | "window" | "browser-tab" | "region" | "menu" | "dialog"; label: string; bounds?: Bounds }
```

---

## 8. Agent-External vs Agent-Embedded

Two integration strategies:

### Option A: Embedded Agent Loop

The agent logic runs inside `ActionAgentRuntime.swift`, called via WebSocket messages from an external orchestrator.

- **Pros**: Simple IPC, shared memory
- **Cons**: Agent code is coupled to the app; hard to update agent independently

### Option B: External Agent (Recommended)

A separate agent process (Node.js, Python, or custom) connects to `ActionAgentRuntime` via WebSocket as a client. The agent sends `tools.call` messages and receives observation payloads.

- **Pros**: Agent can be updated independently; agent can run on a different machine; cleaner isolation
- **Cons**: Requires a stable WebSocket protocol with backpressure handling

**Recommendation**: Start with Option B using a JSON-RPC-over-WebSocket protocol. Define it in `packages/protocol/src/agent.ts`:

```typescript
export interface AgentMessage {
  jsonrpc: "2.0";
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

export interface AgentNotification {
  jsonrpc: "2.0";
  method: string;
  params: Record<string, unknown>;
}
```

Methods:
- `agent.observation` (notification from app → agent, pushed each loop tick)
- `tools.list` / `tools.call` (request/response)
- `memory.get` / `memory.set` / `memory.delete`
- `session.finish`

---

## 9. Security Considerations

Computer use implies autonomous system interaction. Key concerns:

| Concern | Mitigation |
|---------|------------|
| Unintended file access | Sandboxed to `~/action-sessions/` output dir; no arbitrary file read |
| Password / credential exposure | Never store secrets; agent sees only AX tree and screen frames |
| Unbounded loop | Agent loop must report a maximum step count; session times out |
| Click spam | Cooldown between actions (configurable, default 300ms) |
| Permission escalation | `requestPermissions()` must be user-gesture initiated |

The `Action.app` sandbox profile should be updated to reflect these constraints. For now, this is a local-only tool — no network-exposed agent by default.

---

## 10. Verification

### Smoke Tests for Computer Use Readiness

```bash
# Vision stream
$ curl -X POST ws://localhost:9234 --json '{ "method": "tools.call", "params": { "name": "startVisionStream", "args": {} } }'
$ # Should receive frame payloads every second

# AX tree query
$ curl -X POST ws://localhost:9234 --json '{ "method": "tools.call", "params": { "name": "queryAccessible", "args": { "query": { "role": "AXButton" } } } }'
$ # Should return list of buttons

# Continuous observation loop (5 steps)
$ curl -X POST ws://localhost:9234 --json '{ "method": "agent.startLoop", "params": { "goal": "Open Safari and go to example.com", "maxSteps": 5 } }'
$ # Should stream back 5 observation payloads with decreasing uncertainty
```

---

## 11. Priority Order

1. **Frame stream + AX cache** — foundation for all perception
2. **Expanded action surface** (scroll, right-click, double-click, hover)
3. **Tool call protocol over WebSocket** — makes the external agent possible
4. **Clipboard + shell commands** — unlocks most practical workflows
5. **Memory store** — enables context carry-over
6. **External agent loop** — the actual computer use brain
7. **Self-correction / retry** — closes the loop reliably
8. **Smooth mouse motion** — better demo output

---

## 12. Open Questions

- Should the agent runtime support **interrupt** mid-action (user says "stop")?
- Should there be a **dry-run** mode where the agent describes what it would do without executing?
- Do we want **multiple simultaneous agent sessions**? Today sessions are single.
- What is the **authorization model** for shell commands? Any agent-requested shell is a risk.
- Should we support a **headless variant** of Action.app for server-side computer use?

## LIVE_INSPECTION_RUNTIME

# Live Inspection Runtime

## Why This Matters

`action` should not stop at predetermined demo recording.

The stronger product direction is:

- inspect a live app, browser surface, or bounded region
- send the current state to a model or analysis tool
- get structured findings back
- decide whether to act, record, annotate, or keep inspecting

That is useful for:

- dev workflow capture
- UI critique and QA
- agent-assisted debugging
- exploratory automation before a scenario exists

## Keep

- native capture truth in the runtime
- AppKit-owned UI lifecycle in `Action.app`
- the app/agent split
- traces and artifacts as the durable session record

## Avoid

- baking a specific VLM vendor into the native engine
- turning the app into a chat client with hidden state
- vision-only action without observable targets or trace output
- mixing post-capture review with live runtime control

## Adapt

- treat vision analysis as an inspection provider, not as the runtime itself
- let the runtime own snapshots, context packaging, artifact storage, and action boundaries
- let provider adapters own external API calls and response normalization

## Decision

`action` should gain a **live inspection mode** that sits beside guided capture.

The runtime loop becomes:

`observe -> snapshot -> analyze -> inspect findings -> act or record -> trace`

## Fit With Current Architecture

This direction matches the repo's existing split well:

- `Action.app` owns native windows, overlays, permissions UX, and any always-on inspection HUD
- `ActionAgent` owns transport, orchestration, provider calls, and session state
- the native engine keeps providing screenshots, window bounds, AX data, and input primitives
- review remains a consumer of saved inspection sessions, not the owner of live inspection

The existing design already points this way:

- `observe` is a first-class tool family in [packages/mcp/src/index.ts](packages/mcp/src/index.ts)
- the architecture document already centers `observe`, `resolve`, and `act`
- there are already native inspection-style commands such as [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift#L2115)

## New Product Primitive

Add a first-class primitive:

### Inspection Session

An inspection session is a live runtime session where the main artifact is not only video.

It owns:

- active surface or viewport
- latest screenshot or sampled frame
- optional AX/DOM context
- model prompts and responses
- findings
- optional follow-up actions
- trace and artifacts

Suggested lifecycle:

- `created`
- `staging`
- `observing`
- `analyzing`
- `awaiting-decision`
- `acting`
- `recording`
- `completed`
- `failed`
- `cancelled`

## Proposed Capability Split

### Native Engine

Should provide:

- screenshot current viewport/window/screen
- window and surface metadata
- accessibility tree slices
- optional region selection and overlay framing
- deterministic input execution

Should not provide:

- direct Minimax or OpenAI client logic
- prompt templating
- provider-specific parsing

### Agent Runtime

Should provide:

- inspection session creation
- snapshot packaging
- provider adapter selection
- request/response logging
- trace event emission
- finding normalization
- action gating

### Provider Adapters

Should provide:

- external API invocation
- auth and model selection
- response normalization into `action` finding types

Examples:

- Minimax M2.7 adapter
- OpenAI vision adapter
- local CLI adapter for custom workflows

## Minimal API Shape

The next useful surface is not “chat with the app.”

It is a small inspection API:

- `session.inspect.create`
- `observe.snapshot`
- `observe.axTree`
- `inspect.analyze`
- `inspect.findings.latest`
- `act.execute`
- `record.start`
- `record.stop`

`inspect.analyze` should accept:

- image artifact path
- target surface metadata
- optional AX payload
- prompt or preset id
- provider id

It should return structured findings, not only raw prose.

Suggested normalized finding fields:

- `id`
- `source`
- `summary`
- `severity`
- `kind`
- `bounds`
- `targetHint`
- `evidence`
- `recommendedAction`

## First Increment To Actually Build

Do not start with open-ended streaming vision.

Start with one bounded loop:

1. pick a target app window or viewport
2. capture a screenshot plus AX snapshot
3. send both to a provider adapter
4. store the response as session artifacts
5. show findings in Action
6. optionally let the operator or agent run a follow-up action

That gets the core value without forcing us to solve:

- continuous video analysis
- autonomous acting
- multi-provider prompt orchestration
- generalized browser/DOM fusion

## Recommended v0 Scope

Build **Inspect Current Surface** first.

Inputs:

- current focused app or selected viewport
- prompt preset such as `ui-critique`, `qa-pass`, or `interaction-audit`
- provider selection

Artifacts:

- screenshot
- optional AX snapshot JSON
- provider request JSON
- provider response JSON
- normalized findings JSON
- trace

UI outcome:

- findings list in the launcher review surface
- “Run action from finding” later, not in v0

## Why This Is Better Than “Just Ask A VLM”

If the model call lives outside the runtime, we lose the product.

The value of `action` is that it can:

- create a stable snapshot
- preserve inspection context
- bind findings to a concrete surface and time
- keep a trace of what was observed and what happened next
- turn inspection into a reusable workflow instead of a one-off screenshot prompt

## Suggested Next Build Order

1. add inspection session types and artifacts to the runtime/protocol
2. add a provider adapter interface in the agent/runtime layer
3. implement `inspect current surface` using screenshot + AX snapshot
4. render findings in the launcher review UI
5. add optional “act on finding” follow-up commands

For the precise implementation checklist, see
[RUNTIME_BUILD_CHECKLIST.md](docs/RUNTIME_BUILD_CHECKLIST.md).

## MILESTONE_GUIDED_CAPTURE_LOOP

# Guided Capture Loop

## Purpose

This is the first meaningful milestone for `action`.

The goal is not to finish the whole product. The goal is to prove that `action`
can run a polished, inspectable, native-first capture session end to end.

If this milestone works, we will have validated the most important live-system
assumptions:

- a session-oriented runtime
- a useful operator HUD
- a visible stage with a controlled viewport
- real recording lifecycle control
- deterministic actions against a native app
- artifacts and logs that make the run inspectable afterward

## Mission

Build a native macOS guided capture session where a user can:

1. choose a backdrop and target app
2. see a HUD that reflects session state and logs
3. stage a window inside a viewport
4. trigger a recording countdown
5. record a deterministic Calculator demo
6. save video, screenshot, and trace artifacts
7. replay the last run

This milestone is intentionally live-phase heavy. It validates the runtime and
engine before investing deeply in final-video composition.

## Why This Is First

This milestone gives us the highest-value proof earliest.

- It makes the system feel real immediately.
- It tests the runtime where most failure risk lives.
- It creates the traces and artifacts the composition layer will later consume.
- It gives us a visible product loop instead of isolated backend pieces.

If this is weak, composition will not save the product. If this is solid,
composition can evolve safely later.

## Precedent Review Requirement

Before implementing each major part of this milestone, review how the same area
worked in earlier iterations such as `vif` and `stage`.

For each of these feature areas, write down:

- `Keep`
- `Avoid`
- `Adapt`
- `Decision`

Apply that review to:

- HUD
- stage and viewport
- countdown and recording state
- Calculator scenario flow
- replay and artifact presentation

The purpose is to preserve the strong product instincts from prior work without
re-importing the old architectural problems.

## Scope

### Included

- macOS-only session flow
- native HUD window
- backdrop and viewport framing
- recording countdown
- clear recording-state visuals
- Calculator launch and focus
- click, key press, and type support
- session logs
- screenshot capture
- raw video capture
- replay of the most recent run

### Deferred

- browser flows
- Notes scenario
- subtitle generation
- chapter cards
- voiceover and music timing
- Remotion final export
- multi-window stage layouts
- vision-only target selection

## Success Criteria

The milestone is successful when all of the following are true:

- A user can start a guided session from a single control surface.
- The HUD remains visible and useful during the full run.
- The system can visibly count into recording.
- The viewport clearly indicates what is being captured.
- The area outside the viewport dims during countdown and recording.
- Calculator can be launched, focused, and fit into the viewport.
- The runtime can execute a short deterministic demo using both clicks and keys.
- Every major state transition and action appears in the HUD log.
- The session saves at least one video, one screenshot, and one trace file.
- The most recent run can be replayed from the HUD.

## Primary Demo Scenario

Calculator is the first target because it is simple, native, and good at proving
basic interaction primitives.

### Scenario

1. Start a new session.
2. Select a backdrop preset.
3. Open Calculator.
4. Fit Calculator into the viewport.
5. Trigger a `3, 2, 1` countdown.
6. Start recording.
7. Execute a short expression using both keyboard and click input.
8. Capture a screenshot during or after the interaction.
9. Stop recording automatically or through the HUD.
10. Save artifacts and offer replay.

### Suggested Interaction Sequence

- type `12`
- click `+`
- type `30`
- press `=`

This is enough to prove:

- target window selection
- focus control
- key input
- pointer movement and click
- action logging
- artifact capture

## User Experience Requirements

### HUD

The HUD is a first-class product surface, not a debug panel.

It should show:

- current session state
- elapsed time or recording timer
- current target app
- control buttons
- recent log events
- recent artifacts

Controls for v1 of the HUD:

- `Start`
- `Pause`
- `Stop`
- `Replay Last Run`
- `Quit`

The HUD should feel deliberate and presentable:

- compact
- readable
- elegant
- stable in position
- visually distinct from the captured viewport

There may be two HUD layers over time:

- a minimal native HUD for always-on capture state and immediate controls
- a richer TS-side HUD for logs, diagnostics, artifacts, and operator workflows

For this milestone, the TS HUD is an acceptable first implementation surface as
long as runtime truth still lives below it.

### Stage, Backdrop, and Viewport

The stage is the operator's framing surface.

It should support:

- a chosen backdrop treatment
- one primary viewport
- clear distinction between on-stage content and surrounding space
- window fitting that does not feel accidental

The viewport is the authoritative capture region for the live demo.

### Recording State

Recording must be unmistakable.

The system should provide:

- visible countdown
- dimming outside the viewport
- explicit recording indicator
- obvious transition from staging to recording

## Architectural Implications

This milestone is mostly about three layers:

### 1. Native Engine

Owns:

- window enumeration
- window movement and sizing
- ScreenCaptureKit session control
- native overlays for countdown or viewport emphasis
- input synthesis
- app launch/focus integration

### 2. Runtime

Owns:

- session creation
- lifecycle transitions
- command dispatch
- action execution sequencing
- trace collection
- artifact registration
- replay metadata

### 3. HUD Frontend

Owns:

- user controls
- session-state presentation
- logs view
- artifact list
- replay trigger

The composer is not the main concern in this milestone. The live system is.

## Session Lifecycle For This Milestone

The generic runtime lifecycle should be specialized into an operator-facing flow:

- `created`
- `staging`
- `countdown`
- `recording`
- `paused`
- `completing`
- `completed`
- `failed`
- `cancelled`

Notes:

- `staging` means the target is being prepared and framed.
- `countdown` is a visible pre-recording phase.
- `recording` means capture is live.
- `paused` should preserve enough session state to resume or stop cleanly.

The shared protocol can continue using the broader lifecycle, but the product
surface should expose this narrower guided-capture vocabulary.

## Runtime Events

The run should emit structured events that are useful both for the HUD and for
later composition.

Minimum event categories:

- session state changed
- backdrop selected
- viewport updated
- app launched
- window focused
- countdown tick
- recording started
- recording paused
- recording stopped
- action planned
- action started
- action completed
- action failed
- screenshot captured
- video artifact finalized
- replay requested

Every event should have:

- timestamp
- session id
- type
- human-readable summary
- structured payload

## Artifacts

Minimum artifacts for this milestone:

- raw screen capture video
- screenshot
- trace log
- session metadata

Recommended session folder layout:

```text
artifacts/sessions/<session-id>/
  session.json
  trace.json
  capture.mov
  screenshot-final.png
```

## Package Responsibilities

### `packages/protocol`

- session states
- action and observation types
- HUD event payloads
- artifact metadata types

### `packages/runtime`

- session manager
- lifecycle rules
- trace storage
- artifact registration
- guided-session orchestration

### `packages/cli`

- local operator commands for development
- session start/stop/replay wiring

### `packages/composer-core`

- not primary for this milestone
- may define the future shape of render-manifest inputs

### `native/engine`

- native capture control
- window fitting
- overlays
- app launch/focus
- input synthesis

## Delivery Plan

### Phase 1: Session Skeleton

- finalize milestone-specific lifecycle states
- add runtime event stream for HUD consumption
- define artifact directory layout

### Phase 2: HUD Shell

- create HUD window
- add controls
- add status area
- add scrolling event log
- add artifact list and replay control

### Phase 3: Stage and Viewport

- create backdrop surface
- define viewport region
- fit Calculator into viewport
- add non-captured dimmed surroundings

### Phase 4: Recording Control

- implement countdown
- implement start/stop recording
- implement screenshot capture
- save artifacts per session

### Phase 5: Deterministic Calculator Demo

- open Calculator
- focus window
- run click and keyboard actions
- record action traces in real time

### Phase 6: Replay

- make last run discoverable
- open or preview the latest capture from the HUD

## Definition Of Done

This milestone is done when:

- the full Calculator scenario runs from a single operator flow
- the HUD stays informative and responsive throughout
- recording state is visually clear
- artifacts are saved to a predictable session folder
- replay of the latest run works
- the trace is useful enough to debug failures afterward

## Follow-On Milestones

If this milestone lands well, the next likely milestones are:

1. manual website capture with trace recording
2. Notes scenario with richer typing and selection behavior
3. trace-to-scenario compilation
4. composer-driven polish from captured sessions

That sequence preserves the architectural idea that live capture creates the raw
truth, and composition upgrades presentation later.

## PRECEDENT_HUD_STAGE

# HUD And Stage Precedent Review

## Feature

HUD, backdrop, viewport, and recording-state presentation for the guided capture
milestone.

## Keep

- `vif`: the product feeling that the stage is visible, deliberate, and clearly
  in a recording mode when capture starts.
- `vif`: viewport-first framing with backdrop dimming outside the captured
  region.
- `vif`: a control surface that feels like part of the product, not a raw debug
  console.
- `stage`: clearer separation between operator controls and stage primitives
  such as backdrop and viewport.

## Avoid

- `vif`: HUD and overlay behavior becoming tightly coupled to ad hoc runner
  logic.
- `vif`: letting the UI invent state that diverges from runtime truth.
- `stage`: keeping the stage too abstract or too tool-like to feel like a real
  product surface.

## Adapt

- Keep the richer TS-side operator HUD, but make it render the runtime session
  state directly.
- Treat backdrop and viewport as first-class stage concepts, but avoid binding
  them to a specific renderer too early.
- Use native overlays later for always-on capture-state presence, while the TS
  HUD remains the richer inspection and control surface.

## Decision

- For this milestone, the TS HUD will become stage-aware: it should visibly show
  backdrop, viewport, countdown, recording state, and artifacts.
- The native side remains responsible for capture truth and will later gain the
  thin always-on stage overlay.
- The product contract stays viewport-first: the stage shows what is captured,
  and the rest of the scene is visually subordinate.

## Reference Weight

Blend leaning `vif` for product feel and `stage` for boundaries.

## PRECEDENT_REVIEW

# Precedent Review

## Purpose

`action` is a rewrite, not a fresh invention.

That means every meaningful feature should be implemented with awareness of prior
iterations such as `vif`, `stage`, and other reference products already named in
the vision docs.

The point is not to cargo-cult old code or old abstractions. The point is to
avoid relearning the same lessons and to preserve the parts that were genuinely
good.

## Primary References

There are two primary implementation precedents for this repo:

### `vif`

`vif` is the more mature reference.

Use it for:

- richer product instincts
- features that were already proven in practice
- examples of end-to-end flows that felt real
- areas where the UX had already become compelling

Treat it carefully because it also carries more historical complexity:

- broader product surface
- accumulated lifecycle complications
- architectural entanglement
- features that worked but were hard to reason about internally

### `stage`

`stage` is the less mature reference, but often the cleaner conceptual one.

Use it for:

- stronger boundaries
- cleaner framing of capabilities
- improved instincts around agent-facing primitives
- ideas that look more like a v2 architecture

Treat it carefully because it is also less proven:

- some concepts were still underdeveloped
- some reliability questions were unresolved
- some abstractions were cleaner than their implementation maturity

## How To Read The Two Together

When both references are relevant:

- use `vif` to understand what felt good and what actually mattered in practice
- use `stage` to understand how that idea wanted to be cleaned up architecturally
- do not inherit `vif` complexity just because it is more complete
- do not inherit `stage` abstractions just because they are cleaner on paper

In short:

- `vif` is often the better product reference
- `stage` is often the better architecture prompt
- `action` should combine the strongest parts of both without importing their
  weaknesses

## Additional Reference: Peekaboo

Peekaboo is a strong native implementation reference for:

- permission handling
- Swift-first macOS automation ownership
- CLI and agent surfaces over one underlying automation stack
- separating visual feedback concerns from the lowest-level automation core

It is not the primary product precedent for `action`, but it is highly relevant
when we are deciding how to structure:

- native permissions
- capture services
- macOS automation boundaries
- app/CLI/MCP sharing

Use Peekaboo mainly as an implementation precedent for native host architecture,
not as a reason to broaden `action` beyond the guided demo mission.

## Rule

Before implementing a substantial feature, do a short precedent review.

A substantial feature includes things like:

- HUD
- stage and viewport
- countdown and recording controls
- target resolution
- timeline/scenario format
- overlays and cues
- replay and artifact presentation
- composition/export behavior

## What A Precedent Review Should Ask

For the specific feature being built:

1. What did `vif` do that was genuinely good?
2. What did `stage` do that was genuinely good?
3. What failed in those implementations?
4. What should be preserved in spirit but re-implemented differently?
5. What should be explicitly rejected this time?

Also ask:

6. Is this feature better informed by `vif` as product precedent, `stage` as
   architecture precedent, or both?

The review does not need to be long. It does need to be explicit.

## Expected Output

For each substantial feature, produce a short note before or during
implementation with these headings:

### Keep

- behaviors, UX ideas, or implementation instincts worth preserving

### Avoid

- failure modes, overreach, or known weak abstractions

### Adapt

- ideas that were good but need a different architecture in `action`

### Decision

- what this repo will actually build now

### Reference Weight

- whether this feature leans more on `vif`, `stage`, or a blend of both

## Example: HUD

### Keep

- a persistent control surface
- visible logs and state
- polished feeling, not a debug-only panel
- recording controls that are always easy to reach

### Avoid

- HUD logic owning runtime state directly
- UI behavior diverging from runtime truth
- messy control flow tied to CLI lifecycle hacks

### Adapt

- preserve the operator-first feeling
- move state authority into the runtime session model
- let the HUD render events instead of inventing its own truth

### Decision

- HUD is a thin frontend over guided-session events and controls

## Working Agreement

When implementing features in this repo:

- review the relevant precedent first
- write down the keep/avoid/adapt/declaration summary
- then implement

This keeps the rewrite grounded without letting old architecture silently
control the new one.

## REVIEW_UX_V1

# Review UX V1 (Agent Notes)

## Goal
Turn session review into a fast, reliable "agent note" workflow:

1. seek quickly
2. anchor feedback precisely (point/range/region)
3. write actionable instruction
4. save and revisit notes

This is not a social commenting UI. It is a structured note system for an AI agent.

## Interaction Model

### 1) Single Composer
- One explicit composer entrypoint: `+ Feedback`
- Composer has anchor mode tabs:
  - `Point`: click timeline to stamp a single time
  - `Range`: drag timeline to set in/out
  - `Region`: drag on video frame to select area
- Composer always shows current anchor summary and short mode instructions.

### 2) Timeline As Primary Control
- Timeline must always support click and drag seek.
- Anchor creation overlays on top of seek behavior, not instead of it.
- In range mode, drag previews the range before commit.
- Timeline markers represent saved notes and jump playback on click.

### 3) Frame Region Selection
- Region mode is explicit and visible.
- Drag on frame creates a highlighted area with clear border.
- Region remains visible after selection and after save when focused.

### 4) Notes Rail
- Composer and saved notes live in a dedicated "notes rail".
- Saved notes are scrollable and selectable.
- Selecting a saved note focuses timeline + playback + region context.

## State Rules

- `isComposingFeedback` gates anchor creation.
- `anchorMode` controls source of anchor input:
  - timeline click for point
  - timeline drag for range
  - frame drag for region
- `Save` requires non-empty instruction.
- `Clear Anchors` only clears draft anchors, not saved notes.

## Quality Bar

- No hidden interaction modes.
- Every click/drag should produce immediate visual response.
- No ambiguous labels like "marking" without visible result.
- Primary actions should be discoverable without documentation.

## Follow-up (V1.1)

- Keyboard controls:
  - `N` open composer
  - `1/2/3` switch anchor mode
  - `Esc` cancel region mode
  - `Cmd+Enter` save note
- Inline marker hover previews.
- Optional snap-to-nearest-marker and frame-accurate stepping.

## RUNTIME_BUILD_CHECKLIST

# Runtime Build Checklist

This document is the practical implementation list for turning `action` into a
runtime that can observe, act, reflect, and record.

It is intentionally precise. Items here should be implementable as concrete
tasks, not aspirational themes.

## Product Contract

When this roadmap lands, `action` should support this loop:

1. select a live surface
2. inspect the current state
3. run reflection against that state
4. decide whether to act, record, annotate, or stop
5. preserve a full trace and artifacts

## Workstream 1: Shared Runtime Model

### 1.1 Session Vocabulary

- [ ] Decide whether to keep one session type with modes, or separate `capture`
  and `inspection` session types.
- [ ] Add a stable session mode enum such as `capture`, `inspection`, `hybrid`.
- [ ] Define reflection-specific phases and make them canonical across TS and
  Swift:
  - [ ] `observing`
  - [ ] `analyzing`
  - [ ] `awaiting-decision`
  - [ ] `acting`
- [ ] Define phase transition rules so invalid jumps are impossible.
- [ ] Define which phases allow recording, acting, replay, or dismissal.

### 1.2 Trace Model

- [ ] Add trace events for:
  - [ ] snapshot captured
  - [ ] AX snapshot captured
  - [ ] inspection requested
  - [ ] inspection response received
  - [ ] finding recorded
  - [ ] finding accepted or dismissed
  - [ ] follow-up action started
  - [ ] follow-up action completed
  - [ ] follow-up action failed
- [ ] Record control-origin events:
  - [ ] HUD button pressed
  - [ ] CLI command issued
  - [ ] MCP tool request issued
- [ ] Record provider metadata in the trace without leaking secrets.

### 1.3 Artifact Model

- [ ] Finalize artifact kinds for:
  - [ ] screenshot
  - [ ] raw capture
  - [ ] trace
  - [ ] AX snapshot
  - [ ] inspection request
  - [ ] inspection response
  - [ ] normalized findings
- [ ] Standardize per-session artifact paths.
- [ ] Add a session manifest file listing all artifacts and their roles.
- [ ] Add versioning for saved findings and inspection result formats.

## Workstream 2: Native Engine Capabilities

### 2.1 Surface Discovery

- [ ] Add a native API to enumerate observable surfaces:
  - [ ] running apps
  - [ ] top-level windows
  - [ ] active browser window if applicable
  - [ ] bounded region selection
- [ ] Add a stable surface identifier format.
- [ ] Add a native command to return the currently focused surface.

### 2.2 Snapshot Capture

- [ ] Add a native command to capture the current focused window screenshot.
- [ ] Add a native command to capture a selected viewport screenshot.
- [ ] Add a native command to capture a full screen screenshot without starting
  a recording session.
- [ ] Add timestamped, deterministic snapshot naming.
- [ ] Add geometry metadata to every snapshot artifact.

### 2.3 Accessibility Inspection

- [ ] Generalize the existing Calculator-only inspection commands into
  app-agnostic AX inspection.
- [ ] Add a native command to fetch an AX tree slice for a bundle id or surface
  id.
- [ ] Add a native command to fetch a focused AX element snapshot.
- [ ] Add bounds and role metadata normalization for AX nodes.
- [ ] Add size limits and pruning rules so AX payloads stay usable for model
  calls.

### 2.4 Live Overlay And Controls

- [ ] Keep an always-available native control surface whenever a live session is
  on screen.
- [ ] Make controls phase-aware for:
  - [ ] inspect
  - [ ] apply
  - [ ] start recording
  - [ ] interrupt
  - [ ] cancel
  - [ ] dismiss
- [ ] Add a visible reflecting or analyzing state in the native HUD.
- [ ] Add explicit control affordances for non-recording live sessions.
- [ ] Add an operator-safe way to stop a session that is waiting on external
  analysis.

### 2.5 Input And Acting

- [ ] Keep deterministic input primitives as the only execution path.
- [ ] Add generic click, type, keypress, drag, and focus commands to the
  runtime-facing API where missing.
- [ ] Add optional screenshot-before and screenshot-after hooks for actions.
- [ ] Add a way to bind a follow-up action to a finding target hint.

## Workstream 3: Agent Runtime Core

### 3.1 Session Registry

- [ ] Add a session registry in the agent/runtime layer.
- [ ] Track active session state in one place instead of distributing it across
  UI-only paths.
- [ ] Add explicit resource cleanup per session:
  - [ ] overlay stop files
  - [ ] recording stop files
  - [ ] child processes
  - [ ] temporary inspection request files

### 3.2 Snapshot Packaging

- [ ] Build a snapshot packaging service that can assemble:
  - [ ] screenshot path
  - [ ] viewport metadata
  - [ ] AX snapshot path
  - [ ] surface metadata
  - [ ] runtime notes
- [ ] Add payload size budgeting before a provider call.
- [ ] Add redaction hooks for sensitive text or window titles later.

### 3.3 Reflection Orchestration

- [ ] Add an inspection service in the runtime layer.
- [ ] It should:
  - [ ] create inspection requests
  - [ ] invoke a provider adapter
  - [ ] store raw request and response artifacts
  - [ ] normalize findings
  - [ ] emit trace events
  - [ ] transition the session between `observing`, `analyzing`, and
    `awaiting-decision`
- [ ] Add timeout and cancellation handling for provider calls.
- [ ] Add retry policy rules that avoid duplicate artifact corruption.

### 3.4 Action Gating

- [ ] Require an explicit decision point before executing a model-suggested
  action.
- [ ] Add a runtime policy switch:
  - [ ] operator approval required
  - [ ] agent approval required
  - [ ] auto-apply allowed
- [ ] Log the decision source in the trace.

## Workstream 4: Provider Adapter Layer

### 4.1 Adapter Interface

- [ ] Add a provider adapter interface in the runtime layer.
- [ ] Standardize adapter input:
  - [ ] prompt preset id
  - [ ] freeform prompt
  - [ ] image path
  - [ ] AX context path
  - [ ] surface metadata
- [ ] Standardize adapter output:
  - [ ] summary
  - [ ] findings
  - [ ] optional recommended actions
  - [ ] raw response reference

### 4.2 Minimax Adapter

- [ ] Add a concrete Minimax M2.7 adapter.
- [ ] Read credentials from environment or config, not from the native app.
- [ ] Save the exact request payload sent to Minimax as an artifact.
- [ ] Save the raw response as an artifact.
- [ ] Normalize the response into the internal findings format.

### 4.3 Prompt Presets

- [ ] Define a preset registry for:
  - [ ] `ui-critique`
  - [ ] `qa-pass`
  - [ ] `interaction-audit`
  - [ ] `target-suggestion`
- [ ] Keep preset definitions in a single runtime-owned location.
- [ ] Add versioning so findings can be traced back to a prompt revision.

## Workstream 5: Frontend Surfaces

### 5.1 Launcher

- [ ] Add a top-level inspection workflow in `Action.app`.
- [ ] Add controls to:
  - [ ] inspect current surface
  - [ ] inspect selected app
  - [ ] inspect selected viewport
  - [ ] start recording from current session
- [ ] Add a findings list view.
- [ ] Add a raw context view:
  - [ ] screenshot preview
  - [ ] AX summary
  - [ ] provider summary
- [ ] Add a decision bar for:
  - [ ] apply suggested action
  - [ ] ignore finding
  - [ ] record next step
  - [ ] rerun inspection

### 5.2 Native HUD

- [ ] Keep HUD controls reachable during all live phases.
- [ ] Show when the runtime is:
  - [ ] observing
  - [ ] reflecting
  - [ ] waiting for a decision
  - [ ] acting
  - [ ] recording
- [ ] Make sure the HUD never shows a disabled dead-end state without a visible
  escape path.

### 5.3 TS HUD

- [ ] Add inspection session rendering to the TS HUD.
- [ ] Show latest findings inline with the current screenshot.
- [ ] Show trace events for reflection and action gating.
- [ ] Add artifact previews for inspection request, response, and findings JSON.

## Workstream 6: Agent-Facing Interfaces

### 6.1 CLI

- [ ] Add CLI commands for:
  - [ ] `inspect current-surface`
  - [ ] `inspect app --bundle-id ...`
  - [ ] `inspect viewport --x ... --y ... --width ... --height ...`
  - [ ] `inspect findings`
  - [ ] `session act`
  - [ ] `session record-start`
  - [ ] `session record-stop`
- [ ] Make CLI output distinguish startup acknowledgement from completed
  inspection or recording.

### 6.2 MCP

- [ ] Add MCP tools for:
  - [ ] create inspection session
  - [ ] capture snapshot
  - [ ] request analysis
  - [ ] list findings
  - [ ] execute action
  - [ ] start recording
  - [ ] stop recording
- [ ] Make MCP tools return session ids and artifact references, not only prose.

### 6.3 WebSocket Agent Protocol

- [ ] Expand the agent protocol beyond the current narrow native command set.
- [ ] Add methods for:
  - [ ] session creation
  - [ ] surface enumeration
  - [ ] snapshot capture
  - [ ] AX inspection
  - [ ] provider-backed analysis
  - [ ] findings retrieval
  - [ ] gated action execution

## Workstream 7: Session Storage And Review

### 7.1 Session Layout

- [ ] Standardize a session directory layout that works for both capture and
  inspection sessions.
- [ ] Add `session.json` with:
  - [ ] mode
  - [ ] lifecycle
  - [ ] target surface
  - [ ] provider info
  - [ ] key artifact paths

### 7.2 Findings Persistence

- [ ] Add `findings.json` as a first-class saved artifact.
- [ ] Add support for finding status:
  - [ ] open
  - [ ] accepted
  - [ ] dismissed
  - [ ] acted-on
- [ ] Add finding-to-action linkage so review can explain what happened next.

### 7.3 Review UI

- [ ] Extend the existing review surface to load inspection sessions, not only
  demo captures.
- [ ] Show inspection summary cards beside recordings in the library.
- [ ] Let a user reopen a session and see:
  - [ ] original snapshot
  - [ ] findings
  - [ ] follow-up actions
  - [ ] whether recording happened later

## Workstream 8: Reliability And Safety

### 8.1 Cancellation

- [ ] Ensure every live phase has a tested cancel path.
- [ ] Ensure cancellation writes a final session status and does not strand
  child processes.
- [ ] Ensure provider timeouts do not leave the UI in `analyzing` forever.

### 8.2 Error Handling

- [ ] Normalize native errors, provider errors, and runtime errors into one
  session-visible format.
- [ ] Record failures as trace events and artifacts where useful.
- [ ] Add user-visible recovery guidance for common failure classes.

### 8.3 Permissions

- [ ] Make inspection flows clearly report when Accessibility or Screen
  Recording permissions are missing.
- [ ] Distinguish which operations need which permission.

## Workstream 9: Testing

### 9.1 Protocol And Runtime Tests

- [ ] Add TypeScript tests for:
  - [ ] session phase transitions
  - [ ] finding normalization
  - [ ] artifact manifests
  - [ ] provider adapter contracts

### 9.2 Native Tests

- [ ] Add smoke tests for:
  - [ ] current surface screenshot
  - [ ] AX snapshot fetch
  - [ ] live HUD controls during inspect phases
  - [ ] inspection cancellation
  - [ ] recording start from an inspection session

### 9.3 End-To-End Tests

- [ ] Add one end-to-end inspection path:
  - [ ] stage Calculator or another stable app
  - [ ] capture screenshot
  - [ ] capture AX snapshot
  - [ ] run mock provider analysis
  - [ ] persist findings
  - [ ] apply one follow-up action
  - [ ] optionally record the result

## Recommended Build Order

This is the order that keeps the architecture practical.

### Phase A: Foundation

- [ ] finalize session mode and phase model
- [ ] finalize artifact and trace schema
- [ ] add session registry in the runtime

### Phase B: Native Observe

- [ ] implement surface enumeration
- [ ] implement focused surface screenshot
- [ ] implement generic AX snapshot
- [ ] keep HUD controls live during non-recording sessions

### Phase C: Reflection

- [ ] add provider adapter interface
- [ ] add Minimax adapter
- [ ] add prompt preset registry
- [ ] add findings persistence

### Phase D: Decision And Action

- [ ] add action gating
- [ ] add finding-to-action execution
- [ ] add screenshot before and after action hooks

### Phase E: Record And Review

- [ ] start recording from an inspection session
- [ ] persist hybrid inspection-plus-recording sessions
- [ ] render findings in the launcher and TS HUD

## Done Criteria For The Vision

We are meaningfully on the intended path when all of the following are true:

- [ ] a live app surface can be inspected without starting a demo scenario
- [ ] a model-backed reflection step can run on the captured state
- [ ] findings are stored as first-class session artifacts
- [ ] a user or agent can choose whether to act on a finding
- [ ] a recording can begin from the same live runtime session
- [ ] the full loop is preserved as trace plus artifacts

## SURFACE_ADAPTER_PLAN

# Surface Adapter Plan

> Formalized as [ACT-001: Surface Adapter Architecture](decisions/ACT-001-surface-adapter-architecture.md).
> Keep ACT-001 as the source of truth for the decision/proposal record.

## Principle

Every surface starts with the macOS accessibility tree.

First-class surfaces get complementary semantic channels. Those channels should
make Action faster and more precise, but they should not replace AX as the
baseline source of UI truth.

In practice:

- AX tells Action what app/window/control exists in the OS.
- Native capture tells Action what is visible.
- Adapter-specific channels tell Action what the app means internally.
- Vision verifies visual outcomes when AX or semantic state is incomplete.

## Runtime Shape

Action should expose one runtime contract and many adapters.

```ts
interface SurfaceAdapter {
  id: string;
  label: string;
  priority: number;

  canHandle(surface: SurfaceRef): Promise<AdapterMatch>;
  observe(context: ObserveContext): Promise<SurfaceObservation>;
  resolve(query: TargetQuery, observation: SurfaceObservation): Promise<TargetCandidate[]>;
  act(action: RuntimeAction, target: TargetCandidate): Promise<ActionResult>;
  extract(query: ExtractionQuery, observation: SurfaceObservation): Promise<ExtractionResult>;
  captureHints(target: TargetCandidate): Promise<CaptureHint[]>;
  verify(result: ActionResult, context: VerifyContext): Promise<VerificationResult>;
}
```

The shared observation envelope should look roughly like this:

```ts
interface SurfaceObservation {
  surface: SurfaceRef;
  ax: AXSnapshot;
  native: NativeWindowState;
  semantic?: ChromeDomState | BrowserPageState | TerminalState | EditorState | SiteState;
  vision?: ScreenshotReflection;
  freshness: {
    axCapturedAt: string;
    semanticCapturedAt?: string;
    screenshotCapturedAt?: string;
  };
}
```

The target resolver should produce candidates with evidence, not just a point.

```ts
interface TargetCandidate {
  id: string;
  label: string;
  role?: string;
  rect?: Rect;
  confidence: number;
  stabilityKey?: string;
  evidence: TargetEvidence[];
  preferredActionChannel: "ax" | "dom" | "tmux" | "editor" | "native" | "hid";
  fallbackChannels: string[];
}
```

## Action Policy

The adapter should choose the safest available channel for each action.

Recommended order:

1. App-native semantic action, such as DOM value set, tmux send-keys, or editor command.
2. AX action, such as `AXPress`, `AXValue`, `AXSelectedText`, or settable focused value.
3. Process-directed key or text event.
4. HID event that may move focus or the real pointer.

When an action may disturb the user's current focus, Action should warn through
the overlay before doing it.

Post-action verification should use a different channel when possible. For
example, a DOM set should be verified by DOM state plus AX or screenshot.

## Adapter Families

## 1. Browser App Adapters

Browsers are first-class because a large share of user work happens inside
web apps, and AX alone is too lossy inside complex pages.

### Chrome

Channels:

- AX snapshot for window, omnibox, tabs, web area, and native Chrome controls.
- Chrome extension for DOM observe/act/extract.
- Optional Chrome DevTools Protocol for development and debugging flows.
- Native capture for screenshots, previews, and recording.

Core abilities:

- Inspect current tab URL/title/loading state.
- Return visible DOM nodes with roles, labels, text, rects, selectors, and image URLs.
- Resolve form fields, buttons, links, menus, image cards, and content regions.
- Set input and textarea values with browser events.
- Click page-local elements without moving the OS pointer.
- Return semantic crop hints for top-right preview or recording focus.

### Safari

Channels:

- AX snapshot for window, toolbar, web area, form controls, and page content.
- Safari extension later if the product needs Chrome-like DOM fidelity.
- AppleScript or Safari automation only where reliable.
- Native capture.

Core abilities:

- Browser-window awareness.
- URL/title extraction through AX or scripting.
- Basic target resolution and form interaction.
- Conservative fallbacks when Safari does not expose stable internals.

### Firefox

Channels:

- AX snapshot for browser shell and web area.
- Firefox extension for DOM observe/act/extract if we want parity with Chrome.
- Native capture.

Core abilities:

- Same conceptual model as Chrome, with a smaller initial scope.
- Good enough for users who do not want Chrome.

## 2. Browser Site Adapters And Recipes

Site adapters live inside the browser extension world. They should not be
separate native apps. They specialize the generic browser adapter for high-volume
web products.

Not every product deserves a bundled first-class adapter. The default path
should be:

1. generic browser adapter
2. user-authored or bundled browser recipe
3. first-class site adapter only when usage volume and workflow depth justify it

### GitHub

Why:

- Pull requests, issues, reviews, checks, diffs, and file browsing are common
agent workflows.

Extra semantics:

- PR title/status/checks/review state.
- File tree and diff hunks.
- Comment boxes and review submission controls.
- Repo/branch/commit context.

### Google Search And Docs-Like Surfaces

Why:

- Search, docs, sheets, and web forms appear in many demos.

Extra semantics:

- Search box and result list.
- Document title and editable region.
- Save/sync state when exposed.
- Selection and visible cursor context where possible.

### Midjourney Recipe

Why:

- It is a strong demo and dogfood target for background generation, visual
preview, and rendered result monitoring.
- It is probably too specific for the initial first-class adapter set.

Recipe semantics:

- Create prompt composer target.
- Submit control target.
- Job/result card targets.
- Prompt text associated with result cards.
- Image URL and crop hint extraction.

This should start as a bundled recipe on top of the Chrome companion extension,
not as a bespoke core adapter.

## 3. Terminal Adapters

Terminals are first-class because the user base lives in shells, and terminal
AX output is often weaker than the shell's own state.

### Terminal Base Adapter

Channels:

- AX snapshot for app/window/pane bounds.
- Native capture for terminal screenshots.
- Optional shell integration markers.
- Process/window metadata.

Core abilities:

- Identify terminal app, window title, and visible text region.
- Capture a visible pane region.
- Warn before focus-taking input.
- Detect when only HID/focus-based typing is available.

### tmux

Channels:

- `tmux list-sessions`, `list-windows`, `list-panes`.
- `tmux capture-pane`.
- `tmux send-keys`.
- `tmux display-message` for current command, cwd, and pane metadata.
- AX/native capture for the terminal window that hosts the pane.

Core abilities:

- Resolve a pane by session/window/pane id, title, cwd, or visible text.
- Send keys without using the OS pointer.
- Extract command output reliably.
- Know whether a command exited and with what status when shell integration is available.

### iTerm

Channels:

- AX snapshot for windows, tabs, split panes, and text areas.
- iTerm scripting API where available.
- tmux adapter when iTerm hosts tmux.
- Native capture.

Core abilities:

- Resolve window/tab/session.
- Read visible text where possible.
- Send text/keys through the safest available path.
- Capture exact pane bounds.

### Ghostty

Channels:

- AX snapshot and native capture.
- tmux/shell integration when present.
- App-specific hooks later if Ghostty exposes stable automation APIs.

Core abilities:

- Window/pane bounds.
- Visible terminal text via AX/capture.
- tmux-backed control when applicable.

### Warp

Channels:

- AX snapshot and native capture.
- Block-aware semantics if Warp exposes them through AX or local APIs.
- Shell integration where possible.

Core abilities:

- Resolve command blocks.
- Extract visible block output.
- Warn when input requires focus.

## 4. Coding Surface Adapters

Coding apps are first-class because Action's users spend most of their time in
editors and agent consoles.

### Cursor

Channels:

- AX snapshot for editor shell, command palette, sidebars, terminal panels, and chat.
- VS Code-compatible extension channel if available.
- Filesystem/workspace state.
- Native capture.

Core abilities:

- Identify active workspace, file, selection, editor region, terminal panel, and chat panel.
- Run editor commands through extension APIs where possible.
- Capture focused code regions.
- Avoid stealing focus unless the requested action truly requires it.

### VS Code

Channels:

- AX snapshot.
- VS Code extension API.
- Filesystem/workspace state.
- Native capture.

Core abilities:

- Active file/selection/diagnostics.
- Command palette actions.
- Terminal panel state.
- Extension-mediated text edits and navigation.

### Codex

Channels:

- AX snapshot for the desktop app UI.
- Local workspace and thread context when available.
- Native capture and overlay.

Core abilities:

- Understand chat/input/output regions.
- Track running commands and visible logs where exposed.
- Capture meaningful preview regions.
- Warn before actions that may interfere with the user's current Codex focus.

### Conductor

Channels:

- AX snapshot.
- Local app/project metadata if exposed.
- Native capture.

Core abilities:

- Identify active project/session.
- Resolve chat, task, and result regions.
- Capture agent progress and output state.

## 5. System And Long-Tail Adapters

### Finder And File Pickers

Why:

- Files, save dialogs, open dialogs, downloads, and permissions are frequent
automation edges.

Channels:

- AX snapshot.
- Filesystem APIs.
- Native capture.

Core abilities:

- Resolve file picker fields and buttons.
- Navigate known folders.
- Select files without fragile coordinate clicking when possible.

### System Dialogs And Permissions

Why:

- macOS permission dialogs and settings are unavoidable for capture and
automation products.

Channels:

- AX snapshot.
- System settings URLs.
- Native capture.

Core abilities:

- Detect permission state.
- Open correct settings pane.
- Explain when manual user action is required.

### Generic AX Adapter

This is the long-tail fallback for every other app.

Channels:

- AX snapshot.
- Native capture.
- Optional vision reflection.

Core abilities:

- Inspect app/window/control tree.
- Resolve buttons, text fields, menus, lists, and scroll areas.
- Prefer AX actions over coordinates.
- Use coordinate/HID fallback only with explicit risk labeling.

## 6. User-Authored Adapters

The adapter system should let users teach Action their own high-volume surfaces
without waiting for a bundled adapter release.

There should be three authoring levels.

### Level 1: Recipes

Recipes are declarative target and extraction definitions. They should be enough
for most site-specific and app-specific customizations.

Good fits:

- internal web apps
- niche SaaS tools
- personal dashboards
- demo targets like Midjourney
- simple editor or terminal workflows that mostly need better labels and crops

Example shape:

```json
{
  "id": "user.midjourney.create",
  "label": "Midjourney Create",
  "surface": {
    "kind": "browser-page",
    "urlMatches": ["https://www.midjourney.com/imagine*"]
  },
  "targets": {
    "prompt": {
      "dom": { "role": "textbox", "text": "What will you imagine?" },
      "ax": { "role": "AXTextArea" }
    },
    "latestResult": {
      "dom": { "nearTextTarget": "prompt", "image": true },
      "capture": { "padding": 32, "preferAspectRatio": "16:9" }
    }
  },
  "actions": {
    "submitPrompt": [
      { "setValue": "prompt" },
      { "key": "Enter" },
      { "waitFor": "latestResult" }
    ]
  }
}
```

Recipes should be inspectable, exportable, and safe by default. They can define
targets, fallback selectors, capture hints, waits, and verification checks. They
should not run arbitrary shell commands.

### Level 2: TypeScript Adapter Modules

TypeScript adapters implement a constrained subset of the adapter contract for
users who need logic, not just selectors.

Good fits:

- teams with complex internal tools
- workflow products with stable local APIs
- browser apps where extracting state requires page-specific logic

They should run in a sandboxed runtime with explicit capabilities:

- browser DOM access
- AX snapshot read access
- capture hint generation
- local filesystem read access only when granted
- no native input or shell by default

### Level 3: Native Capability Adapters

Native capability adapters are for integrations that need privileged local
behavior, such as deep terminal or editor control.

These should usually be bundled, reviewed, or explicitly installed because they
can affect the user's OS session.

Good fits:

- tmux
- terminal hosts
- editor extension bridges
- permission/settings flows

### Sharing Model

Adapters and recipes should be packageable as small packs:

- local user recipes
- team-shared packs
- bundled Action packs
- optional community packs later

Each pack should declare:

- surfaces matched
- capabilities requested
- actions it can perform
- whether actions are background-safe
- whether actions may steal focus
- verification strategy

## Initial Adapter Set

The first shippable set should be roughly 15 to 18 adapters:

1. Generic AX
2. Chrome
3. Chrome extension generic web
4. GitHub site adapter
5. Google search/docs-like site adapter
6. Safari
7. Firefox
8. Terminal base
9. tmux
10. iTerm
11. Ghostty
12. Warp
13. Cursor
14. VS Code
15. Codex
16. Conductor
17. Finder/file pickers
18. System dialogs/permissions

Bundled recipes can cover specific demo or workflow targets without promoting
them into core adapters. Midjourney is a good first bundled recipe because it
exercises browser DOM resolution, background action, result monitoring, image
extraction, and semantic preview crops.

This is enough to cover the highest-volume places while preserving a credible
long-tail story through AX.

## Milestones

### Milestone 1: Adapter Registry And Observation Envelope

- Add a runtime-level adapter registry.
- Normalize AX, native window, screenshot, and semantic observations into one envelope.
- Add target candidates with evidence, confidence, rects, and preferred action channel.
- Add action risk classification.

### Milestone 2: Chrome Companion Extension

- Build a minimal Manifest V3 extension.
- Add content-script DOM observe/resolve/act/extract.
- Add native messaging or local WebSocket pairing with Action.
- Use extension rects to drive native top-right semantic previews.
- Keep AX as the Chrome window and toolbar source of truth.

### Milestone 3: tmux And Terminal Family

- Add tmux observe/extract/send primitives.
- Add terminal host detection for iTerm, Ghostty, Warp, and Terminal.app.
- Map tmux pane geometry back to native capture regions.
- Warn when a terminal action requires focus-taking input.

### Milestone 4: Coding Surfaces

- Start with Cursor and VS Code because their extension story is strongest.
- Add active file, selection, diagnostics, terminal panel, command palette, and chat surface observations.
- Add Codex and Conductor as AX-first app adapters with optional local state hooks.

### Milestone 5: Recipe Authoring

- Add a declarative recipe format for browser and AX targets.
- Add local recipe loading, validation, and capability summaries.
- Ship a Midjourney recipe as dogfood, not as a core adapter.
- Add import/export for team-shared recipes.

### Milestone 6: Site Adapters

- Layer GitHub and Google-like flows on top of the browser adapter.
- Promote recipes to first-class site adapters only after repeated usage proves they deserve it.
- Keep site adapters small and evidence-driven.
- Avoid hard-coding pixel layouts when DOM or AX can provide stable targets.

### Milestone 7: Long-Tail Hardening

- Improve generic AX resolution.
- Add screenshot plus local VLM verification.
- Add better ambiguity reporting.
- Add "focus will be stolen" warnings for unsafe actions.

## Definition Of Done For A First-Class Adapter

An adapter is first-class when it can:

- Observe the current state from AX and at least one complementary channel.
- Resolve targets with evidence and confidence.
- Act through the safest available channel.
- Verify the result after acting.
- Provide capture hints for screenshots, zooms, and overlays.
- Explain when it cannot act without interfering with the user.
- Fall back cleanly to generic AX behavior.

## Product Rule

Action should be excellent in the places builders actually live, and still
competent everywhere else.

## V0

# v0 Scope

## Included

- macOS only
- Native session lifecycle
- Observe / resolve / act primitives
- Browser and app target resolution
- Raw screen capture plus cursor/click metadata
- Chapters, labels, subtitles
- Auto-zoom and click emphasis during composition
- Voice and background music tracks
- CLI and MCP frontends
- Remotion composition backend

## Deferred

- Full GUI editor
- Multi-platform support
- Vision-only autonomous clicking
- Complex collaborative timelines
- Multiple simultaneous app surfaces in one live session

## Target Resolution Order

1. semantic ids
2. accessibility or DOM matches
3. bounded text-based fuzzy match
4. calibrated anchor
5. coordinates

Automatic actions should only execute when confidence crosses an explicit threshold.

## VISION

# Vision

`action` is an agentic system for producing polished software demos and promotional videos on macOS.

It is designed for a workflow where an engineer, founder, or AI agent can say:

> Show the core features of this product clearly, stylishly, and repeatably.

And the system can turn that intent into a deterministic run, a trace of what happened, and a polished output that is ready to share.

## Why This Exists

Existing work in this space tends to split into a few categories:

- capture tools that are visually polished but not programmable enough
- automation tools that can click around but do not produce presentation-quality output
- DSL-driven systems that become fragile because execution, lifecycle, and rendering are all mixed together

`action` is meant to bridge those gaps.

It should feel like:

- a serious automation runtime
- a serious demo-production system
- a tool an agent can use confidently

## What We Learned From Prior Work

### From `vif`

Keep:

- ambition around browser/app automation plus media output
- promo/demo orientation
- support for overlays, audio, and export
- the insight that this is useful for AI-agent workflows

Do not keep:

- loosely bounded product surface
- CLI-owned lifecycle complexity
- runtime state spread across unrelated modules
- architectural drift caused by feature accumulation

### From `stage`

Keep:

- cleaner module instincts
- stronger agent-tool framing
- the desire for explicit capabilities and clearer boundaries

Do not keep:

- incomplete lifecycle/error handling
- underdeveloped reliability story
- early-stage abstractions that still need significant hardening

### From Recordly

Borrow:

- the render-time polish mindset
- auto zoom and stylish motion language
- cursor smoothing and emphasis
- project/artifact-oriented composition

Do not borrow:

- editor-first assumptions as the primary architecture
- GUI-centric runtime control

### From Stagehand

Borrow:

- the conceptual separation of `observe`, `act`, and `extract`
- conservative, inspectable target resolution
- agent-friendly interaction model

### From Peekaboo

Borrow:

- native-first Swift ownership of macOS automation concerns
- explicit permission handling as a first-class product concern
- thin consumer surfaces over a shared automation core
- the idea that visual feedback can be a distinct layer instead of being mixed into runtime truth

Do not borrow:

- a broad automation surface before the guided demo loop is solid
- product sprawl caused by trying to cover every macOS interaction mode too early

### From QuickRecorder and similar macOS-native tools

Borrow:

- native-first capture fidelity
- macOS-specific optimizations
- acceptance that cursor, capture, and media quality are better when treated as native concerns

### From Remotion

Borrow:

- rendering and templating as a backend capability
- separation of composition from capture/runtime concerns

Do not borrow:

- the temptation to make the rendering layer define the whole product

## Product Vision

The ideal end-state for `action` is:

1. an agent can inspect an app or website
2. resolve meaningful targets safely
3. execute a demo scenario deterministically
4. record raw media and rich metadata
5. automatically produce a polished output with zooms, cues, subtitles, and audio

The user should not need to hand-author every coordinate or every transition.

The user should be able to define intent, constraints, and style, while `action` handles the hard parts around:

- target resolution
- runtime stability
- capture fidelity
- metadata collection
- composition orchestration

## What `action` Should Be Great At

### 1. Agentic Demos

An AI agent should be able to:

- inspect available windows and surfaces
- resolve likely targets
- ask for confirmation when resolution is ambiguous
- execute a feature demo in a repeatable way

### 2. Product Storytelling

The output should feel closer to a polished product walkthrough than a raw screen recording.

That means:

- chapter cues
- focus guidance
- subtitles
- tasteful zooming and reframing
- cursor clarity
- music and narration support

### 3. Deterministic Runs

A run should leave behind a trace that explains:

- what was observed
- what targets were resolved
- what actions were taken
- what failed or was ambiguous
- what assets were produced

This is essential both for debugging and for agent trust.

### 4. Strong Native Fidelity

The system should feel designed for macOS, not merely compatible with it.

That includes:

- ScreenCaptureKit quality
- Accessibility API targeting
- native window handling
- native cursor and input behavior

## What We Explicitly Do Not Want

- a haunted runtime with hidden background state
- click automation that guesses recklessly
- a giant scene DSL that becomes the true implementation
- a framework that claims to be universal before it is reliable
- premature editor complexity
- a product that is visually polished but operationally fragile

## Design Taste

`action` should feel:

- deliberate
- inspectable
- native
- cinematic
- composable
- dependable

The cinematic part matters. This is not merely automation; it is automation in service of making good-looking software demos.

## v0 Aspiration

The first successful version of `action` should let a user or agent:

- define a short demo scenario
- run it against a macOS app or browser flow
- get a raw capture plus trace
- generate a polished edit with:
  - zooms
  - click emphasis
  - labels or chapters
  - subtitles
  - optional voice/music

That would already be meaningfully better than either a plain recorder or a plain automation tool.

## Strategic Direction

`action` should be built as a stable core with borrowable edges.

The system should own:

- runtime behavior
- session model
- targeting model
- trace model
- render manifest

And it should delegate where appropriate:

- Remotion for polished render backends
- FFmpeg or similar tools for specific media-processing tasks
- browser adapters for DOM-specific observation and action

This allows the product to move quickly without surrendering architectural control.

## Working Name

`action` is a good working name because it fits the cinema lexicon and reinforces the runtime emphasis.

It may or may not be the final public name. The architectural direction matters more than the branding for now.

## Api

# API

This page documents the current local agent protocol for `action`.

The protocol is intentionally small right now. It is enough to support native
health checks, permissions, window control, screenshots, and recording.

Primary source:

- [ActionAgentProtocol.swift](native/engine/CoreSources/ActionAgentProtocol.swift)

## Transport

- Protocol: WebSocket
- Default host: `127.0.0.1`
- Default port: `4319`

## Request Shape

```json
{
  "id": "uuid-string",
  "method": "capture.recordRegion",
  "params": {
    "output": "/tmp/example.mov"
  }
}
```

Fields:

- `id`: request id, defaults to a UUID in native clients
- `method`: string name from `ActionAgentMethod`
- `params`: flat string map

## Response Shape

```json
{
  "id": "uuid-string",
  "ok": true,
  "result": {
    "status": "finished"
  },
  "error": null
}
```

Fields:

- `id`: mirrors request id
- `ok`: success flag
- `result`: optional flat string map
- `error`: optional error string

## Methods

| Method | Purpose | Key Params |
|---|---|---|
| `ping` | basic liveness check | none |
| `status` | server metadata and supported methods | none |
| `permissions.snapshot` | current permission state | none |
| `permissions.request` | request or prompt for permissions | none |
| `settings.openAccessibility` | open Accessibility settings pane | none |
| `settings.openScreenRecording` | open Screen Recording settings pane | none |
| `app.activate` | bring an app forward | `bundleId` |
| `window.setFrame` | move/resize an app window | `bundleId`, `x`, `y`, `width`, `height` |
| `window.getFrame` | inspect current app window frame | `bundleId` |
| `capture.recordAppWindow` | record a target app window | `bundleId`, `output`, optional `stopFile`, `finishedFile`, `debugLog` |
| `capture.recordRegion` | record a bounded region | `x`, `y`, `width`, `height`, `output`, optional `fps`, `scale`, `stopFile`, `finishedFile`, `debugLog` |
| `capture.screenshotAppWindow` | screenshot a target app window | `bundleId`, `output` |
| `capture.screenshotRegion` | screenshot a bounded region | `x`, `y`, `width`, `height`, `output` |
| `capture.screenshotScreen` | screenshot the main display | `output` |

## Recording Contract

Recording methods have a special lifecycle:

- startup success means the recording path was accepted
- actual completion is represented by the finished marker file
- for debugging, pass `debugLog`

This matters because recording is currently performed by launching a real
`Action.app` probe instance rather than keeping the full recording lifecycle
inside the headless agent process.

## Browser-profiles

# Browser Identity: Regular Chrome, Action Browsers, Seeded Identities

How Action gives an agent a **browser identity** without taking over your daily
Chrome — and which kind of control you get in each case.

## Three browsers, two kinds of control

When an agent says "I'll open it in Chrome", it can mean one of three things.
They are not interchangeable.

| | What it is | What the agent can do |
|---|---|---|
| **1. Your regular Chrome** | The browser you use all day. Your real profiles (`Default`, `Profile 1` / "Work"), your tabs, history, extensions, and logins. | **Open a URL, and that's it.** `browser_open { mode: "regular" }` is a visible handoff with no DevTools attachment. To make the agent *act* there, use Action's native macOS control: screen capture + accessibility (`action.observe.snapshot`, `action.resolve.target`, `action.act.execute`). |
| **2. An Action browser** | A real, non-headless Chrome that Action owns, on its own user-data-dir under `~/Library/Application Support/Action/ChromeProfiles/`. The default identity `agent-browser` is blank and signed into nothing. | **Full DOM control** over CDP: `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot`, `browser_tabs`. |
| **3. An Action browser identity seeded from one of your Chrome profiles** | The same Action-owned Chrome under a name you choose (`work`, `mira`, …), carrying cookies copied from one of your real profiles for an explicit allowlist of domains. | **Full DOM control, on sites you're already signed in to.** |

The tradeoff in one line: **your regular Chrome has your session but only
screen-and-accessibility control; an Action browser has DOM control but starts
as a stranger.** Seeding (option 3) is how you get both.

This is a boundary Action does not try to cross. [Chrome 136 and later ignore
remote-debugging switches for the default personal data
directory](https://developer.chrome.com/blog/remote-debugging-port), and Action
does not attempt to bypass it. Pointing automation at your everyday user-data-dir
would also fight Chrome's directory lock and hand an agent your full history,
extensions, and sessions by accident.

### Picking one

- The user wants to *look* at something in their own browser → **regular**.
- The agent needs to click through a public site → **Action browser**.
- The agent needs to click through a site you're logged into → **seeded identity**.
- The agent needs to act inside your real signed-in session, and cookies aren't
  enough (passkeys, SSO device trust, an extension's state) → **regular Chrome
  plus Action's native observe/act**, not the browser tools.

## The canonical example: seed "Profile 1" into `work`, then drive it

Your Chrome profile *directory* names are `Default`, `Profile 1`, `Profile 2`, …
and are not the display names you see in Chrome's avatar menu. A browser you
call "Work" is usually the `Profile 1` directory. Map them first, then seed.

From an agent, over MCP:

```text
browser_import_cookies { listSourceProfiles: true }
# -> [{ dir: "Default", name: "Personal" }, { dir: "Profile 1", name: "Work" }, ...]

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"] }
# dry run: lists exactly which cookies would be copied

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"], confirm: true }
# writes them into the Action identity `work`

browser_open { url: "https://github.com/notifications", profile: "work" }
browser_snapshot
browser_screenshot
```

The same thing from the terminal:

```bash
# map display names to profile directories
bun run chrome:companion:import:cookies -- --list-profiles

# dry run
bun run chrome:companion:import:cookies -- list --into work --source "Profile 1" --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --source "Profile 1" --domains github.com --confirm
```

After that, `work` is an ordinary Action identity: `browser_use_profile
{ profile: "work" }` or `browser_open { url, profile: "work" }`, and every DOM
tool works against it.

## Named identities

Identities are created on first use — any unused name gives you a fresh blank
one. Shipped conventions:

- `agent-browser` — the default blank agent identity
- `work` — seeded from your work Chrome profile, per the example above
- `mira` — the creative/Midjourney identity used by the companion tooling

Create and prepare one with the companion extension loaded:

```bash
# from the Action product root (`products/action`)
bun run chrome:companion:profile -- setup work
```

This builds the companion extension, creates the profile directory, opens
`chrome://extensions` in that profile, and reveals `packages/chrome-companion/dist`
so you can **Load unpacked** once.

Later:

```bash
bun run chrome:companion:profile -- launch work
bun run chrome:companion:profile -- check work
bun run chrome:companion:profile -- path work
```

Environment aliases (shared between companion tooling and Action Browser MCP):

| Variable | Meaning |
|----------|---------|
| `ACTION_BROWSER_PROFILE` / `ACTION_CHROME_COMPANION_PROFILE` | Active identity name |
| `ACTION_BROWSER_PROFILE_DIR` / `ACTION_CHROME_COMPANION_PROFILE_DIR` | Absolute user-data-dir override |
| `ACTION_BROWSER_PROFILE_ROOT` / `ACTION_CHROME_COMPANION_PROFILE_ROOT` | Root for named identities |
| `ACTION_BROWSER_DEBUG_PORT` | CDP port (MCP default `9334`) |
| `ACTION_ROOT` | Action product root (`<lattices-checkout>/products/action`); cookie tools use it when the MCP process starts elsewhere |

## Cookie seeding

Copy **selected** cookies from a regular Chrome profile into an Action identity:

```bash
# list your Chrome profiles (directory + display name)
bun run chrome:companion:import:cookies -- --list-profiles

# list Action identities
bun run chrome:companion:import:cookies -- --list-action-profiles

# dry-run
bun run chrome:companion:import:cookies -- list --into work --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --domains github.com --confirm

# narrow to specific cookies
bun run chrome:companion:import:cookies -- import --into mira \
  --domains midjourney.com \
  --only cf_clearance \
  --confirm
```

Or via the profile CLI:

```bash
bun run chrome:companion:profile -- import-cookies import --into work --domains github.com --confirm
```

Notes:

- Requires a Keychain allow for Chrome Safe Storage only when decrypting values;
  the import path copies encrypted blobs as-is for same-machine use.
- Prefer domain allowlists over full-jar dumps.
- Cookies are not a complete identity (localStorage / passkeys may still need a
  one-time interactive login in the Action identity).

## Chrome Companion (generic extension)

Package: `packages/chrome-companion`

- Manifest V3 extension with DOM observe / resolve / act helpers
- Localhost bridge on `http://127.0.0.1:4321` (WebSocket for the extension)
- One-time **Load unpacked** per Action identity (`dist/` after build)

```bash
bun run chrome:companion:build
bun run chrome:companion:bridge
bun run chrome:companion:health
bun run chrome:companion:profile -- setup work
```

Chrome Stable often ignores `--load-extension`; the reliable path is manual
unpacked install inside the Action-owned identity.

## Action Browser MCP

Server: `bin/mcp/toolsets/browser/index.ts` in the lattices repo root — the
browser tools are a toolset inside the lattices MCP, served by `lattices mcp`.
See [the lattices MCP doc](../../../docs/mcp.md).

### Tools

| Tool | Purpose |
|------|---------|
| `browser_profiles` | List Action identities, the active one, and the three-surface policy |
| `browser_use_profile` | Switch the active identity (`agent-browser`, `work`, `mira`, …) |
| `browser_profile_info` | Active path, cookie readiness, companion hints |
| `browser_import_cookies` | Dry-run or confirm a seed from a regular Chrome profile |
| `browser_companion_status` | Extension dist + bridge health |
| `browser_open` | Open in an Action browser, or `mode: "regular"` for an open-only handoff |
| `browser_tabs` / `browser_snapshot` / `browser_click` / `browser_fill` / `browser_screenshot` / `browser_close` | DOM automation via CDP — Action browsers only |
| `browser_resize` | Set a tab to an explicit viewport width and height for responsive checks; `target: "window"` resizes the real Chrome window instead |

### Two MCP surfaces

- **Native runtime MCP** (`action`): observe / resolve / act / record on macOS
  through Action.app. This is what controls your *regular* Chrome window, and
  every other native app, via screen capture and accessibility.
- **Browser MCP** (the `browser` toolset of `lattices mcp`): Action-owned Chrome
  identities plus DOM-level tools over CDP.

Register it. The entry names the `lattices` binary and no path, so a repo move or
a version bump cannot break it:

```bash
claude mcp add lattices -s user -- lattices mcp
```

To pin a default identity, add the environment variable to that same entry:

```bash
claude mcp add lattices -s user -e ACTION_BROWSER_PROFILE=work -- lattices mcp
```

`ACTION_ROOT` is only needed for the Chrome Companion paths below, and only when
the tools run from a published `lattices` install rather than a checkout.

### Agent workflow

```text
browser_profiles                                   # what identities exist
browser_use_profile { profile: "work" }            # pick one
browser_open { url: "https://github.com" }         # drive it
browser_snapshot
browser_screenshot
browser_companion_status                           # optional richer DOM path
browser_close { scope: "browser" }                 # when the task is done
```

To open a URL in the user's own Chrome instead:

```text
browser_open { url: "https://github.com", mode: "regular" }
```

Regular mode is deliberately not controllable, and the result says so:
`controlAvailable: false`, plus the native control path. Snapshot, click, fill,
and screenshot continue to target the Action browser.

### Responsive breakpoints

`browser_resize` gives an already-open tab an explicit viewport, so a narrow
layout can be captured instead of assumed.

```text
browser_open   { url: "http://localhost:3000" }
browser_resize { width: 1440, height: 900 }
browser_screenshot
browser_resize { width: 390, height: 844, mobile: true, matchMedia: ["(max-width: 767px)"] }
browser_screenshot
browser_resize { reset: true }
```

Two targets, deliberately not interchangeable:

| | What moves | Cost |
|---|---|---|
| `target: "tab"` (default) | CSS emulation for that one tab | Exact to the pixel, other tabs unaffected, fully reversible |
| `target: "window"` | The real Chrome window hosting the tab | Every tab in that window moves, the display is a hard ceiling, and the tab's emulated viewport is dropped first |

A device-metrics override belongs to the CDP session that set it, and Action
Browser opens a fresh session per tool call. Two consequences shape the design:

- The server keeps the requested viewport in memory and re-applies it on every
  session, so a resize survives the later `browser_screenshot` that is the whole
  point of it. It is per-tab, in-memory only, and dropped when the tab or the
  browser closes — nothing is written to the profile.
- `reset` cannot simply call `clearDeviceMetricsOverride`: a foreign session's
  clear is accepted and does nothing, leaving Chrome stuck at the stale size. The
  reset re-sets the metrics to adopt ownership first, then clears them.

`deviceScaleFactor` defaults to `1`, which makes screenshot pixels equal CSS
pixels — a 390-wide viewport returns a 390px-wide PNG. Read `exact` in the reply
before trusting a capture: a page with a hard `min-width` can refuse to lay out
as narrow as it was asked to.

## Plugin versioning

Harnesses cache the Action Browser skill and interface metadata by plugin
version. Bump all seven manifests together when that metadata changes:

```bash
bun run plugin:version              # check that every manifest agrees
bun run plugin:version -- 0.4.1     # set them all
```

The check covers the root and Action product marketplace/Kimi manifests, plus
the browser plugin's Claude, Codex, and Kimi manifests. Reinstall or refresh the
plugin in each harness so its cached skill is replaced.

The plugin no longer carries an MCP server or a `SERVER_VERSION`. Browser tools
ship with the lattices CLI; updating that CLI and restarting its MCP process
updates the server separately from refreshing this skill-only plugin.

## What is intentionally not done

- Automation attachment to the currently open regular Chrome window
- Silent full cookie jar import
- Claiming a page is authenticated without observing it after seed/login

## Related

- [packages/chrome-companion/README.md](../packages/chrome-companion/README.md)
- [ACT-001 surface adapter architecture](decisions/ACT-001-surface-adapter-architecture.md)
- [plugins/action-browser/skills/action-browser/SKILL.md](../plugins/action-browser/skills/action-browser/SKILL.md)

## Browser request deadlines

`browser_open.waitMs` is the total operation budget (15,000 ms by default),
including profile selection, Chrome startup, HTTP/CDP connection, navigation,
and readiness checks. Zero fails immediately without opening a tab. Expiry
returns an MCP tool error and cancels pending transport work; increasing
`waitMs` does not remove the 10-second limit on individual HTTP/CDP operations.

Configure the MCP server as `command: "lattices", args: ["mcp"]` — no path, so it
cannot be pinned to a stale checkout or plugin cache. On the next MCP process
start, `initialize` reports the lattices version, and `tools/list` exposes
`browser_open.mode`, `profile`, and `newTab`. Existing MCP processes retain their
loaded implementation until reloaded.

The `lattices` launcher resolves Bun from `LATTICES_BUN_BIN`, PATH, or the
standard user and Homebrew locations, so it survives the bare system PATH a
GUI-launched harness hands it. An explicit invalid override fails with an
actionable error.

## Native-runtime.agent

# Native Runtime (Agent)

## Ownership Model

### `Action.app`

Owns:

- AppKit lifecycle
- launcher UI
- WebKit windows
- menus and app identity
- recording probe mode

Primary files:

- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- [ActionLauncherController.swift](native/engine/Sources/ActionLauncherController.swift)
- [ActionLauncherViewModel.swift](native/engine/Sources/ActionLauncherViewModel.swift)

### Agent Runtime

Owns:

- WebSocket listener
- request dispatch
- automation method surface
- launching the recording probe

Primary files:

- [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionAgentClient.swift](native/engine/CoreSources/ActionAgentClient.swift)
- [ActionAgentCommandBridge.swift](native/engine/Sources/ActionAgentCommandBridge.swift)

## Recording Rule

- Do not implement real recording directly in the headless agent path.
- Use [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift).
- The probe launches `Action.app` with `recording-probe` args.
- The probe runner performs the actual `WindowRecorder` call.

## WebKit Rule

- WebKit belongs to the app lifecycle.
- If a change touches browser windows, inspect the AppKit entry path before changing configuration.

## Debug Order

1. Confirm the signed app build exists.
2. Confirm whether the failure is app lifecycle, agent transport, or probe execution.
3. For recording, inspect `.mov`, `.finished`, and debug log together.
4. Do not trust initial `"recording"` replies as proof of completion.

## Overview.agent

# Overview (Agent)

## Project

- Name: `action`
- Type: monorepo with native macOS runtime focus
- Primary native surface: `Action.app`
- Primary automation surface: local WebSocket agent runtime

## Current Truth

- Native app lifecycle matters more than CLI convenience for WebKit and recording.
- `Action.app` is the owner of AppKit lifecycle, menus, WebKit, and permission UX.
- Recording stability currently depends on running capture in a fresh app instance via `recording-probe`.
- The agent is for transport and orchestration, not for pretending to be a full UI lifecycle host.

## Entry Points

- Root framing: [README.md](README.md)
- Native host main: [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- Agent runtime: [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- Recording probe launcher: [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- Recording probe app runner: [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)

## Use This Page For

- quick repo orientation
- understanding app-vs-agent ownership
- finding the files that currently define runtime truth

## Do Not Assume

- that command-mode execution owns the correct macOS UI lifecycle
- that the agent should directly host all AppKit-dependent behavior
- that older architecture docs always describe the latest capture implementation details

## Recording.agent

# Recording (Agent)

## Status

- Region recording: working through app-backed probe path
- App-window recording: working through app-backed probe path
- Success artifacts: `.mov` + `.finished`

## Control Flow

1. caller invokes `record-region` or `record-app-window`
2. host sends request to agent
3. agent calls [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
4. launcher runs `open -n Action.app --args recording-probe ...`
5. probe runner uses [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)
6. probe uses `WindowRecorder` inside a real AppKit lifecycle

## Files To Read

- [ActionHostMain.swift](native/engine/Sources/ActionHostMain.swift)
- [ActionAgentRuntime.swift](native/engine/CoreSources/ActionAgentRuntime.swift)
- [ActionRecordingProbeLauncher.swift](native/engine/CoreSources/ActionRecordingProbeLauncher.swift)
- [RecordingProbeAppRunner.swift](native/engine/Sources/RecordingProbeAppRunner.swift)

## Debugging Rules

- Initial `"recording"` response is startup ack only.
- Finished marker is the completion signal.
- If present, `--debug-log` should be inspected before changing capture configuration.
- If recording fails again, validate lifecycle assumptions before tweaking `ScreenCaptureKit` settings.

## Invariants

- Recording implementation should stay app-backed until a safer replacement exists.
- Probe mode must remain available from the signed app bundle.
- App lifecycle correctness is a recording dependency, not an optional detail.

## Skill

# Action Skills

These are project-specific skills or task patterns an AI agent should follow.

## Native Runtime Review

Use when:

- changing AppKit lifecycle code
- changing agent startup or bridge logic
- changing WebKit entry paths

Instructions:

1. read [docs/native-runtime.md](docs/native-runtime.md)
2. verify whether the change belongs in app code or agent code
3. keep AppKit-owned behavior in `Action.app`
4. verify the signed app still builds

## Recording Review

Use when:

- changing `ScreenCaptureKit` recording
- changing stop-file or finished-file handling
- changing probe launch behavior

Instructions:

1. read [docs/recording.md](docs/recording.md)
2. inspect the probe launcher and probe app runner
3. preserve `.mov` + `.finished` behavior
4. test a real recording path, not just a unit-level refactor

## Agent API Review

Use when:

- adding WebSocket methods
- changing request or response shape
- updating CLI-to-agent behavior

Instructions:

1. read [docs/api.md](docs/api.md)
2. update the protocol source of truth
3. confirm method names remain documented
4. verify callers still match the transport contract

## Hermes Action

Use when:

- connecting Hermes to the native Action runtime
- using Action MCP tools from a harness
- recording or inspecting native macOS surfaces through Hermes

Instructions:

1. read [docs/harnesses/hermes-action.md](harnesses/hermes-action.md)
2. use [skills/hermes-action/SKILL.md](../skills/hermes-action/SKILL.md) as the harness doctrine
3. prefer observe and resolve before act
4. treat recording start as asynchronous until `.finished` or `action.record.status` confirms completion

---
Generated by [Dewey 0.3.6](https://github.com/arach/dewey) | Last updated: 2026-08-15
