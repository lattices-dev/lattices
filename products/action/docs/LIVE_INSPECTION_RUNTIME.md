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

- direct model client logic
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

- local Moondream adapter
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
