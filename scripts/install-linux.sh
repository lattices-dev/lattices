#!/usr/bin/env bash
set -euo pipefail

# Linux bootstrap for the public install.sh entry point and source checkouts.
# System packages use the distribution's package manager. App files are user-owned.
[[ $(uname -s) == Linux ]] || { echo 'This installer needs Linux.' >&2; exit 1; }
case $(uname -m) in x86_64|aarch64|arm64) ;; *) echo 'Supported Linux architectures: x86_64 and arm64.' >&2; exit 1 ;; esac

no_deps=0
preview=0
for arg in "$@"; do
  case "$arg" in
    --no-deps) no_deps=1 ;;
    --dry-run) preview=1 ;;
    --help|-h)
      cat <<'HELP'
Install Lattices on Linux (Hyprland + Quickshell)

  bash install.sh [--gestures | --wheel-gestures] [--no-start] [--dry-run]

--gestures          Add Forward-button gestures and the pen trail on Omarchy
--wheel-gestures    Also reserve wheel-click for gestures
--no-start          Install files without starting services or opening the app
--no-deps           Skip distribution packages; JavaScript dependencies still install
--replace-existing Back up and replace files from an older/manual installation
--dry-run           Print the plan without downloads, writes, package installs or services

Run in a Hyprland desktop. Other desktops are not supported.
HELP
      exit 0 ;;
    --gestures|--wheel-gestures|--no-start|--replace-existing) ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

installer_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer_source="$(dirname -- "$installer_dir")"
if [[ ! -f "$installer_source/apps/linux/install.ts" ]]; then installer_source=''; fi
if (( preview )); then
  echo 'Would install missing dependencies: git, curl, unzip, Bun, tmux, Quickshell, Python, grim, wtype, ffmpeg and tesseract.'
  echo 'Would copy a standalone user runtime, command launchers, app icon and systemd user services.'
  if [[ -n "$installer_source" ]] && command -v bun >/dev/null; then
    exec bun "$installer_source/apps/linux/install.ts" "$@"
  fi
  echo 'Would download the Lattices source into a temporary directory, install it and verify host health.'
  exit 0
fi

as_admin() {
  if (( EUID == 0 )); then "$@"
  elif command -v sudo >/dev/null; then sudo "$@"
  else echo "Need sudo to install system dependencies. Install them first, then retry --no-deps." >&2; exit 1
  fi
}
if (( EUID == 0 )); then
  echo 'Run this installer as your desktop user. It uses sudo only for missing system packages.' >&2
  exit 1
fi
if (( ! no_deps )); then
  missing=()
  # Hyprland itself belongs to the desktop setup; never install/replace a compositor here.
  for pair in git:git curl:curl unzip:unzip tmux:tmux quickshell:quickshell python3:python grim:grim wtype:wtype ffmpeg:ffmpeg tesseract:tesseract; do
    tool=${pair%%:*}; package=${pair#*:}
    if ! command -v "$tool" >/dev/null; then missing+=("$package"); fi
  done
  if ! [[ -f /usr/share/tessdata/eng.traineddata ]]; then missing+=(tesseract-data-eng); fi
  if (( ${#missing[@]} )); then
    if command -v pacman >/dev/null; then
      echo "Installing missing Arch packages: ${missing[*]}"
      as_admin pacman -S --needed --noconfirm "${missing[@]}"
    else
      echo "Install the missing commands with your distribution's package manager: ${missing[*]}" >&2
      echo 'Automatic dependency installation supports Arch/Omarchy. Retry with --no-deps once dependencies are available.' >&2
      exit 1
    fi
  fi
fi

if ! command -v bun >/dev/null && [[ -x "$HOME/.bun/bin/bun" ]]; then export PATH="$HOME/.bun/bin:$PATH"; fi
if ! command -v bun >/dev/null; then
  if (( no_deps )); then echo 'Bun is missing. Install Bun, add it to PATH and retry.' >&2; exit 1; fi
  command -v unzip >/dev/null || { echo 'Install unzip before installing Bun.' >&2; exit 1; }
  bun_script=$(mktemp)
  trap 'rm -f -- "$bun_script"' EXIT
  curl --fail --show-error --silent --location https://bun.sh/install --output "$bun_script"
  bash "$bun_script"
  rm -f -- "$bun_script"
  trap - EXIT
  export PATH="$HOME/.bun/bin:$PATH"
fi

installer_tmp=''
cleanup() { if [[ -n "$installer_tmp" ]]; then rm -rf -- "$installer_tmp"; fi; }
trap cleanup EXIT
if [[ -z "$installer_source" ]]; then
  command -v git >/dev/null || { echo 'Install git before running the bootstrap.' >&2; exit 1; }
  installer_tmp=$(mktemp -d)
  # Use one checkout for all installer and app files. No mixed revisions during installation.
  git clone --filter=blob:none --no-checkout --depth 1 --branch "${LATTICES_INSTALL_REF:-main}" https://github.com/lattices-dev/lattices.git "$installer_tmp/source"
  git -C "$installer_tmp/source" sparse-checkout set --no-cone '/bin/' '/apps/linux/' '/packages/host-linux/' '/packages/desktop-client/' '/packages/gateway/' '/packages/npm/sdk/' '/assets/logo-mark.svg' '/package.json' '/docs/'
  git -C "$installer_tmp/source" checkout
  installer_source="$installer_tmp/source"
fi
export PATH="$HOME/.local/bin:$PATH"
bun "$installer_source/apps/linux/install.ts" "$@"
