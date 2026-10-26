<p align="center">
  <img src="https://raw.githubusercontent.com/lattices-dev/lattices/main/assets/hero.svg" width="720" alt="Lattices: workspaces for agents (and you)" />
</p>

<h1 align="center">Lattices</h1>

<p align="center"><strong>Find any project's windows. Put them in place, for you or your agent.</strong><br />
A window manager that knows about projects.</p>

<p align="center">
  <a href="#get-started"><strong>Get started</strong></a> ·
  <a href="#give-your-agents-workspace-access">For agents</a> ·
  <a href="https://lattices.dev/docs/quickstart">Documentation</a> ·
  <a href="https://lattices.dev">Website</a>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@lattices/lattices"><img alt="npm version" src="https://img.shields.io/npm/v/@lattices/lattices.svg" /></a>
  <a href="https://github.com/lattices-dev/lattices/blob/main/LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-informational.svg" /></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-black.svg" />
</p>

Lattices is a native Mac app that makes your desktop part of your workflow. Put your editor and browser side by side, find a terminal by the project running inside it, and switch between groups of windows as your work changes.

Use hotkeys, gestures, or the command bar. Your agents can inspect and arrange the same workspace, read app controls, click, type, and verify results through `lats`, MCP, or a local API.

- **Arrange the work in front of you.** Tile windows into halves, thirds, or grids. Group a project's windows into a [workspace layer](https://lattices.dev/docs/layers).
- **Find the context you need.** Search window titles, apps, terminal directories, and screen text. Bring the matching window into place with one command.
- **Come back to a running session.** Define your terminal panes once, then reattach with `lats start` after closing the terminal. Persistent sessions use tmux.

## Get started

**Requires macOS 26 or later.** The Mac app works without Bun or tmux.

1. [Download Lattices for Mac](https://github.com/lattices-dev/lattices/releases/latest), open the DMG, and drag Lattices to Applications.
2. Open Lattices and grant Accessibility access when prompted.
3. Press **Control+Option+Left**. Your frontmost window moves to the left half of the screen. Press **Control+Option+Space** to open the command bar.

For screen-text search, also grant Screen Recording permission and enable **Search & OCR** in Settings. OCR is off by default.

<p align="center">
  <img src="https://raw.githubusercontent.com/lattices-dev/lattices/main/assets/readme-demo.gif" width="100%" alt="Lattices arranging windows with gesture previews and shared workspace state" />
</p>

### Install the CLI

Install [Bun](https://bun.sh) first: the CLI uses it at runtime, even when you install with npm. Then:

```sh
npm install -g @lattices/lattices
lats app
lats
```

The package includes the Mac app. `lats app` launches it; bare `lats` shows workspace status. Both `lats` and `lattices` run the same CLI. The package is macOS-only.

The [setup guide](https://lattices.dev/docs/quickstart) covers login startup, permissions, and other installation options.

### Linux (Hyprland and Omarchy)

Install the Linux app, CLI, host and tray from a terminal inside Hyprland:

```sh
curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
```

On Arch/Omarchy, the installer installs missing dependencies, enables the user
services, verifies host health and opens the app. From a checkout, use
`bash install.sh`. Add `--gestures` for Forward-button gestures, or
`--wheel-gestures` to also reserve wheel-click. `--no-start` prepares the files
without starting services.

See [Install on Linux](docs/install-linux.md) for requirements, updates and
recovery. The published npm app package remains macOS-only.

## Find a project window and bring it beside you

With a terminal open in your project, replace `tideline` with its directory name:

```sh
lats search tideline --deep
lats place tideline right
```

Deep search includes live terminal inspection. `place` searches the same sources, focuses the **top match**, and tiles that window on the right. Inspect the search results first if several windows match.

An agent can run those same commands. It can find the terminal by project context instead of needing you to copy a window ID.

## Give your agents workspace access

With the app running and the CLI installed, add the family skills to your agent:

```sh
npx skills add lattices-dev/lattices --all --global --yes
```

Inspect the live API or call it directly:

```sh
lats daemon status
lats call api.schema
lats call windows.search '{"query":"api"}'
```

For a Bun script, install the package in your project (`bun add @lattices/lattices`):

```js
import { daemonCall, isDaemonRunning } from '@lattices/lattices'

if (!(await isDaemonRunning())) {
  throw new Error('Start Lattices with: lats app')
}

const windows = await daemonCall('windows.search', { query: 'api' })
console.log(windows)
```

Lattices 0.15.1 hosts the API at `~/.lattices/run/lattices.sock` and requires a local token before the WebSocket upgrade. Install the matching 0.15.1 CLI and app together. Versions before 0.15.1 use `ws://127.0.0.1:9399`; clients that connect directly to that port must migrate. Read the [API reference](https://lattices.dev/lattices/docs/api) and [agent guide](https://lattices.dev/lattices/docs/agents) for the transport that matches your build.

You can also expose the CLI as a stdio MCP server:

```sh
lats mcp
lats mcp --list
lats mcp --print-config claude       # also: codex or kimi
```

Use the installed `lattices` binary with arguments `["mcp"]` in agent configuration. The `browser` and `hosts` toolsets can be selected with `--toolsets`. See the [MCP guide](https://lattices.dev/docs/mcp).

## Let agents use your Mac

Computer use starts with context. Lattices lets an agent find a window, inspect its Accessibility tree, capture the screen, and act on a specific control. Click, type, scroll, and keyboard actions can be staged before execution; captures and verification help the agent check what happened.

With a Finder window open, inspect it without clicking or typing:

```sh
lats call computer.windowState '{"app":"Finder","maxDepth":4}'
```

Use the returned snapshot and element IDs for subsequent actions. The [computer-use API](https://lattices.dev/docs/api) also exposes a typed SDK at `@lattices/lattices/cua`. Accessibility permission is required; screenshots need Screen Recording permission.

For private browser layers and dedicated computer-use sessions, add [Action](https://lattices.dev/action):

```sh
lats action install
lats action launch
lats action status
```

Action is a separate native app. The [Action skill](https://github.com/lattices-dev/lattices/blob/main/skills/action/SKILL.md) and [agent guide](https://lattices.dev/docs/agents) cover its observation, interaction, and recording workflow.

## Keep a terminal session alive

Install tmux (`brew install tmux`), then:

```sh
cd ~/your-project
lats init
lats start
```

`lats init` creates `.lattices.json`. `lats start` creates or reattaches the project's tmux session; `lats tmux` is an alias. Close your terminal and run `lats start` again to return to the session.

```json
{
  "ensure": true,
  "panes": [
    { "name": "shell", "size": 60 },
    { "name": "server", "cmd": "bun dev" }
  ]
}
```

## Keyboard

These are the default bindings. Hyper means Control+Option+Shift+Command.

| Shortcut | Action |
| --- | --- |
| **Control+Left / Right** | Switch Spaces |
| **Control+Option+arrows** | Tile the frontmost window to a half |
| **Control+Option+Return** | Maximize |
| **Control+Option+U / I / J / K** | Tile to a quarter |
| **Hold Control+Option, press 1–9** | Place the window in that cell of the 3×3 matrix; 5 maximizes |
| **Control+Option+Shift+1 / 2 / 3** | Tile thirds |
| **Control+Option+Space** | Open the command bar |
| **Command+Option+1–9** | Aim a workspace layer; release to switch. Slot 5 shows the current layer |
| **Control+Option+Shift+arrows** | Move across the layer pad |
| **Command+Option+T** | Add the front window to the active layer |
| **Command+Option+0** | Classic: every window back |
| **Hyper+1** | Workspace home |
| **Hyper+L** | Overview |

Voice Command is rebindable and has no default shortcut. Hold Option while the command bar has keyboard focus to speak. See [App and shortcuts](https://lattices.dev/docs/app) for the remaining bindings.

## Existing installations

`@arach/lattices` and `@lattices/cli` remain supported compatibility packages. They receive the same CLI, exports, and bundled app as `@lattices/lattices`. Update using the package name you already installed. From version 0.14.1, `lats app upgrade` also preserves that package name.

The repository moved from `arach/lattices` to `lattices-dev/lattices`. Existing Git remotes and release links redirect to the new location. Your configuration, sessions, and app identity stay the same. See the [migration guide](https://lattices.dev/docs/namespace-migration).

## The Lattices family

Each product has its own app, README, and source directory. Start here:

| Product | What it adds |
| --- | --- |
| **[Lattices](https://lattices.dev)** | A programmable workspace: windows, projects, screen search, and terminals. |
| **[Action](https://github.com/lattices-dev/lattices/blob/main/products/action/README.md)** | Computer use for agents: observe apps, operate browser surfaces, and record what happened. |
| **[Canvas](https://github.com/lattices-dev/lattices/blob/main/products/blink/README.md)** | Spatial notes: editable notes that live in floating windows on your desktop. |
| **[Speech / Voice](https://github.com/lattices-dev/lattices/blob/main/products/voice/README.md)** | Spoken agent output with queued playback and a readalong HUD. |

Action, Canvas, and Voice have independent installation and runtime lifecycles. Their source lives together under [`products/`](https://github.com/lattices-dev/lattices/tree/main/products). [Explore the family](https://lattices.dev/family).

## Other machines

The Linux host has a separate source installation; it is not included in the macOS npm package. See the [Linux host guide](https://github.com/lattices-dev/lattices/blob/main/packages/host-linux/README.md), [Linux desktop app](https://github.com/lattices-dev/lattices/blob/main/apps/linux/README.md), and [visit guide](https://lattices.dev/docs/visit) for pairing and cross-machine control.

<details>
<summary>Linux host and Machines setup from source</summary>

These instructions target the repository source, which can be ahead of the npm release. Clone the repository first and run the Linux commands from its root. The host requires a Hyprland session; it is a separate installation from the Mac app.

## Linux host

The [Linux host](https://github.com/lattices-dev/lattices/blob/main/packages/host-linux/README.md) exposes a Hyprland desktop through the same API envelope (`{id, method, params}`). Version 0.15.1 keeps the host and visit bridge on local Unix sockets. Remote access requires the separate gateway: run `lats gateway start --tailnet` on the Linux host, then approve paired clients and their grants. The gateway uses port 9399 for both RPC and visit traffic. Older builds listen directly on port 9399 and use port 5287 for visits; use matching host and client builds.

Install Bun and Tailscale, then run these commands inside a Hyprland session. Visiting also requires Quickshell for the cursor overlay and `wtype` for keyboard input.

```sh
bun install --cwd packages/host-linux --ignore-scripts --omit optional
bun packages/host-linux/src/main.ts
```

For tray controls and systemd user units:

```sh
bun packages/host-linux/scripts/install-tray.ts
systemctl --user enable --now lattices-host
```

The tray installer enables the tray. The second command also enables the host at login. Keep the checkout in place because the units use its paths.

From a Mac with `lats` installed:

```sh
lats hosts add archie archie
lats --host archie pair              # approve the code on archie
lats --host archie call host.describe
lats --host archie call windows.place '{"app":"firefox","placement":"left"}'
```

Pairing requests the `act` scope by default. Use `--read-only` or `--drive` to request a different scope. Wider access requires a new approval. `lats hosts` lists configured hosts; `lats hosts --discover` probes your online tailnet devices. See the [host README](https://github.com/lattices-dev/lattices/blob/main/packages/host-linux/README.md) for capabilities and pairing controls.

## Machines

Open **Workspace → Machines** to arrange this Mac's displays and paired machines. Drag a machine against a display to choose the edge where your pointer crosses. Moving a local display creates a draft: **Apply** starts a 15-second trial, **Keep** accepts it, and **Revert** restores the previous arrangement. Opening Machines does not arm a visit.

A visit lends this Mac's mouse and keyboard to a paired machine. Pair the visit bridge, choose an edge, then arm crossing:

```sh
lats visit pair archie               # source build uses gateway archie:9399; approve there
lats visit side archie left
lats visit on
lats visit archie                    # enter immediately
```

The host draws a labelled visitor cursor while the Mac pointer stays parked. Return through the entry edge, press **Control+Option+Command+Home**, or run `lats visit end` to finish. `lats home` also returns the pointer to the center of the Mac's main display. A disconnected or unresponsive visit ends automatically.

```sh
lats visit off                      # disarm edge crossing
lats visit status
lats visit screens
lats elsewhere 2 archie             # this display shows the paired machine
lats here 2
lats visit host on                  # explicitly allow visits to this Mac
lats visit host off
lats machines                      # local machine, configured hosts, and visit pairings
lats @archie call windows.list      # API call on a configured host
lats bring dell                     # bring other displays' windows to this display
lats bring --undo
lats main dell                      # try a different main display for 15 seconds
lats main dell --keep
```

Visit pairing and API host configuration are separate. `lats @<host>` forwards daemon commands to a configured address; it does not make a Mac's loopback daemon remotely reachable. Read the [visit guide](https://lattices.dev/docs/visit) for placement, receiving visits, and arrangement recovery.

</details>

## Build and contribute

<details>
<summary>Source setup and repository map</summary>


```sh
git clone https://github.com/lattices-dev/lattices.git
cd lattices
bun install
bun link
bun run check
bun run test
```

The native app uses Swift 6.2 / Xcode 26+. See [AGENTS.md](https://github.com/lattices-dev/lattices/blob/main/AGENTS.md) for component boundaries and build instructions.

| Source | Purpose |
| --- | --- |
| `apps/mac` | SwiftUI/AppKit app and local daemon |
| `bin` | CLI, app helper, API client, and MCP server |
| `packages/host-linux` | Hyprland host, visit bridge, and tray |
| `swift` | LatticesTerminalKit and DeckKit |
| `products` | Companion products |
| `skills` | Agent skills |
| `apps/site` | Website and documentation |

</details>

## Documentation

[Quickstart](https://lattices.dev/docs/quickstart) · [App and shortcuts](https://lattices.dev/docs/app) · [Configuration](https://lattices.dev/docs/config) · [Layers](https://lattices.dev/docs/layers) · [Screen search](https://lattices.dev/docs/ocr) · [API](https://lattices.dev/docs/api) · [Visits](https://lattices.dev/docs/visit) · [Linux host](https://github.com/lattices-dev/lattices/blob/main/packages/host-linux/README.md)

## License

[MIT](https://github.com/lattices-dev/lattices/blob/main/LICENSE)
