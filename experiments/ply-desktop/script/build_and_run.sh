#!/usr/bin/env bash
set -euo pipefail

PLY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLY_MODE="${1:-run}"
PLY_BUNDLE="$PLY_ROOT/dist/Ply.app"
PLY_REPOSITORY="$(cd "$PLY_ROOT/../.." && pwd)"
PLY_BUN="$(command -v bun)"

# Compile before stopping the previous preview.
swift build --package-path "$PLY_ROOT"
PLY_BIN="$(swift build --package-path "$PLY_ROOT" --show-bin-path)/PlyDesktop"
mkdir -p "$PLY_BUNDLE/Contents/MacOS" "$PLY_BUNDLE/Contents/Resources"
if [[ "$PLY_MODE" != "--build-only" ]]; then pkill -x PlyDesktop >/dev/null 2>&1 || true; fi
cp "$PLY_BIN" "$PLY_BUNDLE/Contents/MacOS/PlyDesktop"
cp "$PLY_ROOT/Sources/PlyDesktop/Resources/ply-desktop-v1.png" "$PLY_BUNDLE/Contents/Resources/"
cat > "$PLY_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PlyDesktop</string>
<key>CFBundleIdentifier</key><string>dev.arach.lattices.ply-preview</string>
<key>CFBundleName</key><string>Ply</string>
<key>CFBundleDisplayName</key><string>Ply</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# LaunchServices does not inherit a login shell PATH. Record this checkout's
# exact CLI and Bun paths; plist tooling safely encodes spaces and XML characters.
/usr/bin/plutil -insert PlyRepositoryRoot -string "$PLY_REPOSITORY" "$PLY_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert PlyBunPath -string "$PLY_BUN" "$PLY_BUNDLE/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$PLY_BUNDLE"

case "$PLY_MODE" in
  run) /usr/bin/open -n "$PLY_BUNDLE" ;;
  --build-only) printf '%s\n' "$PLY_BUNDLE" ;;
  --verify) /usr/bin/open -n "$PLY_BUNDLE"; sleep 1; pgrep -x PlyDesktop >/dev/null ;;
  --self-test)
    printf '{}\n' > "$PLY_ROOT/dist/self-check.json"
    /usr/bin/open -n -W "$PLY_BUNDLE" --args --self-test "$PLY_ROOT/dist/self-check.json"
    cat "$PLY_ROOT/dist/self-check.json"
    [[ "$(/usr/bin/plutil -extract passed raw -o - "$PLY_ROOT/dist/self-check.json")" == "true" ]]
    ;;
  --logs|--telemetry)
    /usr/bin/open -n "$PLY_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.arach.lattices.ply-preview"'
    ;;
  --debug) /usr/bin/lldb -- "$PLY_BUNDLE/Contents/MacOS/PlyDesktop" ;;
  *) printf 'usage: %s [run|--build-only|--verify|--self-test|--logs|--telemetry|--debug]\n' "$0" >&2; exit 2 ;;
esac
