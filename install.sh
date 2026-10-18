#!/bin/bash
set -euo pipefail

# ── Lattices install shim ──────────────────────────────────────────────
# Keeps the public install URL stable while the real installer lives in
# scripts/install.sh:
#   curl -fsSL https://raw.githubusercontent.com/arach/lattices/main/install.sh | bash
#
# - Run from a checkout: forwards to ./scripts/install.sh (local link mode).
# - Piped via curl (no checkout on disk): fetches scripts/install.sh from main.
# ───────────────────────────────────────────────────────────────────────

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if [[ -n "${HERE:-}" && -f "$HERE/scripts/install.sh" ]]; then
  exec bash "$HERE/scripts/install.sh" "$@"
fi

# Standalone (curl | bash): pull the real installer from main.
installer_script="$(curl -fsSL https://raw.githubusercontent.com/arach/lattices/main/scripts/install.sh)"
exec bash -c "$installer_script" -- "$@"
