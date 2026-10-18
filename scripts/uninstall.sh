#!/bin/bash
set -euo pipefail

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${BOLD}▸${RESET} $1"; }
ok()    { echo -e "${GREEN}✓${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }

echo ""
echo -e "${BOLD}lattices${RESET} uninstaller"
echo ""

# ── Quit the app ──────────────────────────────────────────────────────

if pgrep -x Lattices &>/dev/null; then
  info "Stopping lattices app..."
  pkill -x Lattices 2>/dev/null || true
  sleep 0.5
  pkill -9 -x Lattices 2>/dev/null || true
  ok "App stopped"
else
  ok "App not running"
fi

# ── Remove CLI ────────────────────────────────────────────────────────

if command -v lattices &>/dev/null; then
  info "Removing Lattices CLI packages..."
  for package in @lattices/lattices @arach/lattices @lattices/cli; do
    bun remove -g "$package" 2>/dev/null || true
    npm uninstall -g "$package" 2>/dev/null || true
    if command -v pnpm >/dev/null 2>&1; then pnpm remove -g "$package" 2>/dev/null || true; fi
  done
  ok "CLI removed"
else
  ok "CLI not installed"
fi

# ── Remove config ─────────────────────────────────────────────────────

if [[ -d "$HOME/.lattices" ]]; then
  echo ""
  echo -e "${YELLOW}Found config at ~/.lattices/${RESET}"
  read -rp "Remove it? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/.lattices"
    ok "Config removed"
  else
    warn "Kept ~/.lattices/"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Lattices uninstalled.${RESET}"
echo ""
