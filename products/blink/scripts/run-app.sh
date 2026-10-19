#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Canvas"
app_path="${CANVAS_APP_PATH:-${BLINK_APP_PATH:-$repo_root/dist/$app_name.app}}"
restart_existing=false
configuration=release
launch_app=true

usage() {
  cat <<EOF
Usage: run-app.sh [--restart] [--debug] [--no-launch]

Builds the Canvas macOS app bundle (menubar-only) and launches it.

Options:
  --restart   Quit an existing Canvas (this bundle) before launching
  --no-launch Build the bundle without launching it
  --debug     Build and bundle the debug executable for faster iteration

Environment:
  CANVAS_APP_PATH       Override output .app path (default: dist/Canvas.app)
  BLINK_APP_PATH        Legacy fallback for CANVAS_APP_PATH
  BLINK_HUDSON_SOURCE   "git" (default, pinned revision) or "path"
  BLINK_HUDSON_PATH     Local Hudson checkout used when source is "path"
                        (default: ../../../hudson from products/blink)
  BLINK_SIGN_IDENTITY   Code-signing identity for the local bundle. Defaults to
                        a "Blink Dev" certificate if one exists. A stable
                        identity stops macOS re-prompting for the login password
                        on every rebuild (Keychain ACLs key off code identity).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart) restart_existing=true; shift ;;
    --debug) configuration=debug; shift ;;
    --no-launch) launch_app=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

cd "$repo_root"

# Always pass -c explicitly: macOS bash 3.2 + `set -u` chokes on expanding
# an empty array.
swift_args=(-c "$configuration")

swift build "${swift_args[@]}" --product CanvasApp
bin_path="$(swift build "${swift_args[@]}" --show-bin-path)/CanvasApp"

if [[ -e "$app_path" || -L "$app_path" ]]; then
  existing_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -L "$app_path" || "$existing_id" != "dev.arach.blink" ]]; then
    echo "Refusing to replace an unrelated app at $app_path" >&2
    exit 1
  fi
fi
# Quit through AppKit so asynchronous note saves can finish. Never signal the app.
running_product_paths() {
  /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.runningApplications.js.filter(a => ObjC.unwrap(a.bundleIdentifier) === "dev.arach.blink").map(a => ObjC.unwrap(a.bundleURL.path)).join("\n")'
}
running_paths="$(running_product_paths)"
if [[ "$restart_existing" == true && "$launch_app" == true ]]; then
  if [[ -n "$running_paths" ]]; then
    /usr/bin/osascript <<'APPLESCRIPT'
with timeout of 60 seconds
  tell application id "dev.arach.blink" to quit
end timeout
APPLESCRIPT
    for attempt in {1..120}; do
      [[ -z "$(running_product_paths)" ]] && break
      sleep 0.25
    done
    if [[ -n "$(running_product_paths)" ]]; then
      echo "Canvas is still saving or declined to quit; leaving its bundle unchanged." >&2
      exit 1
    fi
  fi
elif [[ -n "$running_paths" ]] && printf '%s\n' "$running_paths" | /usr/bin/grep -Fxq "$app_path"; then
  echo "Canvas is running from $app_path; use --restart to save and quit before replacing it." >&2
  exit 1
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path" "$app_path/Contents/MacOS/$app_name"
chmod +x "$app_path/Contents/MacOS/$app_name"
for resource_bundle in "$(dirname "$bin_path")"/*.bundle; do
  [[ -e "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")"
done

icon="$repo_root/assets/AppIcon.icns"
if [[ -f "$icon" ]]; then
  cp "$icon" "$app_path/Contents/Resources/AppIcon.icns"
fi
# The light and dark icons, which CFBundleIconName picks over the .icns.
if [[ -f "$repo_root/assets/Assets.car" ]]; then
  cp "$repo_root/assets/Assets.car" "$app_path/Contents/Resources/Assets.car"
fi

# Editor web bundle (built separately: cd web/editor && bun run build).
editor_html="$repo_root/web/editor/dist/editor.html"
if [[ -f "$editor_html" ]]; then
  cp "$editor_html" "$app_path/Contents/Resources/editor.html"
else
  echo "warning: web/editor/dist/editor.html missing — note panels will not load an editor" >&2
fi

# Keep local bundles truthful: the same package version drives the CLI, npm,
# releases, and the in-panel build signature.
package_version="$(bun -p 'require("./packages/npm/package.json").version')"
marketing_version="${package_version%%-*}"

cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIdentifier</key>
  <string>dev.arach.blink</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${app_name}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${marketing_version}</string>
  <key>CFBundleVersion</key>
  <string>${marketing_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Canvas uses your local network to share notes with your paired iPhone or iPad.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_blink-notes._tcp</string>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Keychain ACLs bind to designated requirement + bundle id. Prefer Developer
# ID (or BLINK_SIGN_IDENTITY) so rebuilds keep one identity. If none is
# available, launch unsigned and warn — agents without a cert can still run.
sign_identity="${BLINK_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([A-F0-9]\{40\}\)[[:space:]]*"Developer ID Application:[^"]*".*/\1/p' \
      | head -n 1
  )"
fi
entitlements="$repo_root/tools/release/Blink.entitlements"
if [[ -n "$sign_identity" && -f "$entitlements" ]]; then
  sign_bundle() {
    local bundle="$1"
    local binary="$bundle/Contents/MacOS/$app_name"
    codesign --force --options runtime --timestamp \
      --entitlements "$entitlements" --sign "$sign_identity" \
      "$binary"
    codesign --force --options runtime --timestamp \
      --entitlements "$entitlements" --identifier "dev.arach.blink" --sign "$sign_identity" \
      "$bundle"
    codesign --verify --strict --deep "$bundle"
  }
  if sign_bundle "$app_path"; then
    echo "Signed $app_path as \"$sign_identity\""
  else
    echo "warning: codesign as \"$sign_identity\" failed — Keychain may re-prompt" >&2
  fi
elif [[ -n "$sign_identity" ]]; then
  echo "warning: missing entitlements at $entitlements — launched unsigned" >&2
else
  echo "warning: no Developer ID / BLINK_SIGN_IDENTITY — launched unsigned; Keychain will re-prompt each rebuild" >&2
fi


if [[ "$launch_app" == true ]]; then
  open -n "$app_path"
  echo "Launched $app_path ($configuration)"
else
  echo "Built $app_path ($configuration)"
fi
