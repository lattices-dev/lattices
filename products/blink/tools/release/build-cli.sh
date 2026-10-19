#!/usr/bin/env bash
# Build (and sign) the `canvas` CLI (with the `blink` alias) binary into the npm package's dist/ so it
# ships in the tarball. Run by the npm `prepack` hook and by ship.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$ROOT/packages/npm/dist"
EXPECTED_VERSION="${BLINK_VERSION:-$(node -p "require(process.argv[1]).version" "$ROOT/packages/npm/package.json")}"

SKIP_SIGN="${BLINK_SKIP_SIGN:-0}"

default_sign_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([A-F0-9]\{40\}\)[[:space:]]*"Developer ID Application:[^"]*".*/\1/p' \
        | head -n 1
}
SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:-$(default_sign_identity || true)}"

echo "==> Building canvas CLI (release)..."
cd "$ROOT"
# The CLI target does not link Hudson, but SwiftPM still resolves the manifest's
# pinned Hudson revision. CI therefore needs HUDSON_READ_TOKEN; local Hudson
# development can opt into BLINK_HUDSON_SOURCE=path with BLINK_HUDSON_PATH.
swift build -c release --product canvas
BIN_PATH="$(swift build -c release --product canvas --show-bin-path)/canvas"

mkdir -p "$OUT_DIR"
cp "$BIN_PATH" "$OUT_DIR/canvas"
chmod +x "$OUT_DIR/canvas"

if [ "$SKIP_SIGN" = "1" ]; then
    echo "==> Skipping CLI signing (BLINK_SKIP_SIGN=1)"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing canvas CLI ($SIGN_IDENTITY)..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT_DIR/canvas"
    codesign --verify --strict --verbose=2 "$OUT_DIR/canvas"
else
    echo "Error: no Developer ID Application identity found." >&2
    echo "Set BLINK_SIGN_IDENTITY, or use BLINK_SKIP_SIGN=1 only for a local smoke build." >&2
    exit 1
fi

echo "==> canvas CLI at $OUT_DIR/canvas"
ACTUAL_VERSION="$("$OUT_DIR/canvas" --version)"
echo "$ACTUAL_VERSION"
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "Error: CLI version $ACTUAL_VERSION does not match package version $EXPECTED_VERSION." >&2
    exit 1
fi

# Preserve the old binary name byte-for-byte, including its signature.
cp "$OUT_DIR/canvas" "$OUT_DIR/blink"
