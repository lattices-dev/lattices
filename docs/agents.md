---
title: Agent Guide
description: Canonical contracts for agents using docs URLs, CLI, voice, and the daemon API
order: 6
---

Lattices exposes the same execution model through these interfaces:

- **Docs URLs** for discovery and citation
- **CLI** for shell-based agents
- **Daemon API** for typed programmatic control
- **Voice / hands-off / HUD** as clients of the same execution layer

The rule is simple: agents should learn the **canonical action model**
first, then choose the transport that fits the environment.

## First check

Run these read-only commands before any mutation. They do not move windows.

```bash
lats call api.schema        # every daemon method and its parameters
lats call desktop.snapshot  # what is on screen now, with window ids
```

Expect a method list, then a snapshot of the current space. If either call
fails, the usual cause is that the menu bar app, which hosts the daemon, is not
running. Ask the user to start it with `lats app`. Then resolve a target with `windows.resolve` or `dryRun` before you
place a window. See [Discoverability](#discoverability).

## Install the skills

`lattices-dev/lattices` is the [skills.sh](https://skills.sh) catalog for the product
family. Skills live under [`skills/`](https://github.com/lattices-dev/lattices/tree/main/skills).

| Skill | Product |
| --- | --- |
| `lattices` | Workspace control, tiling, sessions, screen text |
| `action` | Native observe / resolve / act / record |
| `voice` | The `voice` domain: spoken commands, voice intents, and speech output through the Voice app |
| `blink` | Spatial notes through the `blink` CLI |

```bash
npx skills add lattices-dev/lattices --list
npx skills add lattices-dev/lattices --all --global --yes
npx skills add lattices-dev/lattices --skill lattices --global --yes
npx skills add lattices-dev/lattices --skill action --global --yes
npx skills add lattices-dev/lattices --skill voice --global --yes
npx skills add lattices-dev/lattices --skill blink --global --yes
```

The `browser_*` tools come from `lats mcp`, not from a plugin. The
`action-browser@lattices` plugin carries only the skill text. See
[MCP](/lattices/docs/mcp).

Each product owns its own work. [Concepts](/lattices/docs/concepts#where-commands-go)
lists every `lats` command, the process that receives it, and the product
that does the work. Product docs: [Action](/action/docs/overview),
[Canvas](/canvas/docs/overview), [Voice](/voice/docs/overview).

To install the Action product itself, run `lattices action install`. It
downloads the latest signed `Action.app` release to `/Applications`.
`lattices action status` reports install, runtime, and agent state;
`lattices action call <method>` talks to the Action agent without a monorepo
checkout. Action 0.4.0 and Lattices 0.15.1 use authenticated private IPC;
earlier releases use the local agent port. Let the matching CLI discover the endpoint.
See [Processes and ports](/lattices/docs/concepts#processes-and-ports).

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
and [layer reference](/action/docs/agent-layer)
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
2. **Read-only workspace map and UI hygiene**: [/lattices/docs/workspace-map](/lattices/docs/workspace-map)
3. **Daemon reference**: [/lattices/docs/api](/lattices/docs/api)
4. **Agent guide**: [/lattices/docs/agents](/lattices/docs/agents)
5. **Voice model**: [/lattices/docs/voice](/lattices/docs/voice)
6. **Concepts / config**: [/lattices/docs/concepts](/lattices/docs/concepts), [/lattices/docs/config](/lattices/docs/config)

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
is exact tmux pane text, not OCR.

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
context bundle without scraping HTML. Every docs page also has a
**Use with an agent** control that copies the page or its product's docs.

Prefer the product-scoped files. They hold only that product's current
guides. `<product>` is `lattices`, `action`, `blink`, or `speech`.

| Need | URL |
|------|-----|
| One product's index and first check | `/<product>/docs/llms.txt` |
| One product's current docs, full text | `/<product>/docs/llms-full.txt` |
| One product's docs as JSON | `/<product>/docs/agent-docs.json` |
| One page as readable Markdown | `/<product>/docs/<slug>.md` or `/<product>/docs/<slug>/index.md` |
| Exact Markdown source | `/<product>/docs/markdown/<slug>.md` |
| Public product instructions | `/<product>/docs/AGENTS.md` |

HTML pages advertise their Markdown representation with `rel="alternate"`
and the relevant product index with `rel="describedby"`. The Markdown page
links resolve to canonical web pages; source mirrors preserve the original
bytes. Product indexes follow the [llms.txt proposal](https://llmstxt.org/).
`llms-full.txt` is a complete-context convenience file, not a separate standard.

Pages named `agents` use `/agents/index.md` so their Markdown does not collide
with public `AGENTS.md` instructions on case-insensitive filesystems. Follow
the page's advertised alternate URL when retrieving its content.

The public `AGENTS.md` files contain product-use instructions. Repository
maintainer instructions and local workspace paths are not copied into them.
Archives and prompt templates stay outside the automatic current context.

### Discovery and semantic metadata

| File or markup | Purpose | Status |
| --- | --- | --- |
| `/agent/discovery.json` | Coverage, format status, and retrieval links | Project-specific manifest |
| `/.well-known/agent-skills/index.json` | Downloadable skills with content digests | [Discovery draft](https://github.com/cloudflare/agent-skills-discovery-rfc), v0.2 |
| `/.well-known/ai-catalog.json` | Catalog of documentation and skills | [AI Catalog draft](https://ai-catalog.io/spec/) |
| `/robots.txt`, `/sitemap.xml` | Crawl policy and canonical page inventory | Standard crawler formats |
| JSON-LD in each docs page | Product identity, documentation collection, technical article, breadcrumbs | [Schema.org](https://schema.org/TechArticle) |

The site serves documentation and downloadable skills. It does not host an
A2A agent or a remote MCP server, so it publishes no A2A agent card, MCP server
card, or OAuth service metadata. Local MCP installation remains documented in
the product guides. Draft discovery support does not change product permissions.

GitHub Pages serves explicit static files. This site does not promise Markdown
content negotiation or custom HTTP discovery headers; use the linked `.md`
URLs. JSON-LD and discovery links are present in the initial HTML and are
updated during navigation.

The family-wide files below combine the product documentation.

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
