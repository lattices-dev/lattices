#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$ROOT/apps/mac"
DIST_DIR="$ROOT/dist"
RELEASE_REPO="${LATTICES_RELEASE_REPO:-lattices-dev/lattices}"
RELEASE_TARGET="${LATTICES_RELEASE_TARGET:-main}"
VERSION="${LATTICES_VERSION:-$(node -p "require(process.argv[1]).version" "$ROOT/package.json" 2>/dev/null || echo '0.1.0')}"
TAG="v${VERSION}"
MODE="dmg"
DRY_RUN=0
UPLOAD_TMP=""

# The public release feed carries the free tier only. Bundle builds come from
# `LATTICES_TIER=bundle bun bin/lattices-app.ts build` and never ship here.
if [ "${LATTICES_TIER:-free}" != "free" ]; then
    echo "Error: ship.sh publishes the free tier only (LATTICES_TIER=$LATTICES_TIER)" >&2
    exit 1
fi
export LATTICES_TIER=free

cleanup() {
    if [ -n "$UPLOAD_TMP" ] && [ -d "$UPLOAD_TMP" ]; then
        rm -rf "$UPLOAD_TMP"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./tools/release/ship.sh [dmg|bin] [--dry-run]

Build the free-tier release asset and upload it to the public GitHub release
feed. Bundle builds never ship through this script.

Modes:
  dmg   Build/sign/notarize dist/Lattices.dmg and upload it (default)
  bin   Build dist/Lattices-macos-arm64 and upload it
EOF
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Missing required command: $1" >&2
        exit 1
    fi
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY RUN:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

release_notes_file() {
    local notes_path="$1"

    cat > "$notes_path" <<EOF
Release $VERSION

Download and install Lattices for Mac.
EOF
}

build_binary() {
    local binary asset
    binary="$APP_DIR/.build/release/Lattices"
    asset="$DIST_DIR/Lattices-macos-arm64"

    echo "==> Building release binary (arm64)..."
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY RUN: (cd %q && eval "$(bun bin/lattices-build-env.ts shell)" && swift build -c release)\n' "$APP_DIR"
        printf 'DRY RUN: mkdir -p %q && cp %q %q && chmod +x %q\n' "$DIST_DIR" "$binary" "$asset" "$asset"
        return 0
    fi
    (
        eval "$(bun "$ROOT/bin/lattices-build-env.ts" shell)"
        cd "$APP_DIR"
        swift build -c release
    )

    mkdir -p "$DIST_DIR"
    cp "$binary" "$asset"
    chmod +x "$asset"
}

while [ $# -gt 0 ]; do
    case "$1" in
        dmg|bin|binary)
            MODE="$1"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

need_cmd gh

cd "$ROOT"

case "$MODE" in
    dmg)
        ASSET_PATH="$DIST_DIR/Lattices.dmg"
        echo "==> Building DMG release asset..."
        run bash "$SCRIPT_DIR/build-dmg.sh" "$VERSION"
        ;;
    bin|binary)
        need_cmd swift
        ASSET_PATH="$DIST_DIR/Lattices-macos-arm64"
        build_binary
        ;;
esac

if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$ASSET_PATH" ]; then
    echo "Error: Expected asset not found: $ASSET_PATH" >&2
    exit 1
fi

NOTES_PATH=""
if [ "$DRY_RUN" -eq 0 ]; then
    UPLOAD_TMP="$(mktemp -d)"
    NOTES_PATH="$UPLOAD_TMP/release-notes.md"
    release_notes_file "$NOTES_PATH"
else
    NOTES_PATH="\$RUNNER_TEMP/release-notes.md"
fi

UPLOAD_PATHS=("$ASSET_PATH")
if [ "$MODE" = "dmg" ]; then
    VERSIONED_DMG_PATH="${UPLOAD_TMP:-$DIST_DIR}/Lattices-$VERSION.dmg"
    if [ "$DRY_RUN" -eq 0 ]; then
        cp "$ASSET_PATH" "$VERSIONED_DMG_PATH"
    else
        run cp "$ASSET_PATH" "$VERSIONED_DMG_PATH"
    fi
    UPLOAD_PATHS+=("$VERSIONED_DMG_PATH")
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> DRY RUN: would create or update GitHub release $TAG in $RELEASE_REPO"
elif gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    echo "==> Updating GitHub release $TAG in $RELEASE_REPO..."
    run gh release edit "$TAG" --repo "$RELEASE_REPO" --title "Lattices $VERSION" --notes-file "$NOTES_PATH"
else
    echo "==> Creating GitHub release $TAG in $RELEASE_REPO..."
    run gh release create "$TAG" --repo "$RELEASE_REPO" --target "$RELEASE_TARGET" --title "Lattices $VERSION" --notes-file "$NOTES_PATH"
fi

echo "==> Uploading release asset(s)..."
run gh release upload "$TAG" "${UPLOAD_PATHS[@]}" --repo "$RELEASE_REPO" --clobber

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> Dry run complete for $TAG in $RELEASE_REPO"
else
    echo "==> Shipped $TAG to $RELEASE_REPO"
fi
