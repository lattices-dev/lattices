# @lattices/action

Computer use on macOS through one contract: **targets → observe → act**.
Use it as a CLI, a stdio MCP server, or a TypeScript library. Choose one backend
for each call:

| Backend | Uses | Requires |
| --- | --- | --- |
| `codex-cua` | Codex Computer Use (`cua_repl`) | ChatGPT desktop app's Computer Use plugin |
| `trycua-cua` | trycua's Cua Driver (`cua-driver mcp`) | CuaDriver.app and its CLI |
| `action-cua` | Action's native host | Action.app |

You name the backend. There is no fallback between backends. The first two
backends work without Lattices or Action.app. This package does not require
Action's drive infrastructure.

## Install

Requires macOS and Bun, or Node.js 20 or later.

```sh
bun add -g @lattices/action
action --help
```

Or run it with Bun:

```sh
bunx @lattices/action --help
bunx @lattices/action status --json
```

Install and configure the backend you intend to use. `status` reports readiness
and each backend's declared action tiers, plus any `needs` and their setup
commands. A status request can start a backend's driver process.

## Permissions

Run setup for the backend you intend to use:

```sh
action setup trycua-cua
action setup action-cua
action setup codex-cua
# Or check and set up every backend in sequence:
action setup all
```

| Backend | App that holds access | Setup behavior |
| --- | --- | --- |
| `trycua-cua` | CuaDriver.app (`com.trycua.driver`): Accessibility and Screen Recording | Requests access through `cua-driver permissions grant`, opens the missing permission panes, reveals `/Applications/CuaDriver.app` for adding it, and verifies capture after the grants change. |
| `action-cua` | The selected Action.app (`dev.lattices.Action`): Accessibility and Screen Recording | Runs the app's permission request, opens missing permission panes, and polls its native status. Status reports the actual bundle identity/path when available. |
| `codex-cua` | Computer Use's host/helper in the ChatGPT desktop app: macOS permissions are managed by the plugin's onboarding; target-app approvals come from this adapter's `apps` allow list | Verifies the plugin, `cua_repl`, and configuration; reports installation/configuration instructions. This adapter cannot request or grant the plugin's macOS permissions. |

Setup prints progress and click instructions as it runs, and waits up to about
two minutes per backend. In System Settings → Privacy & Security, enable the
named app under **Accessibility** and **Screen Recording** (also called
**Screen & System Audio Recording**). If CuaDriver is absent, drag the app from
the Finder window setup opens into the permission list, then enable it. Follow
any macOS relaunch prompt. The user must approve each grant; setup never edits
the permissions database. A timeout returns `ready: false`, remaining `needs`,
and `waiting-on-user` steps. Run the setup command again after making the change.

Interactive `targets`, `observe`, `press`, `set`, and `act` offer
`Run setup now? [Y/n]` when permissions are the only missing prerequisite.
Non-TTY commands print the fix and exit nonzero without prompting or opening
settings. Explicit `setup` authorizes the permission UI, including when run with
`--json`; progress goes to stderr and stdout remains JSON. Library callers can
use `interactive: false` to verify and report without requesting access.

### Asking through Action

An agent that is not at a terminal can ask in an Action.app panel instead:

```sh
action ask trycua-cua
```

MCP clients call `cua_ask { backend }`. Library callers use `askForBackend(host, id)`,
or `askOperator(request, { check })` for any other request.

- **The check runs first.** If the backend is already ready, no panel opens.
- **One panel per request.** Asks share a key (for example,
  `tcc:com.trycua.driver:accessibility+screen-recording`). A second agent with the
  same key waits for the first agent's answer. It does not open another panel.
- **The panel does not take focus.** It appears at the top right of the main
  display and does not activate Action. Its buttons open the Settings pane, show
  the app in Finder, or ask macOS again. Ask macOS again re-runs the backend's setup.
- **The backend's status check decides.** The panel ticks each permission as the
  grant lands, then closes. The operator can choose Not now.
- **Outcomes:** `satisfied`, `declined`, `cancelled` or `expired` (default timeout:
  five minutes). An Action.app without the panel returns `unsupported`; use the
  `needs` from `status` instead. Its capabilities do not list `operatorAsk`.
- **Audit log:** every ask is appended to
  `~/Library/Application Support/Action/asks/log.jsonl`.

## Tiers

The host checks each action's declared tier before sending it to the backend.
The default allow list is `["observe", "semantic"]`.

| Tier | Meaning |
| --- | --- |
| `observe` | Read targets, accessibility state, or screenshots. |
| `semantic` | Perform accessibility (AX) actions without moving the pointer or taking keyboard input. |
| `target-focus` | Change focus within the target app, such as focusing one of its controls. |
| `attention` | Synthesize keys or pointer events that can take over the user's input. |

The same action can have different tiers in different backends. For example,
`setValue` is `semantic` in `trycua-cua` and conservatively `attention` in
`codex-cua`, whose successful set-value path has not been verified. Check
`status` for the installed adapters' declarations.

Use `--allow attention` on a CLI action to add attention to the default tiers.
MCP callers pass `allowTiers` explicitly; that list replaces the default, with
`observe` always included. Tiers are checked per action, not granted by naming a
backend.

## Backend configuration

The default file is:

```text
~/Library/Application Support/Action/backends.json
```

It holds one options object per backend ID. For example:

```json
{
  "codex-cua": {
    "apps": ["com.google.Chrome", "com.apple.calculator"]
  },
  "trycua-cua": {
    "command": "cua-driver",
    "args": ["mcp"],
    "maxElements": 800,
    "telemetry": false
  },
  "action-cua": {}
}
```

`ACTION_BACKENDS_CONFIG` selects a different file. The CLI's `--config <path>`
sets that variable for its process. `ACTION_SUPPORT_DIRECTORY` changes the
support directory, including the default config and screenshot locations.
An explicit config path takes precedence over the support directory.

Backends read their options when first used. Restart the MCP server after
changing its config. Screenshots are saved under
`<support directory>/runtime/backends/shots/<backend>/`; replies contain the file
path.

### codex-cua

Install the Computer Use plugin in the ChatGPT desktop app. This adapter reads
`mcpServers.cua_repl` from `.mcp.json` in the newest directory, by modification
time, under:

```text
~/.codex/plugins/cache/openai-bundled/unified-computer-use/*
```

The plugin manifest supplies the command, arguments, and environment. The adapter
sets `CUA_REPL_ENABLED_SURFACES=computer`; it does not use browser surfaces.

Set `apps` to the bundle IDs of apps you want it to use. An empty list reports
not ready. Targets include only running apps on the list. The adapter approves
Computer Use's matching per-app prompts for the current session. It declines
other prompts and does not persist an “always allow” approval.

`apps` is this adapter's configuration option. There is no separate command or
plugin-path option. A missing plugin manifest or `cua_repl` entry reports an
unavailable backend.

### trycua-cua

Install Cua Driver using [trycua's installation instructions](https://cua.ai/docs/cua-driver/quickstart).
The macOS commands are:

```sh
/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
action setup trycua-cua
```

Setup requests CuaDriver's permissions and guides you through any remaining
System Settings steps; see [Permissions](#permissions).

Without a configured `command`, the adapter searches in this order:

1. `cua-driver` on `PATH`.
2. `$HOME/.local/bin/cua-driver`.
3. `/Applications/CuaDriver.app/Contents/MacOS/cua-driver`.

A configured `command` replaces that search. It can be a command on `PATH` or a
path; `~/` is expanded. Other options are `args` (default `["mcp"]`), `cwd`,
`maxElements` (default `800`), and `telemetry` (default `false`).

Keep the default `mcp` arguments. On macOS they proxy to CuaDriver.app, which
owns the permissions. Adding `--direct` changes permission attribution to the
calling process.

The adapter sets `CUA_DRIVER_RS_TELEMETRY_ENABLED=false` on its child process.
Setting `telemetry: true` leaves the driver's telemetry defaults unchanged.
It uses the driver's native app/window tools, not its `browser_*` tools.

A semantic press requires the observed element to advertise `AXPress`. The
adapter refuses elements that could make the driver fall back to a pixel click.

### action-cua

Install [Action.app](https://lattices.dev/action). This backend uses its native
host. Set `ACTION_NATIVE_HOST` to an explicit host executable, or `ACTION_APP`
to the Action.app bundle when it is installed outside the default location.
Run `action setup action-cua` to request its macOS permissions.

The config options `host` and `app` select the same paths. The adapter also
checks `/Applications/Action.app` and `~/Applications/Action.app`. An optional
`apps` list restricts targets to those bundle IDs. Status checks the launcher
and the native app's Accessibility and Screen Recording status, and includes
the app version when available. When not ready, its reason also reports path
action support. Permission readiness does not prove that a particular semantic
action works.

The adapter checks native `capabilities` once per backend instance. When all
three path commands are available, observations retain each element's AX path
and root. `press`, `setValue`, and `secondary` act on that exact path with the
observed role, first nonempty label candidate (title, description, value, then
identifier), and frame when present. Duplicate labels and truncated snapshots
do not prevent path actions. Unlabelled elements use role and any observed frame.

The host checks those expectations before acting. A `path-mismatch:` returns a
`stale-ref` refusal with a fresh observation; no action was performed. Native
action failures and mismatched success replies report uncertain delivery.
The mechanisms are `ax-path-press`, `ax-path-set-value`, and `ax-path-action`.
Capability checks run the selected app executable directly, without launching
its UI. Restart the backend after updating Action.app to refresh the cache.

Older hosts retain label matching and require a unique best match across the
whole app. A window snapshot, truncation, duplicate labels, or unreported AXHelp
can prevent that proof. Those refusals advise: update Action.app for
path-addressed actions.

When the host reports window-scoped accessibility, each target is one window:
`<generation>:<bundleId>:<pid>:<windowNumber>`. Windows of the same app, and of
separate processes with one bundle ID, are separate targets. Windows on other
Spaces or on an Action agent layer are included. Helper windows smaller than
100 points on a side (slivers, tab-bar strips, badges) are omitted. Observe and
semantic actions address the window by number and run the host without
activating it. Older hosts list one target per app.

Observed nodes carry `frame` in screen points when the host reports one. For
`action-cua`, that is also the coordinate space of `click` and `scroll`. Native
click and scroll points use macOS screen coordinates, unlike trycua's
screenshot pixels. Native `type` and `key` use the current global keyboard focus.

A native `click` is a HID event: the clicked app can take focus, and the pointer
moves to the point. The `restore` option controls what happens next:

| `restore` | Effect |
| --- | --- |
| `"auto"` (default) | Restore only when a person is co-driving: hardware input arrived in the last 5 seconds. A clean run, such as a demo, is left alone. |
| `true` | Always return focus to the prior frontmost app and the pointer to its prior position. |
| `false` | Never restore. |

```json
{ "action-cua": { "restore": "auto" } }
```

The host waits up to 300 ms for the clicked app to take focus, then returns it.
It skips the pointer warp when the pointer was already at the point or someone
has moved it since. The act reply's `message` reports the host's result, for
example `3589,1460 restored` or `3589,1460 clean-run`. Hosts that do not report
`restoringInputCommands` receive no restore flag.

## CLI

List readiness, then inspect a backend's targets:

```sh
action status
action status codex-cua --json
action targets codex-cua
action observe codex-cua com.google.Chrome --roles 'AXRadioButton|AXButton'
action observe trycua-cua 'Project notes' --screenshot --json
```

`<target>` is a selector. A window identity, `<bundleId>:<pid>:<windowNumber>`,
selects that window; a window target ID from an earlier run also works, because
its generation prefix is ignored. Positional target IDs are not selectors. An
exact bundle ID match comes next. Otherwise the selector is a case-insensitive
regular expression against app names and window titles. Zero or multiple matches produce an error
with candidates. Add `--first` to choose the first matching target.

Press a Chrome tab whose accessibility label is `Project notes`:

```sh
action press codex-cua com.google.Chrome \
  --label '^Project notes$' --role AXRadioButton
```

Set a text field, or explicitly allow a key event:

```sh
action set trycua-cua 'Project notes' \
  --label '^Search$' --value 'release notes'

action act codex-cua com.google.Chrome \
  '{"kind":"key","combo":"cmd+l"}' --allow attention
```

Labels use case-insensitive regular expressions. `--role` matches an exact AX
role. `--nth N` chooses the Nth matching node, starting at 1. Without `--nth`, a
label must select exactly one node. Labels and roles depend on the app's current
accessibility tree; inspect it before choosing them.

For a JSON action that needs a ref, supply a label selector:

```sh
action act codex-cua com.google.Chrome \
  '{"kind":"press"}' --label '^Project notes$' --role AXRadioButton
```

Every acting command lists targets, observes the selected target, resolves any
ref, and acts in one process. Raw refs from earlier CLI invocations are refused.
Target IDs and refs belong to one host generation and cannot be copied between
processes. Point actions capture a screenshot in the same process before acting;
`trycua-cua` points are pixels in that screenshot.

All commands accept `--json`, `--config <path>`, and `--help`. `--json` returns
machine-readable output; errors return a nonzero exit code. For `mcp`, stdout
always carries the MCP protocol and diagnostics go to stderr.

## MCP clients

The standalone server exposes five tools:

| Tool | Input |
| --- | --- |
| `cua_status` | Optional `backend`. |
| `cua_setup` | `backend`; may show permission dialogs/open System Settings and wait up to about two minutes. |
| `cua_targets` | `backend`. |
| `cua_observe` | `backend`, `targetId`, optional `screenshot`. |
| `cua_act` | `backend`, `targetId`, `observationId`, `action`, optional `allowTiers`. |

Use `cua_status` to inspect `needs`, then `cua_setup` for the selected backend.
Setup returns `ready`, `steps`, and remaining `needs`; incomplete setup is an
MCP error with that same structured result. Call `cua_targets`, then
`cua_observe`, then `cua_act` in the same server process.
Use refs from the target's newest observation. Observe again to check the
result. The server disposes its backends when stdin closes or it receives
SIGINT or SIGTERM.

Claude Code:

```sh
claude mcp add action -- npx -y @lattices/action mcp
```

Codex, in `~/.codex/config.toml` (see the [MCP configuration reference](https://learn.chatgpt.com/docs/extend/mcp#configure-with-configtoml)):

```toml
[mcp_servers.action]
command = "npx"
args = ["-y", "@lattices/action", "mcp"]
```

For clients with a JSON `mcpServers` configuration:

```json
{
  "mcpServers": {
    "action": {
      "command": "npx",
      "args": ["-y", "@lattices/action", "mcp"]
    }
  }
}
```

After a global install, use `command: "action"` and `args: ["mcp"]`.
For a custom config file, append `"--config", "/absolute/path/backends.json"`
to the arguments. No Lattices daemon or drive lease is required.

## Library

Create one `BackendHost` for the full sequence and dispose it when finished.
This example presses Calculator's `7` button through `codex-cua`. Calculator
must be running and its bundle ID must be in `apps`.

```ts
import { BackendHost, defaultAllowTiers } from "@lattices/action";

const host = new BackendHost();
const backend = "codex-cua";

try {
  const targets = await host.targets(backend);
  const matches = targets.filter(t => t.bundleId === "com.apple.calculator");
  if (matches.length !== 1) throw new Error("Expected one Calculator target.");
  const target = matches[0]!;
  const observation = await host.observe(backend, target.targetId, false);
  const buttons = (observation.ax ?? []).filter(
    node => node.role === "AXButton" && node.label === "7"
  );
  if (buttons.length !== 1) throw new Error("Expected one button labelled 7.");

  const result = await host.act(
    backend,
    target.targetId,
    { kind: "press", ref: buttons[0]!.ref },
    { observationId: observation.observationId, allowTiers: [...defaultAllowTiers] }
  );
  console.log(result);
  console.log(await host.observe(backend, target.targetId, false));
} finally {
  await host.dispose();
}
```

`BackendHost` also accepts `configPath`, `shotsDir`, and `log` options. Library
calls return backend results and throw errors directly. The MCP tool layer adds
the reply format described below.

`await host.setup(backend, { timeoutMs: 120_000, signal, onSetupStep },
{ interactive: true })` requests setup with cancellation and live step updates.
`interactive: false` checks and reports without showing permission UI. Backends
without a setup method return their availability with a check step.

## Replies and delivery

MCP replies contain the same JSON payload in `structuredContent` and a text
content item. An act success includes `result.delivery`:

```json
{ "status": "delivered_unverified" }
```

Delivery means the backend dispatched the action. It does not prove the intended
UI change. Read the returned observation, when present, or observe again.
Results also report `tierDeclared`, `tierUsed`, and the delivery `mechanism`.
If a backend reports a tier outside the allow list after dispatch, the reply
includes `tierExceeded: true`; the host cannot undo that delivery.

Errors set MCP `isError: true`. Their payload includes `code`, `message`, and
`delivery: { "status": "not_delivered" }` for a `BackendRefusal`. Other errors
use code `backend-error` and `delivery: { "status": "delivery_uncertain" }`: the action could have
arrived, so inspect state before retrying. A refusal can also include a fresh
`observation`, particularly after a stale ref.

| Refusal code | Meaning and recovery |
| --- | --- |
| `unsupported` | Unknown backend or unsupported action. Choose a supported backend/action explicitly. |
| `stale-ref` | The ref or observation is no longer current. Use the supplied fresh observation, or observe again. |
| `unknown-target` | The target is gone or belongs to another process generation. List targets again. |
| `invalid-action` | Arguments or element capabilities do not permit this action. Correct the action or select another element. |
| `unavailable` | The backend, permissions, or required runtime is unavailable. Read the message and check backend setup. |
| `tier-not-allowed` | The action's declared tier is outside `allowTiers`. Nothing was sent. Allow that tier only when intended. |

## Relationship to Action and Lattices

This is the computer-use package shared by the full Action MCP. The full Action
MCP adds drive leases, a HUD, and a cursor. Lattices is the separate workspace
manager. Neither Lattices nor Action's drive infrastructure is needed for this
standalone CLI, MCP server, or library.
