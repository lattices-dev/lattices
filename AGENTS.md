# lattices

> macOS developer workspace manager — tmux sessions with a native Swift menu bar app for tiling, navigation, and project management

## Critical Context

**IMPORTANT:** Read these rules before making any changes:

- lattices has TWO primary interfaces: a TypeScript CLI (`bin/lattices.ts`) and a native Swift menu bar app (`apps/mac/Sources/`)
- Session names are `<basename>-<sha256-6chars>` — both CLI (Node `crypto`) and app (Swift `CryptoKit`) must produce identical hashes
- The app finds terminal windows via a `[lattices:session-name]` tag embedded in the tmux window title (`set-titles-string`)
- Window navigation falls through CG → AX → AppleScript depending on macOS permissions
- Space switching uses private SkyLight framework APIs loaded via dlopen at runtime
- The daemon runs on ws://127.0.0.1:9399 with 35+ RPC methods and real-time events (localhost only, no auth by design)
- Voice runtime is hosted in-process by the menu bar app on ws://127.0.0.1:9398 (deterministic Lattices port family: 9399 agent API, 9398 voice; see `LatticesLocalEndpoints` / `docs/voice.md`)
- Bare `lats` (no args) shows a home/status screen — use `lats start` (alias: `lats tmux`) to create or attach a session
- `lats search <q> --deep` and `--all` both request all search sources (index + live terminal inspection)
- Action is a separate Lattices product under `products/action/`; it keeps its own Bun workspace, signed `Action.app`, local agent runtime, and nested `AGENTS.md` contract.
- `lats action` (`bin/lattices-action.ts`) is the product-family entry point: installs `Action.app` from the latest `action-v*` GitHub release, reports status, launches/quits, calls the Action agent on ws://127.0.0.1:4319 (`lats action call`), and forwards other verbs to the Action CLI when a `products/action` checkout is present.
- Keep Action's AppKit and recording lifecycle separate from the Lattices menu bar app even though both products share this repository and website.
- Blink is a separate Lattices product under `products/blink/`; it keeps its own Swift package, signed `Blink.app`, notes CLI, and nested `AGENTS.md` contract.
- Keep Blink's note panels and NoteStore separate from the Lattices menu bar app even though both products share this repository and website.

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
| Blink | `products/blink/` | Spatial notes app, CLI, iOS companion, and landing |
| Blink Native | `products/blink/Sources/` | Signed Blink.app, BlinkCore, BlinkPeer, and the notes CLI |

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
bun run blink:check             # Blink Swift tests (needs ../../../hudson)
bun run blink:build             # Blink app + CLI via products/blink Package.swift
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
- Working with **Blink**? → Read products/blink/AGENTS.md before changing notes, panels, CLI, or the iOS companion

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

Accumulate changes in these destinations. Do not create a feature worktree or switch the everyday native app to another checkout unless the user explicitly requests it. Build and relaunch the everyday app only from the native workspace; the web workspace is not an app installation source. Preserve the independent Action, Blink, and Speech lifecycles.

Other pre-existing worktrees are inactive recovery copies. Their dirty files and unique branches must not be discarded. The September 20 consolidation recovery archive is `/Users/arach/Documents/Lattices-recovery-20260920-1410`.
