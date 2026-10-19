#!/usr/bin/env bash
# Build the release assets and publish them to a GitHub release on lattices-dev/lattices.
# Uploads the signed+notarized Canvas.dmg (human download) and the canvas CLI
# binary (canvas-macos-arm64). The npm package ships its own copy of the CLI.
#
#   ./tools/release/ship.sh [--dry-run [--skip-dmg]]
#
# Env:
#   BLINK_RELEASE_REPO    default: lattices-dev/lattices
#   BLINK_RELEASE_TARGET  remote ref local HEAD must match (default: main)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$ROOT/dist"
REPO="${BLINK_RELEASE_REPO:-lattices-dev/lattices}"
TARGET="${BLINK_RELEASE_TARGET:-main}"
VERSION="${BLINK_VERSION:-$(node -p "require(process.argv[1]).version" "$ROOT/packages/npm/package.json" 2>/dev/null || echo '2.0.0')}"
TAG="canvas-v${VERSION}"
DRY_RUN=0
SKIP_DMG=0
run() {
    if [ "$DRY_RUN" -eq 1 ]; then printf 'DRY RUN:'; printf ' %q' "$@"; printf '\n'; return 0; fi
    "$@"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --skip-dmg) SKIP_DMG=1 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_DMG" -eq 1 ]; then
    echo "Error: --skip-dmg is only supported with --dry-run; publication requires freshly verified images." >&2
    exit 1
fi

command -v gh >/dev/null || { echo "Error: gh not found" >&2; exit 1; }
cd "$ROOT"

SOURCE_SHA="$(git rev-parse HEAD)"

if [ "$DRY_RUN" -eq 0 ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Error: tracked changes are present; release assets must come from a clean commit." >&2
        exit 1
    fi
    UNTRACKED_INPUTS="$(git ls-files --others --exclude-standard -- \
        Sources Package.swift Package.resolved assets Config web/editor packages/npm tools/release)"
    if [ -n "$UNTRACKED_INPUTS" ]; then
        echo "Error: untracked release inputs are present:" >&2
        printf '  %s\n' "$UNTRACKED_INPUTS" >&2
        exit 1
    fi
    if [ "${BLINK_SKIP_SIGN:-0}" = "1" ]; then
        echo "Error: refusing to publish release assets with BLINK_SKIP_SIGN=1." >&2
        exit 1
    fi
    if [ "${BLINK_SKIP_NOTARIZE:-0}" = "1" ]; then
        echo "Error: refusing to publish release assets with BLINK_SKIP_NOTARIZE=1." >&2
        exit 1
    fi

    REMOTE_SHA="$(gh api "repos/$REPO/commits/$TARGET" --jq .sha 2>/dev/null || true)"
    if [ -z "$REMOTE_SHA" ]; then
        echo "Error: could not resolve release target '$TARGET' in $REPO." >&2
        exit 1
    fi
    if [ "$SOURCE_SHA" != "$REMOTE_SHA" ]; then
        echo "Error: local HEAD $SOURCE_SHA does not match $REPO:$TARGET ($REMOTE_SHA)." >&2
        echo "Push or check out the intended release commit before shipping." >&2
        exit 1
    fi
fi

# CLI binary (also what the npm package embeds).
echo "==> Building canvas CLI asset..."
run bash "$SCRIPT_DIR/build-cli.sh"
CLI_ASSET="$DIST_DIR/canvas-macos-arm64"
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$DIST_DIR"
    cp "$ROOT/packages/npm/dist/canvas" "$CLI_ASSET"
fi
if [ "$DRY_RUN" -eq 0 ]; then cp "$CLI_ASSET" "$DIST_DIR/blink-macos-arm64"; fi

# Signed + notarized DMG (the human download).
if [ "$SKIP_DMG" -eq 0 ]; then
    echo "==> Building DMG asset..."
    run bash "$SCRIPT_DIR/build-dmg.sh" "$VERSION"

fi

# Publish both release channels at the same source commit. Already-published
# 2.2.0 installers only query blink-v2.* and require Blink.app in Blink.dmg.
if [ "$DRY_RUN" -eq 1 ]; then
    bash "$SCRIPT_DIR/publish-assets.sh" --dry-run "$VERSION" "$REPO" "$SOURCE_SHA" "$DIST_DIR"
else
    bash "$SCRIPT_DIR/publish-assets.sh" "$VERSION" "$REPO" "$SOURCE_SHA" "$DIST_DIR"
fi
