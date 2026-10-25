---
title: MCP
description: The lats mcp server, its browser, hosts and windows toolsets, and how agent harnesses register it
order: 8
---

One MCP server ships with the `lattices` package. Agent config names the binary,
never a path:

```json
{ "command": "lattices", "args": ["mcp"] }
```

Lattices **0.15.2** includes all 29 tools below: 14 browser tools, nine host
tools, and six window tools. Install the matching app and CLI, then restart
the MCP connection in your agent harness after upgrading.

## Current toolsets

| Toolset | Tools | Does the work | Product docs |
|---------|-------|---------------|--------------|
| `browser` | `browser_open`, `browser_tabs`, `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot`, `browser_console`, `browser_close`, `browser_profiles`, `browser_use_profile`, `browser_profile_info`, `browser_import_cookies`, `browser_companion_status` | Action Browser code inside the `lattices` package, driving Action-owned Chrome over CDP | [Action browser](/action/docs/browser) |
| `hosts` | `hosts_list`, `host_describe`, `host_windows`, `host_screenshot`, `host_read`, `host_place`, `host_focus`, `host_act`, `host_call` | This Mac's daemon over its private socket, or a paired host through its gateway | [Agent API](/lattices/docs/api) |
| `windows` | `windows_search`, `windows_place`, `windows_focus`, `layers_list`, `layers_switch`, `history_undo` | This Mac's daemon over its private socket | [Agent API](/lattices/docs/api) |

The `hosts` and `windows` toolsets reach this Mac's daemon the way `lats`
does: over the Unix socket `~/.lattices/run/lattices.sock`, with the token in
`~/.lattices/run/lattices.token`. No TCP port is open by default. A paired
remote host is reached through its gateway, which binds the host's Tailscale
address (port 9399 by default) and accepts only signed, approved clients. See
[Agent API](/lattices/docs/api).

### The `windows` toolset

The same window controls as the CLI, as tools on this Mac. Each tool wraps
one daemon method and reuses the CLI's search and place code:

| Tool | Daemon method | Same as |
|------|---------------|---------|
| `windows_search` | `search.query` (`sources: ["all"]` with `deep: true`) | `lats search`, `lats search --deep` |
| `windows_place` | `windows.place`; by `query`, deep search + `windows.focus` + `windows.place` | `lats window place`, `lats place` |
| `windows_focus` | `windows.focus` | `lats focus` |
| `layers_list` | `layers.list` | `lats layer` |
| `layers_switch` | `layers.activate` | `lats layer <name or slot>` |
| `history_undo` | `history.undo` | `lats call history.undo` |

Search with the basic sources first. Set `deep: true` only when the basic
search misses, for example a project that appears only in a terminal's cwd.
`windows_place` returns the daemon receipt with its `receiptId` at the top
level; pass that id to `history_undo` to put the window back.

`lats mcp` is a Lattices entry point. The `browser` toolset is Action Browser
code, so its workflow and profile rules belong to Action. Action.app also has
its own MCP server for private layers and native observe and act, started with
`lats action mcp`. That server is separate from `lats mcp`. See
[Action browser](/action/docs/browser) for which one to use.

## Why a subcommand and not a plugin path

Before this, Action Browser was addressed as if it were an independent product
living at a fixed place on disk. Every harness held its own copy of that
assumption, and each one broke differently:

| Harness | What it pointed at | Failure mode |
|---|---|---|
| Claude Code | marketplace `action` → `installLocation: /Users/art/dev/action` | Directory moved into `lattices/products/action`. The tools were simply **absent**: no error, nothing in `/mcp`. |
| Claude Code (after the first fix) | `.../plugins/cache/action/action-browser/0.3.0/` | A version-pinned copy. The next version bump orphans it. |
| Codex | `.../products/action/plugins/action-browser/scripts/...` | A checkout path. The next repo move breaks it. |

Each of those is the same bug wearing a different hat: **the address of the tools
was a location instead of a name.**

A subcommand fixes it because resolution follows the installed binary. If
`lattices` is on `PATH`, `lattices mcp` is correct, whether that is a global
`bun install -g @lattices/lattices`, a `bun link` from a checkout, or a future
Homebrew formula. Moving the repo, bumping the version, and reinstalling all
become no-ops for agent config.

### The runtime still has to be found

Naming the binary moves the problem from "where is the code" to "is the binary on
this process's `PATH`" -- which on macOS is not free. A GUI-launched app inherits
the bare system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), and neither `lattices`
nor `bun` is there:

```console
$ env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" sh -c 'command -v lattices || echo missing'
missing
```

The retired `run-action-browser-mcp.sh` knew this -- it hunted for Bun across
`ACTION_BUN_BIN`, `PATH`, and the usual install locations, and its test was
literally named "launcher finds the user Bun with a GUI PATH". Deleting that
script without replacing the behaviour would have traded one silent "the browser
tools are gone" for another.

So `bin/lattices` is a POSIX shell launcher, not a bun-shebanged script. It
resolves through however many symlinks the install put in the way, finds Bun
(`LATTICES_BUN_BIN` → `PATH` → `~/.bun/bin`, Homebrew, `/usr/local`), and execs
`bin/lattices.ts`. A harness that can find `lattices` at all can now run it, and a
machine with no Bun gets a one-line error instead of a failed exec.

Finding `lattices` itself is the part a launcher cannot solve. Claude Code
resolves it (verified: `claude mcp list` reports the server connected). A harness
that spawns with a bare system `PATH` would not, and the fallback there is to name
the install location -- `/Users/<you>/.bun/bin/lattices` -- which is still stable
across repo moves and version bumps, and so is still strictly better than what it
replaced.

### Alternatives considered

- **Point the marketplace at `github: lattices-dev/lattices` instead of a local
  directory.** Fixes today's specific breakage, and is genuinely path-free from
  the user's side. Rejected as the primary mechanism because it is Claude
  Code–only: Codex and Kimi would still hold literal paths, and each plugin
  update still writes a fresh version-pinned cache directory.
- **A separate `lattices-mcp` bin entry.** Works, but adds a second published
  binary name to keep in step with the first for no gain over a subcommand.
- **Publishing the MCP as its own npm package.** Reintroduces the thing being
  removed: two products to install, two versions to keep aligned.

## Layout

```
bin/lattices             # POSIX shell launcher: finds Bun, execs the CLI
bin/lattices.ts          # the CLI; `mcp` dispatches into bin/mcp
bin/mcp/
  server.ts              # `lattices mcp` entry: flags, signals, process
  router.ts              # stdio JSON-RPC, tool -> toolset table
  registry.ts            # lazily loaded toolsets
  types.ts               # the Toolset contract
  toolsets/
    browser/             # Action Browser, moved here from products/action
      index.ts
      navigation.ts
      viewport.ts
      transport.ts
      ...
    hosts/               # Lattices hosts over the daemon protocol
      index.ts
    windows/             # this Mac's search, place, focus, layers, undo
      index.ts
```

The server lives under `bin/`, which the npm package includes. The package also
includes the two Action browser profile and cookie helpers it uses; it does
not require an Action checkout. Release checks start the server from the
extracted package and verify its tool list and helper imports. The root `tsconfig.json`
already covers `bin/**/*.ts`, so the browser server is now typechecked by
`bun run check:types`, which it was not before.

## Toolsets

The router owns the protocol; a toolset owns its tools.

```ts
type Toolset = {
  name: string;
  tools: ToolDefinition[];
  init?(): Promise<void>;      // startup work, e.g. sweeping dead-owner claims
  onToolCall?(): void;         // per-call bookkeeping, e.g. the idle timer
  callTool(name, args): Promise<ToolResult>;
  instructions?: string[];
};
```

`init` runs once at startup for every enabled toolset. `onToolCall` fires only
for that toolset's own tools, so a call into one toolset does not reset another's
idle timer.

`lats mcp --toolsets browser` narrows to a subset; the default is all of
them. `lats mcp --list` prints the registry without speaking the protocol.

### Tool names are not namespaced

`browser_open`, `browser_screenshot`, `browser_close` and the rest keep their
exact names. They are load-bearing: they appear in the operator's global
`CLAUDE.md` and in standing instructions across three harnesses, and a rename
silently invalidates all of it.

What changes is the *client-side prefix*, which is derived from the server name
and was never stable anyway:

```
mcp__plugin_action-browser_action-browser__browser_open   →   mcp__lattices__browser_open
```

No instruction anywhere refers to the prefixed form, so nothing needs aliasing.
Future toolsets follow the same convention: a short verb-ish prefix per domain
(`browser_*`, `host_*`, `windows_*`, `layers_*`, and later `session_*`) rather than a product name.

## Lifecycle guarantees

These are the reason Action Browser is written the way it is: orphaned headless
Chromes filled this machine's disk on 2026-07-22. The fold **moves** that code
rather than reimplementing it, and deliberately changes none of its identifiers:

- Ownership claim files in `~/Library/Application Support/Action/BrowserSessions`
- Session names of the form `action-<pid>-<rand>` (`pidFromSessionName` parses
  that prefix, so it is part of the on-disk contract, not cosmetic)
- `ACTION_BROWSER_*` / `ACTION_CHROME_COMPANION_*` environment variables
- CDP port `9334`, profile root `~/Library/Application Support/Action/ChromeProfiles`
- Owner-dies → browser-dies, via `SIGTERM`/`SIGINT`/`SIGHUP` hooks plus a
  synchronous `exit` release
- The 15-minute idle close (`ACTION_BROWSER_IDLE_TIMEOUT_MS`)
- Ref-counting across concurrent servers sharing profile + port
- The startup sweep for dead-owner claims

Keeping the claim schema byte-identical has a migration payoff: an old plugin
server still running from the plugin cache and a new `lattices mcp` server
ref-count *each other* correctly. The two can overlap during a rollout without
either one killing a Chrome the other is using.

## What happened to the plugin and the `action` marketplace

**The plugin no longer ships an MCP server.** `.mcp.json`, the `mcpServers`
blocks in the Codex and Kimi manifests, and `scripts/run-action-browser-mcp.sh`
are gone. There is exactly one live path to the browser tools: `lattices mcp`.

Two registrations would have been worse than none. A session with both the
plugin installed *and* `lattices mcp` configured gets `browser_open` twice under
different prefixes, and an agent picking between two identical tools backed by
two separate Chrome-owning processes is a lifecycle problem, not a cosmetic one.

**The plugin survives as a skill carrier.** It still ships
`skills/action-browser/SKILL.md`, and the marketplace is renamed `action` →
`lattices` to match where the code now lives. The split is deliberate:

- The load-bearing part (tools) is addressed by name and cannot be broken by
  moving the repo.
- The nice-to-have part (skill prose) is still installed the plugin way, and if
  *that* ever breaks the failure is an agent with slightly less guidance, not an
  agent with no browser.

That asymmetry is the whole design. The 2026-09-10 outage was bad specifically
because a path failure took out capability. Now a path failure can only take out
documentation.

## Migrating a machine

Claude Code:

```bash
claude plugin uninstall action-browser@action
claude plugin marketplace remove action
claude mcp add lattices -s user -- lattices mcp
# optional, for the skill only:
claude plugin marketplace add lattices-dev/lattices
claude plugin install action-browser@lattices --scope user
```

Codex: replace the `[mcp_servers.action-browser]` block in `~/.codex/config.toml`:

```toml
[mcp_servers.lattices]
command = "lattices"
args = ["mcp"]
```

Kimi:

```bash
rm -rf ~/.kimi-code/plugins/managed/action-browser
```

then add the same `command: "lattices", args: ["mcp"]` entry to its MCP config.

`lattices mcp --print-config <claude|codex|kimi>` emits these snippets so a new
machine does not have to be told twice.

## Verifying

```bash
lattices mcp --list                    # toolsets and tool names, no protocol
bun test bin/mcp                       # router + toolset contract, each toolset
```

In a harness: `/mcp` should show `lattices` connected, and `browser_open`
followed by `browser_screenshot` should return a PNG.
