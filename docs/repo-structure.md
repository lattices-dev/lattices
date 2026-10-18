# Repository Structure

Lattices is a monorepo with three product boundaries. The root should make the
Lattices workspace surfaces and the focused Action and Blink products obvious.

This document is the current maintainer-facing map and the proposed direction
for keeping file structure as architecture.

## Current Top-Level Areas

| Path | Role |
| --- | --- |
| `apps/mac/` | Native macOS menu bar app. Swift/AppKit/SwiftUI package. |
| `bin/` | Published TypeScript CLI and app helper entry points. |
| `swift/` | Shared Swift package code used by the app. |
| `apps/ios/` | iOS companion app experiments and local build state. |
| `apps/site/` | Vite website, documentation, and blog content. |
| `apps/site/scripts/agent-docs.mjs` | Agent-facing docs collector and static artifact writer. |
| `products/action/` | Action computer-use product. Contains its own Bun workspace, native app, runtime, plugins, and docs. |
| `products/blink/` | Blink spatial-notes product. Contains its own Swift package, signed app, CLI, iOS companion, and landing. |
| `docs/` | Markdown docs and engineering proposals. |
| `skills/` | Family skill catalog for skills.sh: lattices, action, speech, blink. |
| `assets/` | Shared release/app assets. |
| `design/` | Design specifications, catalogs, and Studio. |
| `studies/` | Bounded experiments and their supporting notes, source, and captures. |
| `studies/archive/` | Historical experiments retained for reference. See the [website and deck archive](../studies/archive/website-deck-experiments/README.md). |
| `scripts/` | User/dev entry-point scripts: `install.sh`, `uninstall.sh`, `build.sh`, `run.sh` (root `install.sh` is a shim forwarding here). |
| `tools/release/` | Maintainer scripts for building and shipping. |
| `tests/` | CLI, daemon, and evaluation tests. |

## Problem

The root currently mixes categories:

- shipped Lattices surfaces: `apps/mac/`, `bin/`, `swift/`
- focused product surfaces: `products/action/`, `products/blink/`
- website/docs: `apps/site/`
- companion experiments: `apps/ios/`
- generated or release output: `dist/`
- maintainer and agent affordances: `docs/`, `tools/`, `tests/`

That makes the project feel larger than it is. It also makes it harder to see
which directories are architecture and which are support material.

## Target Shape

Do not reorganize everything at once. The target is:

```text
apps/
  mac/            # macOS menu bar app
  ios/            # iOS companion app
  site/           # website, documentation, and blog content

packages/
  cli/            # current bin/ plus TypeScript package surface
  swift/          # current swift/

products/
  action/         # Action app, runtime, plugins, and product docs
  blink/          # Blink app, CLI, iOS companion, and product docs

docs/
  proposals/

skills/           # family skill catalog (lattices, action, speech, blink)

tools/
  release/        # release/build scripts
```

This is intentionally similar to the `apps/` and `packages/` split used by
small monorepos such as Flue, but adapted for Lattices' macOS app plus CLI
shape.

## Migration Rules

- Move one category at a time.
- Keep published npm entry points stable.
- Keep app bundle and release scripts working after each move.
- Keep `products/action/` and `products/blink/` as explicit product roots with
  their own packages and agent instructions.
- Update docs and agent instructions in the same PR as any move.
- Avoid renames that only satisfy aesthetics without reducing ambiguity.
- Keep generated output ignored and out of the architectural map.

## Near-Term Cleanup

Good first moves:

1. Treat `dist/` as generated output only.
2. Move blog content closer to the site that owns it, or explicitly document it
   as shared content.
3. Decide whether the iOS companion remains in this repo or moves to its own
   repo once the companion work becomes active again.
4. Split `docs/proposals/` for numbered engineering docs such as `LAT-001`.
5. Decide whether `bin/` remains the package root for the CLI or becomes
   `packages/cli/src/` before adding more exported modules.

## What Stays Boring

Root files should be few and intentional:

- `README.md`
- `AGENTS.md`
- `package.json`
- lockfile
- TypeScript config
- license/security/contribution docs
- release/install affordances

Everything else should either be a product surface, a package, docs, content,
or tooling.

Keep experiment images and write-ups together under `studies/<study>/`.
Retain useful historical material under `studies/archive/` instead of leaving
captures and generated variations at the repository root. Store maintained
site assets in `apps/site/public/` and app/release assets in `assets/`.

The root retains `CLAUDE.md` and `AGENTS.md` for agent guidance, `PRODUCT.md`
for website product context, `llms.txt` for documentation discovery, and
`kimi.plugin.json` for plugin discovery. These files are maintained metadata.
