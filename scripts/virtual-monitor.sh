#!/bin/zsh
# Local native experiment. Uses Action's persistent monitor owner and recovery.
# Build is isolated from both the everyday Lattices app and installed Action.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ACTION_DIST_DIR="$ROOT/.local/virtual-monitor-20261028/build"
PRODUCT="$ROOT/products/action"
CLI="$PRODUCT/packages/cli/src/main.ts"
WORKSPACE=monitor-experiment
case "${1:-help}" in
  build)
    "$PRODUCT/native/engine/scripts/build-app.sh"
    ;;
  start)
    if [[ ! -x "$ACTION_DIST_DIR/Action.app/Contents/MacOS/Action" ]]; then
      echo "Build first: ./scripts/virtual-monitor.sh build" >&2
      exit 1
    fi
    cd "$PRODUCT"
    bun "$CLI" layer prepare --workspace "$WORKSPACE" --width 6880 --height 1440 --return-to-mac
    bun "$CLI" layer open --workspace "$WORKSPACE" --viewport
    ;;
  show)
    cd "$PRODUCT"
    bun "$CLI" layer pip --workspace "$WORKSPACE" --viewport
    ;;
  return|close|release)
    cd "$PRODUCT"
    bun "$CLI" layer return-to-mac --workspace "$WORKSPACE"
    ;;
  status)
    cd "$PRODUCT"
    bun "$CLI" layer display-status --workspace "$WORKSPACE"
    bun "$CLI" layer status --workspace "$WORKSPACE"
    ;;
  *)
    echo 'Virtual monitor experiment (6880 × 1440, 100% scale)'
    echo '  build   Build a separate signed local Action bundle.'
    echo '  start   Connect the monitor and open an empty viewport.'
    echo '  show    Reopen the viewport for an active session.'
    echo '  return  Bring every window home, then disconnect the monitor.'
    echo '          Global shortcut: Control-Option-Command-Escape.'
    echo '  close   Alias for return (also: release).'
    echo '  status  Show the monitor and session state.'
    ;;
esac
