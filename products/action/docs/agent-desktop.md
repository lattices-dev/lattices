---
title: agent-desktop backend
description: Action's optional Vercel Labs agent-desktop CLI adapter, supported actions, and privacy boundaries
---

Action's `agent-desktop` backend adapts the Vercel Labs CLI to the same
`targets → observe → act` contract as the other computer-use backends. Select
it explicitly for each call. Action does not fall back between backends.

This page describes development source with the fixture verification below.
It does not establish a published package or an installed native-app release.

## Upstream evaluation

The source review used
[`vercel-labs/agent-desktop` at `ab7dfb218cddc1594aa1d87a5bfcd0ac76da2276`](https://github.com/vercel-labs/agent-desktop/tree/ab7dfb218cddc1594aa1d87a5bfcd0ac76da2276).
That checkout declares npm version `1.2.0` and JSON envelope version `2.6`.
The adapter requires envelope `2.6`; it does not verify an installed binary's
commit hash.

Useful upstream features include window and process identities, refs qualified
by snapshot, advertised element actions, and explicit delivery dispositions.
Those features let Action reject stale targets and distinguish a refusal from
an action that might have landed. Upstream implements native accessibility
through macOS AX, Windows UIA, and Linux AT-SPI. Action's package remains macOS
only.

## Verification on November 9, 2026

A live check used Action's `BackendHost`, the external CLI, and a dedicated
fixture window. Observation returned 194 AX nodes. An old observation was
refused as `stale-ref`. Semantic press changed the fixture's click status to
`click-2`, confirmed by a fresh read. `setValue` sent text through stdin, and a
fresh observation confirmed the field's AX value. Focused-window identities
were unchanged before and after the check. Readiness was `true` with
Accessibility granted and optional Screen Recording denied.

A follow-up status check through RexServer reported both permissions granted
after the operator approved Rex. The earlier check used an SSH launcher
context. These permission reports do not verify screenshot capture.

The upstream fixture check also exposed a limit: `set-value` verified the
element value while the SwiftUI bound text remained empty. AX readback does
not prove application commit. No keyboard workaround or repeated delivery was
used. These results cover this fixture; they do not establish general app
compatibility, screenshot capture, or private-layer acceptance.

All 236 CUA tests passed, including 20 focused adapter tests, 13 setup tests,
and 10 ask-integration tests. The package TypeScript build also passed. The
broader product typecheck retains existing errors in `action-cua.test.ts` and
`ask.test.ts`.

The upstream patch passed 38 Rust tests: 37 permission tests and one batch
preflight regression. Native build, Clippy, formatting, and source checks passed.
The 19-file patch passed a clean-base apply check; applying it reproduced the
verified source bytes exactly.

With existing grants preserved, a live Rex-launched setup returned `ready: true`
and verified both permissions. Ask returned `outcome: "satisfied"` and
`asked: false`. The rebuilt CLI's scoped request through Rex reported
Accessibility and Screen Recording granted, with Automation unknown; final
Action setup returned `ready: true`. These checks cover the already-granted
path. They did not exercise a newly missing permission or display a new native
permission prompt.

## Architecture and configuration

The Action backend launches the external CLI directly and reads JSON replies.
The CLI is operator-installed; Action neither bundles nor installs it. This
path does not require `Action.app`. Action retains its own AppKit lifecycle,
recording probe, drive infrastructure, and private-layer controls. The adapter
does not provide private-layer acceptance or connect a virtual display.

Add an optional executable override to
`~/Library/Application Support/Action/backends.json`:

```json
{
  "agent-desktop": {
    "command": "/absolute/path/to/agent-desktop"
  }
}
```

Without an override, the command is `agent-desktop` on `PATH`.
`ACTION_BACKENDS_CONFIG` selects another config file. Extra `args` are refused;
the adapter controls every argument. There is no adapter app allow list.
Restart the MCP server after changing the configuration.

```sh
action status agent-desktop --json
action targets agent-desktop --json
action observe agent-desktop '<target-id>' --json
```

## Permission setup

Ordinary `status` requires Accessibility. Screen Recording is needed only for
optional screenshots; missing access does not block AX observations or semantic
actions. Explicit setup and ask verify **both** permissions:

```sh
action setup agent-desktop --json
action ask agent-desktop --json
```

Setup requests only Accessibility and Screen Recording, then polls fresh CLI
processes for up to two minutes. It does not request Automation. Ask uses an
Action.app permission panel when access is missing; requests still run in the
original caller. An app with the `operatorAsk` capability is required to show
that panel. Closing or declining the panel cancels pending setup. An
already-complete setup returns without showing a panel.

The standalone `action mcp` server exposes `cua_setup` and `cua_ask`, each with
`{"backend":"agent-desktop"}`. The full Action runtime's `action.backend.*`
tools do not expose setup or ask.

macOS can attribute CLI permissions to the launching host, such as RexServer,
Terminal, or Codex. A separate `agent-desktop` entry is not guaranteed. Approve
the identity shown in macOS settings, then verify status through the same
launcher and execution context used by the backend. A check through another
terminal or SSH can report different permissions.

### Scoped-request compatibility

Managed requests require the local upstream extension in
[agent-desktop-scoped-permissions.patch](https://github.com/arach/lattices/blob/main/products/action/packages/cua/patches/agent-desktop-scoped-permissions.patch).
The patch is accompanied by the upstream
[Apache 2.0 license](https://github.com/arach/lattices/blob/main/products/action/packages/cua/patches/agent-desktop-LICENSE).
The reviewed upstream commit does not include that extension. In a clean
checkout at the commit above, check and apply the downloaded patch, then build:

```sh
git rev-parse HEAD
git apply --check /path/to/agent-desktop-scoped-permissions.patch
git apply /path/to/agent-desktop-scoped-permissions.patch
cargo +1.89.0 build -p agent-desktop
```

Set the backend's `command` to the built executable. Its `permissions` reply
must advertise scoped requests for Accessibility and Screen Recording before
Action sends `permissions --request --only accessibility,screen-recording`.
Without that capability, Action reports update or manual-setup instructions.
It can still verify grants already present.

For manual setup, the selected executable's `permissions --guide` opens System
Settings with instructions. Upstream's unscoped `permissions --request` also
requests Automation for System Events; Action's managed setup does not use it.
This extension and adapter remain development source, not published support.

## Supported subset

Observation reads the selected window's accessibility tree. Screenshots are
optional and address that window explicitly. Targets include window ID, PID,
and process-instance identity. The adapter checks that identity again before
observing or dispatching an action. Incomplete snapshots remain marked as
partial; a missing element in a partial snapshot is not proof of absence.

| Action | Tier | Requirement |
| --- | --- | --- |
| `press` | `semantic` | Latest ref advertises `Click`; dispatches headless `click`. |
| `setValue` | `semantic` | Latest ref advertises `SetValue`. |
| `type` | `attention` | Latest ref advertises `TypeText`; global typing is refused. |
| `key` | `attention` | Selected window is already focused; dispatch includes its exact window ID. |
| `scroll` | `attention` | Latest ref advertises `Scroll`; amount is an integer from 1 through 50. |

Default tiers allow `observe` and `semantic`. Attention actions need explicit
permission, such as CLI `--allow attention`. The adapter never requests headed
mode. Coordinate clicks and secondary actions are unsupported. Upstream has
additional commands that this adapter does not expose.

Refs belong to the latest observation of a target. Every dispatched action
invalidates that observation, including uncertain failures. Observe again
before another action. Only an upstream `not_delivered` disposition becomes a
safe refusal. Unknown delivery requires observation before retrying. Successful
dispatch alone does not prove the application saved the result.

## State and privacy

Each backend instance creates a private temporary directory with mode `0700`
and passes it as `AGENT_DESKTOP_HOME`. Inherited `AGENT_DESKTOP_*` settings are
removed. Normal disposal removes that instance's state; an abrupt process exit
can leave temporary files. Screenshots remain in Action's configured screenshot
directory, by default
`~/Library/Application Support/Action/runtime/backends/shots/agent-desktop/`.

Text for `type` and `setValue` travels through stdin, keeping values out of
process arguments. Native diagnostic text is omitted from adapter errors.
Observations and screenshot artifacts still contain application content.
Upstream secure-field handling is not general secret detection.

The native CLI path does not invoke a model service. The calling agent controls
where returned content goes. Explicit backend observation is independent of
Lattices' background OCR toggle and exclusions. macOS permissions still apply.
Read [Native runtime](native-runtime.md) for Action's app and agent boundaries.
