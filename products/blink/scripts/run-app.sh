#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Blink"
app_path="${BLINK_APP_PATH:-$repo_root/dist/$app_name.app}"
restart_existing=false
configuration=release

usage() {
  cat <<EOF
Usage: run-app.sh [--restart] [--debug]

Builds the Blink macOS app bundle (menubar-only) and launches it.

Options:
  --restart   Quit an existing Blink (this bundle) before launching
  --debug     Build and bundle the debug executable for faster iteration

Environment:
  BLINK_APP_PATH        Override output .app path (default: dist/Blink.app)
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

cd "$repo_root"

# Always pass -c explicitly: macOS bash 3.2 + `set -u` chokes on expanding
# an empty array.
swift_args=(-c "$configuration")

swift build "${swift_args[@]}" --product BlinkApp
bin_path="$(swift build "${swift_args[@]}" --show-bin-path)/BlinkApp"

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
  <string>Blink uses your local network to share notes with your paired iPhone or iPad.</string>
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




if [[ "$restart_existing" == true ]]; then
  # Precise kill: only processes running from this exact bundle path.
  pkill -f "$app_path/Contents/MacOS/$app_name" 2>/dev/null || true
fi

open -n "$app_path"

echo "Launched $app_path ($configuration)"
