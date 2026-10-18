#!/bin/bash
# Build a local artifact only. Never install, launch or publish it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# build.json names no voice feature, so Hudson leaves out HudsonVoice and Vox,
# even when the Lattices app build that embeds Voice turned them on.
eval "$(bun "$ROOT/../../bin/lattices-build-env.ts" shell "$ROOT/build.json")"
CONFIG="${SPEECH_BUILD_CONFIGURATION:-release}"
OUTPUT="${SPEECH_ARTIFACT_DIR:-$ROOT/.artifacts}"
IDENTITY="${SPEECH_SIGN_IDENTITY:--}"
swift build --package-path "$ROOT" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
mkdir -p "$OUTPUT"
STAGE="$(mktemp -d "$OUTPUT/.voice-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Voice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Voice" "$APP/Contents/MacOS/Voice"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# Prebuilt and committed: `bun run brand speech` in apps/site renders them from
# SpeechMark in apps/site/src/components/SpeechMark.tsx. Assets.car holds the
# light and dark icons, which CFBundleIconName picks over the .icns.
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/assets/Assets.car" "$APP/Contents/Resources/Assets.car"
# SwiftPM resource bundles load from Contents/Resources; a missing one traps on first use.
for RESOURCE in "$BIN_DIR"/*.bundle; do
    [ -d "$RESOURCE" ] || continue
    cp -R "$RESOURCE" "$APP/Contents/Resources/"
done
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [ "${SPEECH_DISTRIBUTABLE:-0}" = "1" ]; then
    bash "$ROOT/../../tools/release/verify-companion-signature.sh" "$APP"
fi
DEST="$OUTPUT/Voice.app"
if [ -e "$DEST" ]; then echo "Artifact already exists: $DEST" >&2; exit 1; fi
mv "$APP" "$DEST"
if [ "${SPEECH_CREATE_DMG:-0}" = "1" ]; then
    hdiutil create -volname Voice -srcfolder "$DEST" -ov -format UDZO "$OUTPUT/Voice.dmg"
fi
printf 'Built %s\n' "$DEST"
