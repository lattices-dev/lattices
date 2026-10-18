#!/bin/zsh
#
# Regenerates the app icon in assets with the site's brand exporter:
# AppIcon.icon, the Icon Composer document with the light and dark icons; the
# Assets.car actool compiles from it; AppIcon.icns and AppIcon.svg, the dark
# icon, as the fallback. The mark's source of truth is BlinkMark in
# apps/site/src/components/blink/BlinkMark.tsx, and the exporter renders the
# whole Blink kit from it. Run this after changing the mark, then commit the
# result — run-app.sh and the release build copy the icons, they do not build
# them. Compiling Assets.car needs Xcode.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_DIR=$(cd "$ROOT_DIR/../.." && pwd)

# The exporter's dependencies (react-dom, sharp) resolve from apps/site.
(cd "$REPO_DIR/apps/site" && bun scripts/export-brand.tsx blink) >&2

printf '%s\n' "$ROOT_DIR/assets/AppIcon.icns"
