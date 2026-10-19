#!/usr/bin/env bash
# Publish preverified Canvas and legacy Blink assets from one source commit.
# Usage: publish-assets.sh [--dry-run] version owner/repo source-sha asset-directory
set -euo pipefail
DRY_RUN=0
if [[ "${1:-}" == --dry-run ]]; then DRY_RUN=1; shift; fi
VERSION="${1:?version required}"
REPO="${2:?owner/repo required}"
SOURCE_SHA="${3:?source commit required}"
ASSET_DIR="${4:?asset directory required}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]] || { echo "Expected a full source commit SHA" >&2; exit 1; }
TAGS=("canvas-v$VERSION" "blink-v$VERSION")

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Would publish ${TAGS[0]} and ${TAGS[1]} at $SOURCE_SHA in $REPO"
  echo "${TAGS[0]}: Canvas.dmg (Canvas.app), Canvas-$VERSION.dmg, canvas-macos-arm64, Blink.dmg, blink-macos-arm64"
  echo "${TAGS[1]}: Blink.dmg (Blink.app), Blink-$VERSION.dmg, blink-macos-arm64"
  exit 0
fi
for asset in Canvas.dmg Blink.dmg canvas-macos-arm64 blink-macos-arm64; do
  [[ -f "$ASSET_DIR/$asset" && ! -L "$ASSET_DIR/$asset" ]] || { echo "Missing release asset $asset" >&2; exit 1; }
done
cmp "$ASSET_DIR/canvas-macos-arm64" "$ASSET_DIR/blink-macos-arm64"
[[ "$("$ASSET_DIR/canvas-macos-arm64" --version)" == "$VERSION" ]] || { echo "CLI version does not match $VERSION" >&2; exit 1; }

# Validate both tag identities before publishing either release. A tag-only
# preexisting ref is checked too, not just refs with a GitHub Release attached.
for tag in "${TAGS[@]}"; do
  existing_ref="$(gh api "repos/$REPO/git/matching-refs/tags/$tag" --jq ".[] | select(.ref == \"refs/tags/$tag\") | .ref")"
  if [[ -n "$existing_ref" ]]; then
    existing_sha="$(gh api "repos/$REPO/commits/$tag" --jq .sha)"
    [[ "$existing_sha" == "$SOURCE_SHA" ]] || { echo "Refusing to change $tag at $existing_sha (expected $SOURCE_SHA)" >&2; exit 1; }
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ASSET_DIR/Canvas.dmg" "$TMP/Canvas-$VERSION.dmg"
cp "$ASSET_DIR/Blink.dmg" "$TMP/Blink-$VERSION.dmg"
for tag in "${TAGS[@]}"; do
  notes="$TMP/$tag.md"
  if [[ "$tag" == canvas-* ]]; then
    assets=("$ASSET_DIR/Canvas.dmg" "$TMP/Canvas-$VERSION.dmg" "$ASSET_DIR/canvas-macos-arm64" "$ASSET_DIR/Blink.dmg" "$ASSET_DIR/blink-macos-arm64")
    title="Canvas $VERSION"
    cat > "$notes" <<NOTES
Canvas $VERSION

Download **Canvas.dmg** for Canvas.app. Install or update the compatible CLI with:

    npm install -g @arach/blink

Both \`canvas\` and \`blink\` work. Existing notes, settings, and the app identity remain unchanged.
Update the app and CLI together to use this release's stricter private IPC permissions.
The separate **Blink.dmg** contains the same signed Canvas app under the Blink.app filename required by older installers.

Source: https://github.com/$REPO/commit/$SOURCE_SHA
NOTES
  else
    assets=("$ASSET_DIR/Blink.dmg" "$TMP/Blink-$VERSION.dmg" "$ASSET_DIR/blink-macos-arm64")
    title="Canvas $VERSION — Blink compatibility"
    cat > "$notes" <<NOTES
Canvas $VERSION for existing Blink installers.

**Blink.dmg** contains a real Blink.app directory with Canvas's display name and the unchanged dev.arach.blink identity. This keeps older \`blink app update\` commands working and preserves notes and settings.

Update the app and CLI together to use this release's stricter private IPC permissions.

For the canonical Canvas.app filename and both CLI names, install \`@arach/blink@$VERSION\` and run \`canvas app update\`.

Source: https://github.com/$REPO/commit/$SOURCE_SHA
Canonical release: https://github.com/$REPO/releases/tag/canvas-v$VERSION
NOTES
  fi
  release_id="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")"
  args=(--repo "$REPO" --latest=false --title "$title" --notes-file "$notes")
  [[ "$VERSION" != *-* ]] || args+=(--prerelease)
  if [[ -n "$release_id" ]]; then
    gh release upload "$tag" "${assets[@]}" --repo "$REPO" --clobber
    gh release edit "$tag" "${args[@]}"
  else
    gh release create "$tag" "${assets[@]}" --target "$SOURCE_SHA" "${args[@]}"
  fi
  actual_sha="$(gh api "repos/$REPO/commits/$tag" --jq .sha)"
  [[ "$actual_sha" == "$SOURCE_SHA" ]] || { echo "Published $tag resolved to unexpected commit $actual_sha" >&2; exit 1; }
done
