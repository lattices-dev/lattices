#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_args=(--skip-update --no-parallel --skip 'Stage(Drag|Join|Tile)Tests')
if [[ "${1:-}" == "--release-profile" ]]; then
  shift
  # Use the same manifest and LATTICES_TIER override as build-dmg.sh. A
  # reduced local test run must not stand in for validation of the shipped app.
  feature_env="$(bun "$repo_root/bin/lattices-build-env.ts" shell)"
  eval "$feature_env"
  export LATTICES_HUDSON_SOURCE=git HUDSON_VOX_SOURCE=git
  # Release validation uses the revisions in Package.swift/Package.resolved,
  # never a sibling checkout or a developer's branch override.
  unset LATTICES_HUDSON_PATH LATTICES_VOX_SOURCE HUDSON_VOX_PATH
  unset HUDSON_VOX_GIT_URL HUDSON_VOX_GIT_REVISION HUDSON_VOX_GIT_BRANCH HUDSON_VOX_PACKAGE
  test_args+=(--configuration release --force-resolved-versions)
else
  # Keep the inexpensive core profile available for local iteration.
  export HUDSONKIT_WITH_VOICE="${HUDSONKIT_WITH_VOICE:-0}"
  export LATTICES_BUNDLE="${LATTICES_BUNDLE:-0}"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/lattices-clang-cache}"
export SWIFTPM_TESTS_MODULECACHE="${SWIFTPM_TESTS_MODULECACHE:-${TMPDIR:-/tmp}/lattices-swiftpm-cache}"

# Render probes are separately opt-in. The three Stage integration suites
# physically drag, join, or tile existing desktop windows and remain manual.
unset LONG_RENDER_DIR MACHINES_RENDER_DIR OVERVIEW_RENDER_DIR
exec swift test --package-path "$repo_root/apps/mac" "${test_args[@]}" "$@"
