---
title: Agent Guide
description: Canonical contracts for agents using docs URLs, CLI, voice, and the daemon API
order: 6
---

Lattices exposes the same execution model through four surfaces:

- **Docs URLs** for discovery and citation
- **CLI** for shell-based agents
- **Daemon API** for typed programmatic control
- **Voice / hands-off / HUD** as clients of the same execution layer

The rule is simple: agents should learn the **canonical action model**
first, then choose the transport that fits the environment.

## Install the skills

`lattices-dev/lattices` is the [skills.sh](https://skills.sh) catalog for the product
family. Skills live under [`skills/`](https://github.com/lattices-dev/lattices/tree/main/skills).

| Skill | Product |
| --- | --- |
| `lats` | Workspace control, tiling, sessions, screen text |
| `action` | Native observe / resolve / act / record |
| `speech` | Spoken commands and voice intents |
| `blink` | Spatial notes through the `blink` CLI |

```bash
npx skills add lattices-dev/lattices --list
npx skills add lattices-dev/lattices --all --global --yes
npx skills add lattices-dev/lattices --skill lattices --global --yes
npx skills add lattices-dev/lattices --skill action --global --yes
npx skills add lattices-dev/lattices --skill speech --global --yes
npx skills add lattices-dev/lattices --skill blink --global --yes
```

Action Browser also remains a standalone plugin. Install it with
`action-browser@action` from the Action marketplace.

To install the Action product itself, run `lattices action install` — it
downloads the latest signed `Action.app` release to `/Applications`.
`lattices action status` reports install, runtime, and agent state;
`lattices action call <method>` talks to the Action agent on
ws://127.0.0.1:4319 without a monorepo checkout.

## Action private layers

Action private layers create virtual displays. Lattices workspace layers group
windows and use `layer.activate`; they do not create Action's private surface.
For private browser work, use Action MCP `layer_open { browser: true }`,
`layer_snapshot`, `layer_click/type/js`, and `layer_close`.

First run `lats action capabilities` and query `capabilities` plus `tools/list`
on the active Action MCP connection. Compare source/native fingerprints, check
`safety.privateLayer`, and require host acceptance for desktop preservation.
Stop on quarantine; do not rebuild an installation target or fall back to a
regular browser. A missing block is not proof of isolation. Reconnect MCP after
updates and repeat discovery. Matching a published version does not verify
MCP or native feature parity.

The CLI offers layer lifecycle, snapshot, PiP, and recording. Browser flags,
input, navigation, and JavaScript require MCP. Raw Action WebSocket and the
Lattices daemon do not provide that orchestration. Follow the
[Action skill](https://github.com/lattices-dev/lattices/blob/main/skills/action/SKILL.md)
and [layer reference](https://github.com/lattices-dev/lattices/blob/main/products/action/docs/agent-layer.md)
for leases, operator takeover, cleanup, and acceptance requirements.

## Canonical mutations

These are the preferred action identifiers:

| Action | Purpose | Preferred surface |
|--------|---------|-------------------|
| `windows.place` | Place a window or session using a typed placement spec | `actions.execute` |
| `layers.activate` | Bring up a workspace layer with explicit activation mode | Daemon API |
| `spaces.optimize` | Rebalance a set of windows using an explicit scope and strategy | Daemon API |
| `tabs.stack` | Turn explicit or Hyperspace-selected windows into ephemeral cross-app tabs | Daemon API |
| `tabs.layout` | Expand a live tab stack to grid or collapse it back to tabs | Daemon API |

Compatibility wrappers still exist:

| Legacy method | Canonical equivalent |
|---------------|----------------------|
| `windows.place` | `actions.execute` with `type=windows.place` |
| `window.tile` | `windows.place` |
| `layers.switch` | `layers.activate` |
| `layout.distribute` | `spaces.optimize` with `scope=visible`, `strategy=balanced` |

## Discoverability

Agents should use these paths in order:

1. **API schema**: `lats call api.schema`
2. **Read-only workspace map and UI hygiene**: [/docs/workspace-map](/docs/workspace-map)
3. **Daemon reference**: [/docs/api](/docs/api)
4. **Agent guide**: [/docs/agents](/docs/agents)
5. **Voice model**: [/docs/voice](/docs/voice)
6. **Concepts / config**: [/docs/concepts](/docs/concepts), [/docs/config](/docs/config)

Useful CLI discovery commands:

```bash
lats help
lats call api.schema
lats call desktop.snapshot
lats map
lats call terminals.capture '{"session":"<live-session>","lines":40}'
lats voice intents
```

`desktop.snapshot` is the structured “what is in front of the user?” read.
`lats map` draws that same current-space view as ASCII. `terminals.capture`
is exact tmux pane text — not OCR.

For window actions, resolve before mutating when target identity matters:

```bash
lats call windows.resolve '{"target":{"kind":"session","session":"frontend-a1b2c3"},"placement":"left"}'
lats call actions.execute '{"type":"window.place","target":{"kind":"session","session":"frontend-a1b2c3"},"args":{"placement":"left"},"dryRun":true}'
```

`windows.resolve` and `dryRun` return the resolved `wid`, app/title,
target resolution path, display, and planned frame without moving the
window.

Verified `windows.place` receipts include `undoable: true` when Lattices
captured a concrete window id and previous frame. Agents can restore the
latest undoable placement, or an entire request batch, through:

```bash
lats call history.undo '{}'
lats call history.undo '{"requestId":"req_..."}'
lats call history.undo '{"receiptId":"exec_...","dryRun":true}'
```

Undo checks that the window is still where the original receipt left it
before restoring the previous frame. Pass `force:true` only when the
caller intentionally wants to override a later manual move.

## Agent documentation artifacts

The site build emits agent-first files in addition to rendered pages.
Use these when an agent needs raw markdown, prompt text, or a compact
context bundle without scraping HTML.

| Need | URL |
|------|-----|
| Discovery manifest | `/agent/manifest.json` or `/docs.json` |
| Full docs with markdown bodies | `/agent/docs.json` or `/agent-docs.json` |
| Prompt registry | `/agent/prompts.json` or `/prompts.json` |
| Combined agent context | `/agent/context.md` or `/agent-context.md` |
| Combined raw docs | `/agent/bundles/all.md` or `/docs/all.md` |
| Core onboarding bundle | `/agent/bundles/core.md` |
| Daemon/API bundle | `/agent/bundles/daemon-api.md` |
| Voice and prompts bundle | `/agent/bundles/voice.md` |
| Install bundle | `/agent/bundles/install.md` |
| Raw markdown mirror | `/agent/raw/docs/<slug>.md` or `/docs/markdown/<slug>.md` |

Prompt files are mirrored at `/prompts/<id>.md` and
`/docs/prompts/<id>.md`. Nested docs keep path-safe slugs, for example
`docs/reference/install-agent.md` becomes
`/agent/raw/docs/reference/install-agent.md`.

Local scripts can import the same convenience functions used by the
build:

```js
import {
  collectMarkdownArtifacts,
  getMarkdownDoc,
  getPrompt,
  buildAgentManifest,
  buildPromptRegistry,
  buildContextBundle,
  writeAgentArtifacts,
} from './apps/site/scripts/agent-docs.mjs'
```

Run `bun run docs:agent` to regenerate the static artifacts without
running the full site build.

## Placement contract

At the boundary, placements may be strings for convenience.
Inside the daemon, the canonical contract is typed.

String shorthand:

```json
{ "placement": "top-right" }
{ "placement": "grid:3x2:2,0" }
```

Typed placement objects:

```json
{ "placement": { "kind": "tile", "value": "top-third" } }
{ "placement": { "kind": "grid", "columns": 3, "rows": 2, "column": 2, "row": 0 } }
{ "placement": { "kind": "fractions", "x": 0.5, "y": 0, "w": 0.5, "h": 1 } }
```

This lets voice stay natural while the executor stays explicit.

## Choosing a surface

Use the **daemon API** when you need:

- typed receipts and traces
- explicit targeting by `wid`, `session`, or `app`
- composition across layers, windows, and optimization

Use the **CLI** when you need:

- one-shot shell execution
- quick discovery from inside an agent terminal
- compatibility with environments that already have `lats`

Use **docs URLs** when an agent needs:

- a citeable contract
- a stable page to open in a browser or pass to another agent
- quick onboarding without reading source

## Examples

Node.js:

```js
import { daemonCall } from '@lattices/lattices'

await daemonCall('sessions.launch', { path: '/Users/you/dev/frontend' })
await daemonCall('windows.resolve', {
  target: { kind: 'session', session: 'frontend-a1b2c3' },
  placement: 'left'
})
await daemonCall('actions.execute', {
  type: 'window.place',
  target: { kind: 'session', session: 'frontend-a1b2c3' },
  args: { placement: { kind: 'tile', value: 'left' } }
})
await daemonCall('layers.activate', { name: 'review', mode: 'launch' })
await daemonCall('spaces.optimize', { scope: 'visible', strategy: 'balanced' })
```

CLI:

```bash
lats call api.schema
lats call windows.resolve '{"target":{"kind":"session","session":"frontend-a1b2c3"},"placement":"left"}'
lats call actions.execute '{"type":"window.place","target":{"kind":"frontmost"},"args":{"placement":"left"}}'
lats call windows.place '{"session":"frontend-a1b2c3","placement":"left"}'
lats call layers.activate '{"name":"review","mode":"launch"}'
lats call spaces.optimize '{"scope":"visible","strategy":"balanced"}'
```

## Receipts and traceability

Mutating daemon calls should return structured receipts when possible.
The important fields for agents are:

- resolved target
- resolved placement / scope / mode
- affected window IDs
- computed plan and applied mutations
- verification status
- trace entries explaining why the daemon chose that path

This is what keeps voice, hands-off, and scripted execution scrutable.

## Voice and hands-off

Voice is not a separate execution system. It should compile into the
same canonical actions:

- "put Terminal in the upper third" → `windows.place`
- "bring up review" → `layers.activate`
- "make this nice" → `spaces.optimize`

That keeps the interaction layer flexible while the executor stays
predictable.

## Assistant intelligence boundary

Assistant planning lives in TypeScript where possible:

- `bin/assistant-intelligence.ts` owns the intent catalog, prompt assembly,
  local rule planner, desktop snapshot formatting, and plan normalization.
- `bin/handsoff-worker.ts` and `bin/handsoff-infer.ts` call that module before
  falling back to model inference.
- Swift should remain the macOS execution layer: hotkeys, windows, AX/CG,
  SkyLight, panels, and visual feedback.

Use `lats assistant plan <text> --json` to inspect the TS planner without
launching the app or mutating the desktop.
