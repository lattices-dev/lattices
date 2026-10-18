#!/usr/bin/env bash
# Build a signed + notarized Blink.dmg. Mirrors scripts/run-app.sh's bundle
# assembly (BlinkApp -> Blink.app/Contents/MacOS/Blink + editor.html), then
# signs with the hardened runtime, wraps in a DMG, notarizes, and staples.
#
#   ./tools/release/build-dmg.sh [version]
#
# Env:
#   BLINK_SIGN_IDENTITY   Developer ID Application SHA-1/name (auto-detected)
#   BLINK_NOTARY_PROFILE  notarytool keychain profile (default: notarytool)
#   BLINK_SKIP_SIGN=1     unsigned local smoke build
#   BLINK_SKIP_NOTARIZE=1 sign but don't notarize
#   BLINK_ARTIFACT_DIR    output directory (default: products/blink/dist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BLINK_ARTIFACT_DIR:-$ROOT/dist}"
APP_NAME="Blink"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$SCRIPT_DIR/Blink.entitlements"
BUNDLE_ID="dev.arach.blink"
VERSION="${1:-$(node -p "require(process.argv[1]).version" "$ROOT/packages/npm/package.json" 2>/dev/null || echo '2.0.0')}"
MARKETING_VERSION="${VERSION%%-*}"
BUNDLE_VERSION="$MARKETING_VERSION"
if [[ "$VERSION" =~ -alpha\.([0-9]+)$ ]]; then
    BUNDLE_VERSION="${MARKETING_VERSION}a${BASH_REMATCH[1]}"
elif [[ "$VERSION" =~ -beta\.([0-9]+)$ ]]; then
    BUNDLE_VERSION="${MARKETING_VERSION}b${BASH_REMATCH[1]}"
elif [[ "$VERSION" =~ -rc\.([0-9]+)$ ]]; then
    BUNDLE_VERSION="${MARKETING_VERSION}fc${BASH_REMATCH[1]}"
fi

SKIP_SIGN="${BLINK_SKIP_SIGN:-0}"
SKIP_NOTARIZE="${BLINK_SKIP_NOTARIZE:-0}"
NOTARY_PROFILE="${BLINK_NOTARY_PROFILE:-notarytool}"

default_sign_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([A-F0-9]\{40\}\)[[:space:]]*"Developer ID Application:[^"]*".*/\1/p' \
        | head -n 1
}
SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:-$(default_sign_identity || true)}"

if [ "$SKIP_SIGN" != "1" ] && [ -z "$SIGN_IDENTITY" ]; then
    echo "Error: no Developer ID Application identity found." >&2
    echo "Set BLINK_SIGN_IDENTITY, or run with BLINK_SKIP_SIGN=1 for an unsigned DMG." >&2
    exit 1
fi

echo "==> Building Blink v$VERSION (release)"

# The note panels load this bundle from Resources; build it if it's stale/missing.
EDITOR_HTML="$ROOT/web/editor/dist/editor.html"
if [ ! -f "$EDITOR_HTML" ]; then
    echo "==> Building editor bundle..."
    (cd "$ROOT/web/editor" && bun install && bun run build)
fi

cd "$ROOT"
swift build -c release --product BlinkApp
BIN_PATH="$(swift build -c release --product BlinkApp --show-bin-path)/BlinkApp"

echo "==> Assembling $APP_NAME.app"
mkdir -p "$BUILD_DIR"
# Preserve sibling release assets (notably blink-macos-arm64, which ship.sh
# builds before the DMG). Only replace the outputs owned by this script.
rm -rf "$BUNDLE" "$DMG_PATH"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundles (Hudson assets, etc.) sit beside the binary.
for resource_bundle in "$(dirname "$BIN_PATH")"/*.bundle; do
    [ -e "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$BUNDLE/Contents/Resources/$(basename "$resource_bundle")"
done
cp "$EDITOR_HTML" "$BUNDLE/Contents/Resources/editor.html"
ICON="$ROOT/assets/AppIcon.icns"
[ -f "$ICON" ] && cp "$ICON" "$BUNDLE/Contents/Resources/AppIcon.icns"
# The light and dark icons, which CFBundleIconName picks over the .icns.
[ -f "$ROOT/assets/Assets.car" ] && cp "$ROOT/assets/Assets.car" "$BUNDLE/Contents/Resources/Assets.car"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUNDLE_VERSION}</string>
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

if [ "$SKIP_SIGN" = "1" ]; then
    echo "==> Skipping signing (BLINK_SKIP_SIGN=1)"
else
    echo "==> Signing (hardened runtime)"
    # Inner Mach-O first, then the bundle — more reliable than --deep.
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" \
        "$BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" \
        "$BUNDLE"
    bash "$ROOT/../../tools/release/verify-companion-signature.sh" "$BUNDLE"
fi

echo "==> Creating DMG"
DMG_STAGING="$(mktemp -d)"
cp -R "$BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING"
[ "$SKIP_SIGN" = "1" ] || codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

if [ "$SKIP_NOTARIZE" = "1" ] || [ "$SKIP_SIGN" = "1" ]; then
    echo "==> Skipping notarization"
else
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling"
    xcrun stapler staple "$DMG_PATH"
fi

echo ""
echo "==> Done: $DMG_PATH"
ls -lh "$DMG_PATH"
[ "$SKIP_SIGN" = "1" ] || spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true
