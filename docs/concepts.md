---
title: Concepts
description: Product boundaries, private IPC and gateway processes, legacy ports, and command destinations
order: 6
---

This page explains which product owns each capability, which processes run,
and how clients connect. It also covers Lattices sessions, panes, layers and
the agent API.

## Lattices and the product family

The products share a repository, website and skills catalog. Each
product ships its own app and keeps its own lifecycle. Quitting one app does
not stop another.

| Product | What it owns | Runtime | Docs |
|---------|--------------|---------|------|
| **Lattices** | Windows, tiling, spaces, workspace layers, tmux sessions, screen text, voice commands, the `lats` CLI and the `lats mcp` server | macOS menu bar app; on Linux, `lattices-host` plus a Quickshell app | [/lattices/docs/overview](/lattices/docs/overview) |
| **Action** | Native observe, resolve, act and record; private agent layers; Action-owned browsers | `Action.app` and its local agent | [/action/docs/overview](/action/docs/overview) |
| **Canvas** | Spatial notes: each note is a floating panel backed by a Markdown file | `Canvas.app` and the `canvas` CLI | [/canvas/docs/overview](/canvas/docs/overview) |
| **Speech** | Spoken output: synthesis, the playback queue and the playback HUD | `Voice.app` (bundle ID `dev.lattices.Speech`) | [/speech/docs/overview](/speech/docs/overview) |

Canvas 2.3.0 ships `Canvas.app` and the `canvas` CLI. `Blink.app` and `blink`
remain compatibility names. Existing storage, bundle identity and `blink.sock`
remain unchanged. The rename does not implement the older shared-canvas API proposal. See [Canvas installation](/canvas/docs/overview#install-and-launch).

The [product map](/products) shows the same family for people choosing what
to install. The rest of this page describes processes, not products.

### Shared entry points

`lats` and `lats mcp` are Lattices interfaces. Some of their commands reach
another product:

- `lats action ...` installs, launches and calls Action.
- `lats voice say ...` asks the Lattices daemon to forward speech to Voice.app.
- `lats mcp` serves the `browser_*` tools, which are Action Browser code that
  ships inside the `lattices` npm package.

These commands are routing. They do not move ownership into Lattices. The
destination table below names the process that does the work.

## Processes and ports

**Lattices 0.15.1, Action 0.4.0 and Speech 0.3.0 use private IPC for local APIs.** Remote
access uses a separate, opt-in gateway on the verified Tailscale address,
port 9399 by default. Starting a product does not start that gateway.

Install matching app and CLI versions. Earlier releases use the
[legacy ports](#published-release-ports); their TCP clients must be upgraded.

### macOS

<MacRuntimeDiagram />

The default socket directory is `~/.lattices/run`, including Action's Chrome
bridge. Canvas and Action's job service keep their sockets in their own
application-support directories.

| Endpoint | Process | Owner | Replaces in earlier releases |
|---------------------------|---------|-------|--------------------------------|
| `lattices.sock` | `DaemonServer` in the menu bar app | Lattices | Local agent API on 9399 |
| `voice.sock` | Embedded voice input runtime (Vox, through Hudson Voice) | Lattices | Voice runtime on 9398 |
| `companion.sock` | Companion bridge in the menu bar app | Lattices | Companion listener on 5287 and its Bonjour advertisement |
| `action.sock` | Action local agent | Action | Agent API on 4319 |
| `action-chrome.sock` | Chrome extension bridge | Action | Chrome companion HTTP/WebSocket listener on 4321 |
| `speech.sock` | Voice.app RPC server | Speech | Speech API on 9397 |
| `blink.sock` in `CANVAS_HOME` (then `BLINK_HOME`, then the existing default) | Canvas.app | Canvas | Unchanged private socket |
| `runtime/companion.sock` in Action's application support | Durable job service: jobs, artifacts and timeline | Action | Existing Unix socket; no fixed TCP port |
| `gateway.sock` | Separate gateway process, local control | Lattices | New endpoint |
| Tailscale address, TCP 9399 by default | Separate gateway process, remote RPC and companion relay | Lattices gateway | Direct remote connections to product runtimes |

The local APIs use filesystem permissions and authentication as described in
[Private IPC and the gateway](#private-ipc-and-the-gateway).
The embedded voice runtime is available only in builds that include Hudson
Voice. Voice input has no remote gateway route.

The Chrome extension uses native messaging over stdio. Its native host connects
to the bridge through authenticated `action-chrome.sock`. Action's job service
uses its own `runtime/companion.sock`. Lattices' device companion bridge uses
`~/.lattices/run/companion.sock` for paired remote visits. These are three
separate services despite the shared companion name.

Private IPC does not remove every network listener. Action-owned Chrome still
uses an intentional loopback Chrome DevTools Protocol (CDP) port, 9335 for the
default workspace. That browser endpoint is separate from Action's agent API
and from the gateway.

### Linux

<LinuxRuntimeDiagram />

In 0.15.1, `lattices-host` is a Bun process with
`lattices.sock` and `companion.sock` in `~/.lattices/run`. The Quickshell app's
backend and the tray use the local host. Remote requests enter through the
separate gateway. The Linux host has no TCP compatibility listener.

`host.describe` reports the host's platform, capabilities and methods.
Action.app, Canvas.app and Voice.app remain macOS apps. Action's RemoteEngine
can call the Linux host's `computer.*` methods through the gateway. See
[Install on Linux](/lattices/docs/install-linux) and
[Remote engine](/action/docs/remote-engine). The macOS rollout does not establish
Linux or physical iOS runtime verification.

### Published-release ports

This table applies to Lattices 0.14.1, Action 0.3.1 and Speech 0.2.0.
It is retained for upgrade reference. Binding and authorization are separate boundaries.

| Port | Process | Binding and authorization in earlier releases |
|------|---------|-------------------------------------------------|
| 9399 | Lattices `DaemonServer` on macOS | Loopback; core methods have no token check. Speaking verbs require the Voice capability token, which `lats` sends |
| 9398 | Embedded Lattices voice runtime | Wildcard listener; non-loopback peers rejected after accept. Requests require the token in `~/Library/Application Support/Lattices/Voice/hudson-voice-runtime.json` |
| 9397 | Voice.app RPC server (Speech) | Loopback; token from `~/Library/Application Support/Speech/RPC/capability` in `x-lattices-speech-token`; browser origins refused |
| 4319 | Action local agent | Loopback; token required for attention-mode `drive.begin`, `workspace.dragFile` and `workspace.cancelOperation`. Other methods have no token check |
| 4321 | Action Chrome companion bridge | HTTP/WebSocket listener; the Chrome extension connected directly to the bridge |
| 5287 | Lattices companion bridge on macOS | All IPv4 interfaces with Bonjour discovery; human-approved pairing and signed requests |
| 9399 and 5287 | Linux `lattices-host` and companion bridge | Local host calls use loopback; the host also listens on its tailnet address when available. Remote devices must pair |
| none | Blink.app local API | `blink.sock` in the `BLINK_HOME` directory, mode 0600 |

In Lattices 0.15.1, port 9399 belongs to the opt-in gateway by default. In
versions before 0.15.1, it belongs to the host or daemon. Matching the port
number alone does not make clients compatible.

## Private IPC and the gateway

> **Versions:** Lattices 0.15.1, Action 0.4.0 and Speech 0.3.0 use private IPC.
> The [process table](#processes-and-ports) lists the default
> endpoints. Local clients connect directly to each product. Remote clients
> use the gateway and its approved method grants.

**Local services use private Unix sockets.** The main Lattices, Action and
Speech APIs use `~/.lattices/run`; Canvas keeps its socket in its own data directory,
`~/Library/Application Support/Blink` by default. A nonempty `CANVAS_HOME`
overrides that path, followed by a nonempty `BLINK_HOME`.
Socket directories are mode `0700`, and sockets are mode `0600`. Services in `~/.lattices/run`
write a random capability token beside the socket, also mode `0600`.

WebSocket services require the token in `x-lattices-token` during the upgrade.
The companion bridge requires that header on its HTTP requests too. These
services refuse browser `Origin` headers and unexpected `Host` headers. The
macOS core, companion and Speech servers also check the connected peer's user
ID. Action and the Bun services rely on the private directory and token.
Canvas uses a peer-user-ID check and private filesystem permissions without a
token. This is an account boundary, not isolation between programs running as
the same user.

The product clients find their sockets and credentials. For example, `lats`
and `daemonCall()` find the Lattices socket and token. A raw WebSocket client
must read the service's token file, connect to its socket, and send
`Host: localhost` with the token. The token is a local capability: the shared
client sends it over private IPC by default. An explicit TCP target, even a
loopback address that could be an SSH tunnel, receives no local token unless
loopback compatibility is explicitly enabled. For the CLI and Pi client, that
requires `LATTICES_ALLOW_LOOPBACK_TCP=1`. Non-loopback targets never receive
local tokens. Canvas keeps its newline JSON protocol and needs no HTTP headers
or token.

`LATTICES_RUNTIME_DIR` moves the runtime directory for every participating
process. Use it for isolated tests, not for normal operation.

**Loopback TCP is a compatibility switch, not a default.** These macOS
runtimes can open a loopback port when explicitly configured. The Linux host
has no TCP compatibility listener.

| Product | Variable | Port | Token still required |
|---------|----------|------|----------------------|
| Lattices on macOS | `LATTICES_ALLOW_LOOPBACK_TCP=1` | 9399 | Yes |
| Speech | `LATTICES_SPEECH_TCP=1` | 9397 | Yes |
| Action | `ACTION_ALLOW_TCP=1` | 4319 | Yes |

**Each product keeps its own lifecycle.** Launching or quitting Lattices,
Action, Canvas or Voice.app does not start, stop or restart another product, and
it does not start the gateway. The CLI connects to whichever runtimes are
running and reports the others as unavailable.

**Remote RPC and companion access use the gateway, and only on request.**
The gateway is a separate per-user process. Start it explicitly:

```bash
lats gateway start --tailnet   # background, until `lats gateway stop`
lats gateway status
```

It does not install a login item or boot service. It requires Tailscale and
binds only this machine's verified Tailscale address, on port 9399 by default.
There is no LAN, wildcard or unauthenticated fallback. It admits devices owned
by this machine's Tailscale user unless you set `--allow-user` or
`--allow-tag`.

A remote client pairs, and a person on this machine approves it:

```bash
# On the remote machine
lats --host HOST pair --read-only
# Or request exactly these methods instead of the read-only scope:
lats --host HOST pair --grant action:status --grant speech:speech.enqueue

# On this machine: check the fingerprint and grants, then approve
lats gateway clients
lats gateway approve CLIENT_ID
lats gateway revoke CLIENT_ID
```

Every stored grant names one exact `product:method`. `--read-only` requests
the reviewed core Lattices read methods, which exclude screen contents. Add
`--screen` for screenshots, streams, OCR and terminal contents, or `--shell`
for typing and launching commands. Plain `pair` covers read, screen and act;
`--drive` adds desktop input and shell. Clients paired earlier keep their
exact grants. Repeated `--grant` flags request
exactly the listed methods, from any product, instead of a scope. You cannot
combine them with `--read-only` or `--drive`. A request for a new capability
needs another local approval. Re-pairing with the same client key adds approved
grants to the existing set. To reduce access, revoke the client and pair again.
Only methods on the gateway's reviewed list can be granted; the gateway rejects
unknown methods and never lets a remote client choose a socket path or call
local administration. If a product is not running, the gateway reports it as
unavailable. It does not start it.

These stay local and the gateway does not forward them:

- raw computer action events and Canvas event streams;
- Action's connection-owned drive leases and workspace drag/cancel operations;
- Speech's native playback reservation and event streams;
- the embedded voice-input runtime and core `voice.*` forwarding;
- the VNC `capture.live` listener. The gateway exposes no VNC.

Remote visits use the authenticated companion relay through the gateway port.
Companion device trust and gateway client trust are separate stores, and
existing direct-host RPC pairings must pair again with the gateway. Companion
device pairings remain in the companion's own store. The native Machines/Hosts
view reuses the CLI gateway pairing; a companion pairing alone does not unlock
remote host status or screens. Canvas's paired iOS note sync remains a separate
Multipeer Connectivity service.

## Where commands go

This table names the destination in the current versions. Earlier releases
have the same product ownership but use the
[older transports](#published-release-ports).

| You run | Process that receives it | Method family | Process that does the work |
|---------|--------------------------|---------------|----------------------------|
| `lats tile`, `lats place`, `lats search`, `lats layer`, `lats call ...` | Lattices daemon via `lattices.sock` | `windows.*`, `spaces.*`, `layers.*`, ... | Lattices |
| `lats start`, `lats sync` | tmux, directly | n/a | tmux, configured by Lattices |
| `lats computer ...` | Lattices daemon via `lattices.sock` | `computer.*` | Lattices |
| `lats voice listen`, `stopListening`, `simulate`, `intents` | Lattices daemon via `lattices.sock` | `voice.*` | Lattices; transcription uses the embedded runtime via `voice.sock` |
| `lats voice say`, `stop`, `pause`, `resume`, `skip`, `seek`, `list`, `select` | Lattices daemon via `lattices.sock` | `voice.*` | Voice.app via `speech.sock`, as `speech.*` |
| `lats action call <method>` | Action agent via `action.sock` | Action methods | Action |
| `lats action <verb>` (other verbs) | Action CLI from a runtime bundle or checkout | n/a | Action |
| `lats mcp` tools `browser_*` | `lats mcp` stdio process | n/a | Action Browser code in the `lattices` package, using Action-owned Chrome profiles |
| `lats mcp` tools `host_*` | Local Lattices runtime via `lattices.sock`, or the gateway for a configured remote host | daemon protocol | Lattices on the selected host |
| `lats --host <name> ...` | Separate gateway on the verified Tailscale address, port 9399 by default | Signed requests with approved method grants | The selected product runtime via its private socket |
| `canvas ...` (or `blink ...`) | Note files on disk; `canvas desk` also uses `blink.sock` | File operations and newline-delimited JSON | Canvas.app watches the same files |

### Current mismatches

Some interfaces cross or overlap the product boundaries.
Read these before choosing an interface.

1. **`lats computer` is Lattices, not Action.** The `computer.*` methods run in
   the Lattices daemon (see the `computer.*` entries in the
   [API reference](/lattices/docs/api)). Action is the separate computer-use
   product with its own agent on `action.sock`.
2. **Action reaches Linux through Lattices.** Action's `RemoteEngine` drives a
   Linux machine by calling `computer.*` on that machine's `lattices-host`.
   Current versions reach it through the gateway and approved grants.
   The native Action app remains on macOS. See
   [Remote engine](/action/docs/remote-engine).
3. **`lats voice` has two destinations.** Listening verbs stay in Lattices.
   Speaking verbs are a bridge: the daemon renames each call (for example
   `voice.say` becomes `speech.enqueue`) and forwards it to Voice.app through
   `speech.sock`. If Voice.app is not running, the speaking verbs fail. There is no fallback
   inside Lattices. See [Voice](/lattices/docs/voice) and
   [Speech](/speech/docs/overview).

The Hands-Off worker is a separate case. It speaks its replies through the
embedded voice runtime on `voice.sock`. It does not use Voice.app.

## Glossary

| Term | Definition |
|------|------------|
| **Command Bar** | The menu bar app's primary interface (**Control+Option+Space** by default). Search and run actions for apps, windows, workspaces, and settings. |
| **Workspace layer** | A named group of windows that you switch as one unit with **⌘⌥** arrows or `lats layer`. See [Layers](/lattices/docs/layers). Not the same as an Action private layer. |
| **Window Tiling**     | Snap terminal windows to preset screen positions (halves, quarters, thirds, maximize, center). Works from the CLI (`lats tile`) or the command bar. |
| **Agent API** | Lattices RPC methods and events hosted by the menu bar app on macOS or `lattices-host` on Linux. Current versions use authenticated WebSocket over `lattices.sock`; versions before 0.15.1 use TCP 9399. See the [API reference](/lattices/docs/api). |
| **Private IPC** | Local communication over a Unix socket owned by the current user. Product APIs authenticate local clients before accepting requests; the gateway is not involved. |
| **Gateway** | Separate, opt-in process for remote access. It verifies Tailscale identity and signed requests, checks approved product/method grants, and connects to the product through private IPC. |
| **Agent** | Any program that calls the agent API autonomously: an AI coding agent, a shell script, a CI pipeline, or a custom tool. |
| **Session** | A persistent tmux workspace that lives in the background. Survives terminal crashes, disconnects, and closing your laptop. One session per project. Requires tmux. |
| **Pane** | A single terminal view inside a session. A typical setup has two panes side by side: shell on the left, dev server on the right. Requires tmux. |
| **Attach / Detach** | Attaching connects your terminal to an existing session. Detaching disconnects but keeps the session alive. Your shell and dev server keep running. Requires tmux. |
| **Sync / Reconcile**     | `lats sync` brings a running session back in line with its declared config. It recreates missing panes, re-applies layout, restores labels, re-runs commands in idle panes. Requires tmux. |
| **Ensure / Prefill** | Two modes for restoring exited commands on reattach. **Ensure** auto-reruns the command. **Prefill** types it but waits for you to press Enter. Set via `.lattices.json`. Requires tmux. |
| **tmux** | Terminal multiplexer (optional). Provides persistent sessions, pane layouts, and command restoration. Install with `brew install tmux` on macOS if you want session management. |

## How it works

1. You create a `.lattices.json` file in your project root (or run `lats init`)
2. The menu bar app discovers the project and adds it to the command bar
3. You can tile windows, switch layers, search via OCR, and use the agent API
4. With tmux installed, `lats start` also creates persistent terminal sessions:
   - Each pane gets its command (shell, dev server, tests, etc.)
   - The session persists in the background until you kill it
   - You can attach/detach from any terminal at any time
   - If `ensure` is enabled, exited commands auto-restart on reattach

## Core architecture

- The menu bar app is the core on macOS. It provides the command bar,
  window tiling, OCR, project discovery and the agent API. Versions from 0.15.1 expose
  that API through `lattices.sock`; versions before 0.15.1 use TCP 9399. The app
  works with or without tmux.
- The `lats` CLI calls the agent API for windows, layers, search and OCR. It
  runs `tmux` commands directly for session management.
- Local agents and scripts connect to the agent API over WebSocket, using
  private IPC in current versions. Remote access goes through the
  gateway and is limited to approved methods. The API lets agents discover
  projects, tile windows, switch layers, read on-screen text and subscribe to real-time events. See the
  [API reference](/lattices/docs/api).
- The app and the CLI share one session naming convention, so they always
  agree on which session belongs to which project.

### Session naming

A session name is `<basename>-<hash>`, where:

- `basename` is the project directory name (non-alphanumeric chars replaced with `-`)
- `hash` is the first 6 hex chars of the SHA-256 of the full absolute path

This guarantees unique session names even if two projects share the
same directory name (e.g. `~/work/app` and `~/personal/app`).

Both the CLI (Node.js `crypto.createHash`) and the app (Swift
`CryptoKit.SHA256`) produce identical hashes.

### Window discovery via title tags

When lattices creates a tmux session, it sets the tmux option:

```
set-titles-string "[lattices:<session-name>] #{pane_title}"
```

This embeds a `[lattices:name]` tag in the terminal window title. The
menu bar app uses this tag to find windows via three fallback paths:

1. **CGWindowList** (needs Screen Recording permission): fastest,
   reads window names from the window server
2. **Accessibility API** (needs Accessibility permission): queries
   AXUIElement window titles for the terminal app
3. **AppleScript**: iterates Terminal.app or iTerm2 windows by name

### Space switching via SkyLight

The menu bar app can switch macOS Spaces to reach a session's window.
It uses private SkyLight framework APIs loaded at runtime via `dlopen`:

- `CGSMainConnectionID`: get the connection to the window server
- `CGSGetActiveSpace`: current Space ID
- `CGSCopyManagedDisplaySpaces`: enumerate all Spaces per display
- `SLSCopySpacesForWindows`: find which Space a window is on
- `SLSManagedDisplaySetCurrentSpace`: switch a display to a Space

This is the same approach used by [Loop](https://github.com/MrKai77/Loop)
and other macOS window managers.

### Ensure/prefill restoration (requires tmux)

When you run `lats start` and a session already exists:

1. lattices checks the `ensure` / `prefill` flag in `.lattices.json`
2. For each pane, it queries `#{pane_current_command}` via tmux
3. If the pane is running a shell (bash, zsh, fish, sh, dash), the original
   command has exited. lattices then does one of these:
   - **ensure**: sends the command + Enter (auto-restart)
   - **prefill**: sends the command without Enter (manual restart)
4. Then it attaches to the session as normal

## Agent control

The agent API gives agents the same control as a human using the
menu bar app. An agent can list projects and windows, launch sessions,
tile windows to screen positions, subscribe to real-time events
(`windows.changed`, `tmux.changed`, `layer.switched`), and sync
sessions back to their declared config.

A typical orchestrator sets up a multi-project workspace in a few
`daemonCall()` invocations. See the [Agent API reference](/lattices/docs/api)
for the full method list and code examples.

## Key shortcuts (inside tmux)

These work when you're inside a tmux session:

| Shortcut       | Action                |
|----------------|-----------------------|
| Ctrl+B  D      | Detach from session   |
| Ctrl+B  X      | Kill current pane     |
| Ctrl+B  Left   | Move to left pane     |
| Ctrl+B  Right  | Move to right pane    |
| Ctrl+B  Up     | Move to pane above    |
| Ctrl+B  Down   | Move to pane below    |
| Ctrl+B  Z      | Zoom pane (toggle)    |
| Ctrl+B  [      | Scroll mode (q exits) |

The prefix `Ctrl+B` means: hold Control, press B, release both,
then press the next key.
