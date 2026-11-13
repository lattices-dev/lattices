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

### 4.2 Local Moondream Adapter

- [ ] Add a local Moondream adapter.
- [ ] Read the Moondream install path from environment or config, not from the native app.
- [ ] Save the exact request payload sent to the model as an artifact.
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
- [ ] add local Moondream adapter
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
