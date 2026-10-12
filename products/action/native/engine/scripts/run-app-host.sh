#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)
PACKAGE_DIR="$ROOT_DIR/native/engine"
APP_DIR="${ACTION_DIST_DIR:-$ROOT_DIR/native/dist}/Action.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/Action"
COMMAND="${1:-status}"

# Capability discovery reads the signed bundle without a LaunchServices activation,
# AppKit lifecycle or implicit build. It does not inspect permissions/running apps.
if [[ "$COMMAND" == "capabilities" ]]; then
  if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "Action bundle is missing; install a matched app/runtime or build on the development host." >&2
    exit 1
  fi
  exec "$APP_EXECUTABLE" "$@"
fi

# The agent performs every ScreenCaptureKit and Accessibility call the runtime makes,
# so it has to carry the bundle's TCC identity. A direct exec of the binary does not:
# TCC attributes the request to the responsible process it inherits from the calling
# shell, so the agent saw both permissions as denied while `status` — launched through
# LaunchServices a moment earlier from the same bundle — reported them granted. That
# split is what made observe.snapshot fail with a permission error nobody could
# reproduce anywhere else. Launch it the way the recording probe already does.
# -g keeps the launch from stealing focus; the agent demotes itself to .accessory.
run_agent_via_open() {
  open -n -g "$APP_DIR" --args "$@" >/dev/null
}

run_via_open() {
  local reply_file
  local attempt
  reply_file=$(mktemp "${TMPDIR:-/tmp}/action-host.XXXXXX")

  # The drape must not steal focus. open(1) without -g activates Action, and a
  # later raise-window instance exiting can hand activation back to the still-
  # running drape — burying the subject that was just put on the sheet.
  # window-order must not steal focus either: it exists to read the scene
  # after raise, so activating Action would rewrite the z-order it measures.
  # raise-window itself cannot use -g: a background Action process sees an
  # empty AX window list, so the raise would never land.
  local open_flags=(-n)
  # Pointer input must reach the current foreground target. Activating this
  # short-lived helper first makes the target consume the click for activation.
  if [[ "$COMMAND" == "drape" || "$COMMAND" == "window-order" || "$COMMAND" == "click-point" || "$COMMAND" == "agent-layer" || "$COMMAND" == "agent-display" || "$COMMAND" == "agent-cursor-overlay" || "$COMMAND" == blink-* ]]; then
    open_flags+=(-g)
  elif [[ "$COMMAND" == "launch-app" && " $* " == *" --background "* ]]; then
    # Opens the app without activating it; the helper mustn't take focus either.
    open_flags+=(-g)
  fi
  open "${open_flags[@]}" "$APP_DIR" --args "$@" --reply-file "$reply_file" >/dev/null

  for attempt in {1..100}; do
    if [[ -s "$reply_file" ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ -s "$reply_file" ]]; then
    cat "$reply_file"
    if grep -q '"status"[[:space:]]*:[[:space:]]*"error"' "$reply_file"; then
      rm -f "$reply_file"
      return 1
    fi
    rm -f "$reply_file"
    return 0
  fi

  rm -f "$reply_file"
  echo "ActionHost did not write a reply file for command $*" >&2
  return 1
}

needs_build=0

# Anything the bundle is built from counts: every .swift file under native/engine (Package.swift,
# Sources, CoreSources, AgentSources, AgentCLISources, ProbeSources, and whatever gets added next)
# plus every bundle plist template (App, AgentApp). Scanning by pattern instead of by directory
# means a new source root never needs this check edited again.
if [[ ! -x "$APP_EXECUTABLE" ]]; then
  needs_build=1
elif find "$PACKAGE_DIR" \
  \( -name .build -o -name .git \) -prune -o \
  \( -name '*.swift' -o -name '*.h' -o -name '*.m' -o -name 'Info.plist' \) -type f -newer "$APP_EXECUTABLE" -print -quit \
  | grep -q .; then
  needs_build=1
fi

if [[ $needs_build -eq 1 ]]; then
  if [[ -f "$ROOT_DIR/runtime-provenance.json" ]]; then
    echo "Installed Action runtime needs a matching native bundle; refusing an implicit rebuild on an installation target." >&2
    exit 1
  fi
  "$SCRIPT_DIR/build-app.sh" >/dev/stderr
fi

if [[ "$COMMAND" == "agent" ]]; then
  run_agent_via_open "$@"
  exit 0
fi

run_via_open "$@"
