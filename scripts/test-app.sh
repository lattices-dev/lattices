#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Optional native products stay explicit: HUDSONKIT_WITH_VOICE=1 and/or
# LATTICES_BUNDLE=1 select their additional sources and tests.
export HUDSONKIT_WITH_VOICE="${HUDSONKIT_WITH_VOICE:-0}"
export LATTICES_BUNDLE="${LATTICES_BUNDLE:-0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/lattices-clang-cache}"
export SWIFTPM_TESTS_MODULECACHE="${SWIFTPM_TESTS_MODULECACHE:-${TMPDIR:-/tmp}/lattices-swiftpm-cache}"

# Render probes are separately opt-in. The three Stage integration suites
# physically drag, join, or tile existing desktop windows and remain manual.
unset LONG_RENDER_DIR MACHINES_RENDER_DIR OVERVIEW_RENDER_DIR
exec swift test --package-path "$repo_root/apps/mac" --skip-update --no-parallel \
  --skip 'Stage(Drag|Join|Tile)Tests' "$@"
