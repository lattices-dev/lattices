#!/usr/bin/env bash
# Package an already signed Canvas.app for current and published legacy clients.
# The compatibility image contains a real Blink.app directory; its display name,
# executable, bundle identifier, signing identity, and data paths remain Canvas's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUNDLE="${1:?Usage: package-dmgs.sh Canvas.app output-directory}"
BUILD_DIR="${2:?Usage: package-dmgs.sh Canvas.app output-directory}"
SKIP_SIGN="${BLINK_SKIP_SIGN:-0}"
SKIP_NOTARIZE="${BLINK_SKIP_NOTARIZE:-0}"
SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${BLINK_NOTARY_PROFILE:-notarytool}"

if [[ ! -d "$BUNDLE" || -L "$BUNDLE" ]]; then
  echo "Expected a real Canvas.app bundle at $BUNDLE" >&2
  exit 1
fi
for field in CFBundleName CFBundleDisplayName CFBundleExecutable; do
  [[ "$(plutil -extract "$field" raw "$BUNDLE/Contents/Info.plist")" == "Canvas" ]] || { echo "Unexpected $field in source app" >&2; exit 1; }
done
[[ "$(plutil -extract CFBundleIdentifier raw "$BUNDLE/Contents/Info.plist")" == "dev.arach.blink" ]] || { echo "Unexpected source app identity" >&2; exit 1; }
if [[ "$SKIP_SIGN" != 1 && -z "$SIGN_IDENTITY" ]]; then
  echo "BLINK_SIGN_IDENTITY is required to package signed images" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
STAGING=""
cleanup() { [[ -z "$STAGING" ]] || rm -rf "$STAGING"; }
trap cleanup EXIT
for filename in Canvas Blink; do
  STAGING="$(mktemp -d)"
  ditto "$BUNDLE" "$STAGING/$filename.app"
  if [[ "$SKIP_SIGN" != 1 ]]; then
    bash "$ROOT/../../tools/release/verify-companion-signature.sh" "$STAGING/$filename.app"
  fi
  ln -s /Applications "$STAGING/Applications"
  image="$BUILD_DIR/$filename.dmg"
  echo "==> Packaging $filename.dmg containing $filename.app (Canvas)"
  hdiutil create -volname "$filename" -srcfolder "$STAGING" -ov -format UDZO "$image"
  rm -rf "$STAGING"
  STAGING=""
  if [[ "$SKIP_SIGN" != 1 ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$image"
    if [[ "$SKIP_NOTARIZE" != 1 ]]; then
      xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$image"
      xcrun stapler validate "$image"
      spctl --assess --type open --context context:primary-signature -v "$image"
    fi
  fi
  echo "==> Done: $image"
done
