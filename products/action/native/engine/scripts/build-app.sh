#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)
PACKAGE_DIR="$ROOT_DIR/native/engine"
APP_TEMPLATE_DIR="$PACKAGE_DIR/App"
AGENT_APP_TEMPLATE_DIR="$PACKAGE_DIR/AgentApp"
DIST_DIR="${ACTION_DIST_DIR:-$ROOT_DIR/native/dist}"
APP_DIR="$DIST_DIR/Action.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
AGENT_HELPER_APP_DIR="$HELPERS_DIR/ActionAgent.app"
AGENT_HELPER_CONTENTS_DIR="$AGENT_HELPER_APP_DIR/Contents"
AGENT_HELPER_MACOS_DIR="$AGENT_HELPER_CONTENTS_DIR/MacOS"
PLIST_TEMPLATE="$APP_TEMPLATE_DIR/Info.plist"
AGENT_PLIST_TEMPLATE="$AGENT_APP_TEMPLATE_DIR/Info.plist"
LOCK_DIR="$ROOT_DIR/native/.action-build.lock"
BUILD_CONFIGURATION="${ACTION_BUILD_CONFIGURATION:-debug}"
ACTION_VERSION="${ACTION_VERSION:-}"
ACTION_BUILD_NUMBER="${ACTION_BUILD_NUMBER:-}"
LOCK_TIMEOUT_SECONDS="${ACTION_BUILD_LOCK_TIMEOUT_SECONDS:-120}"

resolve_identity() {
  local requested="$1"

  if [[ "$requested" == "-" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  if [[ "$requested" =~ '^[0-9A-Fa-f]{40}$' ]]; then
    printf '%s\n' "$requested"
    return
  fi

  local resolved
  resolved=$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="\"$requested\"" 'index($0, name) {print $2; exit}')
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return
  fi

  printf '%s\n' "$requested"
}

detect_identity() {
  if [[ -n "${ACTION_CODESIGN_IDENTITY:-}" ]]; then
    resolve_identity "$ACTION_CODESIGN_IDENTITY"
    return
  fi

  local identity

  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2; exit}')
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
    return
  fi

  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/{print $2; exit}')
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
    return
  fi

  printf '%s\n' "-"
}

acquire_lock() {
  local waited_tenths=0
  local max_tenths=$((LOCK_TIMEOUT_SECONDS * 10))

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -f "$LOCK_DIR/pid" ]]; then
      local owner_pid
      owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)

      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi

    if (( waited_tenths >= max_tenths )); then
      if [[ ! -f "$LOCK_DIR/pid" ]]; then
        echo "Removing stale build lock without an owner pid: $LOCK_DIR" >&2
        rm -rf "$LOCK_DIR"
        waited_tenths=0
        continue
      fi

      echo "Timed out waiting for build lock: $LOCK_DIR" >&2
      exit 1
    fi

    sleep 0.1
    waited_tenths=$((waited_tenths + 1))
  done

  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

release_lock() {
  if [[ -f "$LOCK_DIR/pid" ]] && [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    return
  fi

  rmdir "$LOCK_DIR" 2>/dev/null || true
}

codesign_item() {
  local item="$1"
  local args=(--force --sign "$SIGNING_IDENTITY")

  if [[ "${ACTION_CODESIGN_HARDENED_RUNTIME:-0}" == "1" ]]; then
    args+=(--options runtime)
  fi

  if [[ "${ACTION_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
    args+=(--timestamp)
  fi

  codesign "${args[@]}" "$item" >&2
}

apply_bundle_version() {
  local plist="$1"

  if [[ -n "$ACTION_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ACTION_VERSION" "$plist"
  fi

  if [[ -n "$ACTION_BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ACTION_BUILD_NUMBER" "$plist"
  fi
}

case "$BUILD_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Unsupported ACTION_BUILD_CONFIGURATION: $BUILD_CONFIGURATION" >&2
    exit 1
    ;;
esac

acquire_lock
trap release_lock EXIT

swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIGURATION" >&2

BIN_DIR=$(swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)
HOST_EXECUTABLE="$BIN_DIR/ActionHost"
AGENT_EXECUTABLE="$BIN_DIR/ActionAgent"
APP_EXECUTABLE="$MACOS_DIR/Action"
APP_AGENT_EXECUTABLE="$AGENT_HELPER_MACOS_DIR/ActionAgent"
SIGNING_IDENTITY=$(detect_identity)

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$AGENT_HELPER_MACOS_DIR"
cp "$HOST_EXECUTABLE" "$APP_EXECUTABLE"
cp "$AGENT_EXECUTABLE" "$APP_AGENT_EXECUTABLE"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
cp "$AGENT_PLIST_TEMPLATE" "$AGENT_HELPER_CONTENTS_DIR/Info.plist"
# Prebuilt and committed: scripts/build-app-icon.sh renders it with the site's
# brand exporter, from ActionMark in apps/site/src/components/ActionMark.tsx.
# Copied, never generated here, so an ordinary build does not pay for it.
if [[ -f "$ROOT_DIR/assets/brand/Action.icns" ]]; then
  cp "$ROOT_DIR/assets/brand/Action.icns" "$RESOURCES_DIR/Action.icns"
else
  print -u2 "warning: assets/brand/Action.icns missing; Action.app will use the generic icon"
fi
if [[ -d "$ROOT_DIR/themes" ]]; then
  mkdir -p "$RESOURCES_DIR/Themes"
  theme_files=("$ROOT_DIR"/themes/*.json(N))
  if (( ${#theme_files[@]} )); then
    cp "${theme_files[@]}" "$RESOURCES_DIR/Themes/"
  fi
fi
if [[ -f "$ROOT_DIR/assets/pets/mira/pet.json" && -f "$ROOT_DIR/assets/pets/explorer-cat/sprites/explorer-cat.sheet.webp" ]]; then
  mkdir -p "$RESOURCES_DIR/Pets/mira"
  cp "$ROOT_DIR/assets/pets/mira/pet.json" "$RESOURCES_DIR/Pets/mira/pet.json"
  cp "$ROOT_DIR/assets/pets/explorer-cat/sprites/explorer-cat.sheet.webp" "$RESOURCES_DIR/Pets/mira/spritesheet.webp"
fi
apply_bundle_version "$CONTENTS_DIR/Info.plist"
apply_bundle_version "$AGENT_HELPER_CONTENTS_DIR/Info.plist"

python3 "$SCRIPT_DIR/write-build-provenance.py" "$ROOT_DIR" "$RESOURCES_DIR" "$CONTENTS_DIR/Info.plist" "$BUILD_CONFIGURATION"
mkdir -p "$AGENT_HELPER_CONTENTS_DIR/Resources"
cp "$RESOURCES_DIR/build-provenance.json" "$AGENT_HELPER_CONTENTS_DIR/Resources/build-provenance.json"

codesign_item "$APP_EXECUTABLE"
codesign_item "$APP_AGENT_EXECUTABLE"
codesign_item "$AGENT_HELPER_APP_DIR"
codesign_item "$APP_DIR"

printf 'codesigned-with=%s\n' "$SIGNING_IDENTITY" >&2

"$SCRIPT_DIR/verify-app.sh" >&2

printf '%s\n' "$APP_DIR"
