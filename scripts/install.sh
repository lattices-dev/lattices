#!/bin/bash
set -euo pipefail

# ── Lattices Installer ─────────────────────────────────────────────────
# Public entry point is the root shim, which forwards here:
#   curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/install.sh | bash
# ───────────────────────────────────────────────────────────────────────

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${BOLD}▸${RESET} $1"; }
ok()    { echo -e "${GREEN}✓${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }
fail()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

# Linux has its own runtime and user-service installation path.
if [[ "$(uname -s)" == "Linux" ]]; then
  linux_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -f "$linux_script_dir/install-linux.sh" ]]; then
    exec bash "$linux_script_dir/install-linux.sh" "$@"
  fi
  linux_installer="$(curl -fsSL https://raw.githubusercontent.com/lattices-dev/lattices/main/scripts/install-linux.sh)"
  exec bash -c "$linux_installer" -- "$@"
fi

# ── Platform check ────────────────────────────────────────────────────

[[ "$(uname)" == "Darwin" ]] || fail "Lattices requires macOS."

ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] || fail "Unsupported architecture: $ARCH"

# macOS version check (13.0+ required)
MACOS_VERSION="$(sw_vers -productVersion)"
MAJOR="${MACOS_VERSION%%.*}"
if [[ "$MAJOR" -lt 13 ]]; then
  fail "Lattices requires macOS 13.0+. You have $MACOS_VERSION."
fi

echo ""
echo -e "${BOLD}lattices${RESET} installer"
echo -e "${DIM}macOS $MACOS_VERSION ($ARCH)${RESET}"
echo ""

# ── Homebrew ──────────────────────────────────────────────────────────

ensure_brew() {
  if command -v brew &>/dev/null; then
    return
  fi
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for this session
  if [[ "$ARCH" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# ── Dependencies ──────────────────────────────────────────────────────

install_dep() {
  local cmd="$1" pkg="${2:-$1}" tap="${3:-}"
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd $(command -v "$cmd" | xargs)"
    return
  fi
  ensure_brew
  if [[ -n "$tap" ]]; then
    brew tap "$tap" 2>/dev/null || true
  fi
  info "Installing $pkg..."
  brew install "$pkg"
  ok "$cmd installed"
}

info "Checking dependencies..."
install_dep tmux
install_dep bun "oven-sh/bun/bun" "oven-sh/bun"

# ── Install CLI ───────────────────────────────────────────────────────
# If run from inside the source repo, link the local checkout instead of
# fetching from npm. Detected by package.json next to this script with
# name "@lattices/lattices" (also published as @lattices/cli).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # this script lives in scripts/
LOCAL_MODE=0
if [[ -f "$REPO_ROOT/package.json" ]] && \
   grep -qE '"@lattices/lattices"|"@arach/lattices"|"@lattices/cli"' "$REPO_ROOT/package.json"; then
  LOCAL_MODE=1
fi

if [[ "$LOCAL_MODE" -eq 1 ]]; then
  info "Linking @lattices/lattices from $REPO_ROOT..."
else
  info "Installing @lattices/lattices..."
fi

if command -v lattices &>/dev/null; then
  warn "lattices already installed — replacing"
fi

if [[ "$LOCAL_MODE" -eq 1 ]]; then
  (cd "$REPO_ROOT" && bun link)
else
  bun install -g @lattices/lattices
fi
ok "CLI installed → $(command -v lattices)"

# ── Verify CLI ────────────────────────────────────────────────────────

if ! lattices help &>/dev/null; then
  fail "CLI installed but 'lattices help' failed. Check your PATH includes bun's global bin."
fi

ok "lattices help works"

# ── Build or download the menu bar app ────────────────────────────────

info "Setting up the menu bar app..."

if command -v swift &>/dev/null; then
  info "Swift found — building from source..."
  lattices-app build
else
  info "No Swift toolchain — downloading pre-built binary..."
  lattices-app
fi

ok "Menu bar app ready"

# ── Launch ────────────────────────────────────────────────────────────

info "Launching lattices..."
lattices-app
ok "Lattices is running"

# ── Done ──────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}Lattices installed successfully.${RESET}"
echo ""
echo -e "  ${BOLD}Quick start:${RESET}"
echo -e "    cd ~/your-project"
echo -e "    lattices init          ${DIM}# create .lattices.json config${RESET}"
echo -e "    lattices                ${DIM}# start workspace${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "    lattices help           ${DIM}# all commands${RESET}"
echo -e "    lattices search <q>     ${DIM}# find windows${RESET}"
echo -e "    lattices tile           ${DIM}# tile current windows${RESET}"
echo ""
