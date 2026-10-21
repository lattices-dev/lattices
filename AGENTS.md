# lattices

> macOS developer workspace manager — tmux sessions with a native Swift menu bar app for tiling, navigation, and project management

## Critical Context

**IMPORTANT:** Read these rules before making any changes:

- lattices has TWO primary interfaces: a TypeScript CLI (`bin/lattices.ts`) and a native Swift menu bar app (`apps/mac/Sources/`)
- Session names are `<basename>-<sha256-6chars>` — both CLI (Node `crypto`) and app (Swift `CryptoKit`) must produce identical hashes
- The app finds terminal windows via a `[lattices:session-name]` tag embedded in the tmux window title (`set-titles-string`)
- Window navigation falls through CG → AX → AppleScript depending on macOS permissions
- Space switching uses private SkyLight framework APIs loaded via dlopen at runtime
- Source builds use authenticated private IPC: the daemon listens on `~/.lattices/run/lattices.sock`, with a private `lattices.token` required before WebSocket upgrade. `LATTICES_RUNTIME_DIR` overrides the runtime directory for isolated runs. Legacy loopback TCP requires explicit `LATTICES_ALLOW_LOOPBACK_TCP=1` and still requires authentication.
- The voice runtime stays in-process in the menu bar app, using private `voice.sock` and `voice.token`; Speech remains an independent app using `speech.sock`. See `LatticesLocalEndpoints`. Lattices 0.15.1 requires matching app and CLI versions; Action 0.4.0 and Speech 0.3.0 use their own matching clients.
- Remote access belongs to the separate, opt-in `lats gateway start --tailnet` process. It binds the verified Tailscale IP, authenticates peers and signed requests, and enforces locally approved exact product/method grants. Product startup must not implicitly start a network gateway.
- Bare `lats` (no args) shows a home/status screen — use `lats start` (alias: `lats tmux`) to create or attach a session
- `lats search <q> --deep` and `--all` both request all search sources (index + live terminal inspection)
- Action is a separate Lattices product under `products/action/`; it keeps its own Bun workspace, signed `Action.app`, local agent runtime, and nested `AGENTS.md` contract.
- `lats action` (`bin/lattices-action.ts`) is the product-family entry point: installs `Action.app` from the latest `action-v*` GitHub release, reports status, launches/quits, calls a matching source-built Action agent through private `action.sock` (`lats action call`), and forwards other verbs to the Action CLI when a `products/action` checkout is present. Action 0.4.0 uses private IPC; clients do not silently fall back to the older transport.
- Keep Action's AppKit and recording lifecycle separate from the Lattices menu bar app even though both products share this repository and website.
- Canvas (formerly Blink) is a separate Lattices product under `products/blink/`, with its own Swift package, notes CLI, and nested `AGENTS.md` contract. Current source builds produce `Canvas.app` and the `canvas` CLI; `BlinkApp` and `blink` remain SwiftPM executable aliases. The published npm package remains `@arach/blink`; these source changes do not mean a Canvas release has shipped.
- `lats canvas` is the family entry point; `lats blink` remains an alias. Neither entry point merges Canvas into the Lattices app lifecycle. Keep Canvas's note panels and NoteStore independent of the Lattices menu bar app.
- Preserve Canvas's existing identities: `dev.arach.blink`, `~/Library/Application Support/Blink`, `blink.sock`, `blink.*` frontmatter, settings keys, Keychain items, and peer protocol identifiers. Nonempty `CANVAS_HOME` takes precedence over nonempty `BLINK_HOME`; an empty value is ignored. No data move is required for the rename.
- Canvas 2.3.0's release contract pairs `canvas-v2.3.0` / `Canvas.dmg` / `Canvas.app` with `blink-v2.3.0` / `Blink.dmg` / `Blink.app` compatibility assets from the same source commit. The app's signed contents and identity match; the DMGs are distinct. See `products/blink/docs/release.md` for the separately verified `arach/blink` mirror and publication status. Preserve explicit mobile-access choices and existing Keychain approvals; new installs remain off.

## Project Structure

| Component | Path | Purpose |
|-----------|------|---------|
| CLI | `bin/lattices.ts` | Published command-line workspace manager |
| App Helper | `bin/lattices-app.ts` | Build, launch, quit, and restart the app |
| Build script | `bin/lattices-build` | App bundle / DMG packaging (wrapped by `scripts/build.sh`) |
| Menu Bar App | `apps/mac/Sources/` | SwiftUI/AppKit app + daemon (`apps/mac/Package.swift`) |
| Swift packages | `swift/` | LatticesTerminalKit + DeckKit (`swift/Package.swift`) |
| Tests | `tests/` | CLI (node:test), dependency-free (bun test), e2e daemon |
| Docs | `docs/` | User + agent documentation |
| Site | `apps/site/` | Vite website, docs, and blog |
| Agent skills | `skills/` | Family catalog: lattices, action, speech, blink (`npx skills add arach/lattices`) |
| Action | `products/action/` | Native computer-use app, agent runtime, CLI/MCP surfaces, and release tooling |
| Action Native | `products/action/native/engine/` | Signed Action.app, local agent, recording probe, and native scripts |
| Canvas | `products/blink/` | Independent spatial notes app, CLI, iOS companion, and landing |
| Canvas Native | `products/blink/Sources/` | Canvas.app, BlinkCore, BlinkPeer, and the notes CLI |

## Commands

Package manager is **bun** (Node 18+ also works for the CLI entry points).

```bash
bun link                        # Install CLI locally for development
bun run check                   # TypeScript typecheck + Swift app build
bun run check:types             # tsc --noEmit
bun run check:app               # swift build --package-path apps/mac
bun run test                    # CLI tests + dependency-free tests
bun run test:cli                # node --experimental-strip-types --test tests/cli.test.mjs
bun run test:e2e                # daemon e2e tests (requires running app/daemon)
bun run test:dependencies       # bun test tests/dependency-free.test.ts
swift build --package-path swift   # Swift packages (LatticesTerminalKit, DeckKit)
swift test --package-path swift    # Swift package tests
lats app build                  # Rebuild the menu bar app from source
scripts/build.sh                # Signed + notarized release DMG (--local to skip notarization)
scripts/build.sh package        # npm/package app bundle
bun run action:check            # Action TypeScript + safety guard
bun run action:native:doctor    # Build and verify Action.app from the monorepo
bun run canvas:check            # Canvas Swift tests (resolves pinned Hudson)
bun run canvas:build            # Canvas app + CLI via products/blink Package.swift
# blink:check and blink:build remain aliases
```

## Quick Navigation

- Working with **cli**? → Check bin/lattices.ts for CLI commands and session logic
- Working with **app**? → Check apps/mac/Sources/ for Swift menu bar app code
- Working with **config**? → Check docs/config.md for .lattices.json format and CLI reference
- Working with **tiling**? → Check apps/mac/Sources/Core/Desktop/WindowTiler.swift and apps/mac/Sources/Core/Desktop/PlacementSpec.swift
- Working with **command bar**? → Check apps/mac/Sources/Core/Overlays/UnifiedCommandBar/ for the unified command bar (browse, search, slash-commands, voice)
- Working with **terminal**? → Check apps/mac/Sources/Core/Workspace/Terminal/Terminal.swift for supported terminals and launch logic
- Working with **daemon**? → Check apps/mac/Sources/Core/Daemon/DaemonServer.swift and apps/mac/Sources/Core/Daemon/LatticesApi.swift for WebSocket API
- Working with **api**? → Check docs/api.md for the daemon RPC reference
- Working with **agent docs**? → Check docs/agents.md and apps/site/scripts/agent-docs.mjs for raw markdown, prompt, and context artifacts
- Working with **agent skills**? → Check skills/ (lattices, action, speech, blink)
- Working with **Action**? → Read products/action/AGENTS.md before changing its app, runtime, capture, plugins, or release path
- Working with **Canvas** (formerly Blink)? → Read products/blink/AGENTS.md before changing notes, panels, CLI, or the iOS companion

## Documentation

Full documentation lives in `docs/` — read these before changing behavior:

- `docs/quickstart.md` — install and first session
- `docs/concepts.md` — architecture, glossary, session naming, ensure/prefill
- `docs/config.md` — `.lattices.json` format, CLI command reference, tile positions
- `docs/app.md` — menu bar app: command palette, tiling, settings, supported terminals
- `docs/layers.md` — workspace layers and tab groups (`~/.lattices/workspace.json`)
- `docs/api.md` — daemon RPC methods, events, wire protocol, agent integration patterns
- `docs/agents.md` — agent-facing documentation and context artifacts

## Active workspace ownership

Use exactly two ongoing Lattices workspaces on this machine:

- Native app and its supporting CLI: `/Users/arach/dev/lattices`, branch `main` tracking `origin/main`.
- Website, documentation, Studio studies, and other non-native work: `/Users/arach/dev/lattices-design`, branch `codex/web-workspace`.

Accumulate changes in these destinations. Do not create a feature worktree or switch the everyday native app to another checkout unless the user explicitly requests it. Build and relaunch the everyday app only from the native workspace; the web workspace is not an app installation source. Preserve the independent Action, Canvas, and Speech lifecycles.

Other pre-existing worktrees are inactive recovery copies. Their dirty files and unique branches must not be discarded. The September 20 consolidation recovery archive is `/Users/arach/Documents/Lattices-recovery-20260920-1410`.
