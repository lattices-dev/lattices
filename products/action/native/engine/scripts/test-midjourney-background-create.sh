#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)
APP_EXECUTABLE="$ROOT_DIR/native/dist/Action.app/Contents/MacOS/Action"
BUN_BIN="${BUN_BIN:-$HOME/.bun/bin/bun}"
TRACE_FILE="${ACTION_MIDJOURNEY_TRACE_FILE:-/tmp/action-midjourney-bg-create.trace}"
OUTPUT_DIR="${ACTION_MIDJOURNEY_OUTPUT_DIR:-/tmp/action-midjourney-bg-create-$(date +%Y%m%d-%H%M%S)}"
CHROME_BUNDLE_ID="${ACTION_CHROME_BG_BUNDLE_ID:-com.google.Chrome}"
TARGET_URL="${ACTION_MIDJOURNEY_URL:-https://www.midjourney.com/imagine}"
PROMPT="${ACTION_MIDJOURNEY_PROMPT:-a polished product demo frame of a tiny translucent cursor arranging warm cream mechanical keyboard switches on a moonlit desk, cinematic macro lighting, soft editorial composition}"
MOONDREAM_PYTHON="${ACTION_MOONDREAM_PYTHON:-/Users/art/dev/moondream-local-poc/.venv/bin/python}"
SHOW_OVERLAY="${ACTION_MIDJOURNEY_SHOW_OVERLAY:-0}"
USE_COMPANION="${ACTION_MIDJOURNEY_USE_COMPANION:-auto}"
COMPANION_IPC_MODULE="$ROOT_DIR/packages/runtime/src/chrome-companion-ipc.ts"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  "$SCRIPT_DIR/build-app.sh" >/dev/stderr
fi

if [[ ! -x "$BUN_BIN" ]]; then
  echo "bun was not found at $BUN_BIN" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$TRACE_FILE"

front_bundle() {
  local asn
  asn=$(lsappinfo front 2>/dev/null | awk '{print $1}' | sed 's/ASN://;s/:$//' || true)
  [[ -n "$asn" ]] || return 0
  lsappinfo info -only bundleid "ASN:$asn" 2>/dev/null \
    | sed -n 's/^"CFBundleIdentifier"="\(.*\)"$/\1/p' \
    | head -1
}

log_event() {
  local kind="$1"
  local text="$2"
  printf '%s|%s\n' "$kind" "$text" >> "$TRACE_FILE"
  printf '[%s] %s\n' "$kind" "$text"
}

overlay() {
  if [[ "$SHOW_OVERLAY" != "1" ]]; then
    return 0
  fi

  local label="$1"
  local duration_ms="$2"
  local detail="$3"
  shift 3
  "$SCRIPT_DIR/run-app-host.sh" demo-cursor-overlay \
    --duration-ms "$duration_ms" \
    --status-only true \
    --label "$label" \
    --status-detail "$detail" \
    --trace-file "$TRACE_FILE" \
    --trace-title "Midjourney background create" \
    "$@" >/dev/null 2>&1 &
}

start_action_overlay() {
  if [[ "$SHOW_OVERLAY" != "1" ]]; then
    return 0
  fi

  local label="$1"
  local duration_ms="$2"
  local detail="$3"
  shift 3
  if [[ "$TARGET_IS_FRONTMOST" == "true" ]]; then
    "$SCRIPT_DIR/run-app-host.sh" demo-cursor-overlay \
      --duration-ms "$duration_ms" \
      --label "$label" \
      --status-detail "$detail" \
      --trace-file "$TRACE_FILE" \
      --trace-title "Midjourney background create" \
      "$@" >/dev/null 2>&1 &
  else
    "$SCRIPT_DIR/run-app-host.sh" demo-cursor-overlay \
      --duration-ms "$duration_ms" \
      --status-only true \
      --label "$label" \
      --status-detail "background Chrome: $detail" \
      --trace-file "$TRACE_FILE" \
      --trace-title "Midjourney background create" >/dev/null 2>&1 &
  fi
  printf '%s\n' "$!"
}

snapshot_chrome() {
  local name="$1"
  local path="$OUTPUT_DIR/$name.json"
  "$APP_EXECUTABLE" inspect-app-ui \
    --bundle-id "$CHROME_BUNDLE_ID" \
    --max-depth 18 \
    --max-nodes 6000 > "$path"
  printf '%s\n' "$path"
}

activate_bundle() {
  local bundle_id="$1"
  [[ -n "$bundle_id" ]] || return 0
  "$APP_EXECUTABLE" activate-app --bundle-id "$bundle_id" >/dev/null 2>&1 || true
}

restore_frontmost() {
  if [[ -n "${FRONT_BEFORE:-}" && "$FRONT_BEFORE" != "$CHROME_BUNDLE_ID" ]]; then
    activate_bundle "$FRONT_BEFORE"
    sleep 0.35
  fi
}

select_midjourney_tab() {
  /usr/bin/osascript "$TARGET_URL" <<'APPLESCRIPT'
on run argv
  set targetUrl to item 1 of argv
  tell application "Google Chrome"
    repeat with windowIndex from 1 to count of windows
      set candidateWindow to window windowIndex
      repeat with tabIndex from 1 to count of tabs of candidateWindow
        set candidateTab to tab tabIndex of candidateWindow
        set candidateUrl to URL of candidateTab
        if candidateUrl starts with targetUrl or candidateUrl contains "midjourney.com/imagine" then
          set active tab index of candidateWindow to tabIndex
          set index of candidateWindow to 1
          return candidateUrl
        end if
      end repeat
    end repeat
  end tell
  error "No Midjourney Create tab found"
end run
APPLESCRIPT
}

summarize_snapshot() {
  local path="$1"
  "$BUN_BIN" - "$path" <<'BUN'
const fs = require("fs");
const nodes = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const text = (node) => [node.title, node.detail, node.value, node.identifier].filter(Boolean).join(" | ");
const window = nodes.find((node) => node.role === "AXWindow");
const urlField = nodes.find((node) => node.role === "AXTextField" && /address and search bar/i.test(text(node)));
const textArea = nodes.find((node) => node.role === "AXTextArea");
const images = nodes.filter((node) => /cdn\.midjourney\.com/i.test(text(node)) && node.frame && node.frame.height > 10);
console.log(JSON.stringify({
  nodes: nodes.length,
  windowTitle: window?.title ?? null,
  url: urlField?.value ?? null,
  textAreaFocused: textArea?.focused ?? null,
  textAreaValue: textArea?.value ?? null,
  imageRefs: images.length,
}));
BUN
}

resolve_text_area_point() {
  local tree_json="$1"
  local screen_png="$2"
  local point_json="$3"
  "$BUN_BIN" - "$tree_json" "$screen_png" "$point_json" <<'BUN'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [treePath, screenPath, pointPath] = process.argv.slice(2);
const nodes = JSON.parse(fs.readFileSync(treePath, "utf8"));
const area = nodes.find((node) => node.role === "AXTextArea" && node.frame);
if (!area) {
  throw new Error("Could not resolve Midjourney prompt AXTextArea");
}

const sips = execFileSync("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", screenPath], { encoding: "utf8" });
const widthMatch = sips.match(/pixelWidth:\s*(\d+)/);
const heightMatch = sips.match(/pixelHeight:\s*(\d+)/);
const screenWidth = widthMatch ? Number(widthMatch[1]) : 3024;
const screenHeight = heightMatch ? Number(heightMatch[1]) : 1964;
const x = Math.round(area.frame.x + Math.min(260, area.frame.width * 0.34));
const y = Math.round(screenHeight - (area.frame.y + area.frame.height / 2));
const startX = Math.max(42, Math.min(screenWidth - 80, x + 420));
const startY = Math.max(86, Math.min(screenHeight - 90, y + 220));
fs.writeFileSync(pointPath, JSON.stringify({
  area,
  overlayPoint: { x, y },
  startPoint: { x: startX, y: startY },
  screen: { width: screenWidth, height: screenHeight },
}, null, 2));
BUN
}

extract_image_refs() {
  local path="$1"
  "$BUN_BIN" - "$path" <<'BUN'
const fs = require("fs");
const nodes = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const text = (node) => [node.title, node.detail, node.value, node.identifier].filter(Boolean).join(" | ");
const refs = nodes
  .filter((node) => /cdn\.midjourney\.com/i.test(text(node)) && node.frame && node.frame.height > 10)
  .map((node) => text(node).match(/https:\/\/cdn\.midjourney\.com\/[^\s|"]+/i)?.[0])
  .filter(Boolean);
console.log([...new Set(refs)].sort().join("\n"));
BUN
}

page_contains_prompt() {
  local path="$1"
  local prompt="$2"
  "$BUN_BIN" - "$path" "$prompt" <<'BUN'
const fs = require("fs");
const [path, prompt] = process.argv.slice(2);
const nodes = JSON.parse(fs.readFileSync(path, "utf8"));
const normalize = (value) => String(value || "").toLowerCase().replace(/\s+/g, " ").trim();
const needle = normalize(prompt).slice(0, 74);
const haystack = normalize(nodes.map((node) => [node.title, node.detail, node.value].filter(Boolean).join(" ")).join(" "));
const hasPrompt = needle.length > 20 && haystack.includes(needle);
const hasRenderedCards = nodes.some((node) => {
  const text = [node.title, node.detail, node.value].filter(Boolean).join(" ");
  return /cdn\.midjourney\.com/i.test(text) && node.frame && node.frame.width > 40 && node.frame.height > 10;
});
process.exit(hasPrompt && hasRenderedCards ? 0 : 1);
BUN
}

verify_with_moondream() {
  local image_path="$1"
  local output_path="$2"
  if [[ "${ACTION_MOONDREAM_VERIFY:-1}" == "0" ]]; then
    printf '{"available":false,"skipped":true}\n' > "$output_path"
    return 1
  fi
  if [[ ! -x "$MOONDREAM_PYTHON" ]]; then
    printf '{"available":false,"error":"Moondream Python runtime not found"}\n' > "$output_path"
    return 1
  fi
  "$MOONDREAM_PYTHON" "$SCRIPT_DIR/moondream-verify-screenshot.py" "$image_path" "$PROMPT" > "$output_path"
}

companion_available() {
  "$BUN_BIN" - "$COMPANION_IPC_MODULE" <<'BUN' >/dev/null
try {
  const { chromeCompanionRequest } = await import(process.argv[2]);
  const json = await chromeCompanionRequest("/health", undefined, 900);
  process.exit(json.connected ? 0 : 1);
} catch {
  process.exit(1);
}
BUN
}

companion_rpc() {
  local method="$1"
  local output_path="$2"
  "$BUN_BIN" - "$COMPANION_IPC_MODULE" "$method" "$PROMPT" > "$output_path" <<'BUN'
const [modulePath, method, prompt] = process.argv.slice(2);
const { chromeCompanionRequest } = await import(modulePath);
const message = {
  method,
  params: {
    surface: {
      urlMatches: ["https://www.midjourney.com/imagine*"],
      createUrl: "https://www.midjourney.com/imagine",
      activate: false,
    },
  },
};

if (method === "midjourney.setPrompt" || method === "midjourney.submitPrompt") {
  message.params.prompt = prompt;
}

const response = await chromeCompanionRequest("/rpc", message);
process.stdout.write(JSON.stringify(response));
process.exit(response.ok ? 0 : 1);
BUN
}

companion_result_count() {
  local path="$1"
  "$BUN_BIN" - "$path" <<'BUN'
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const result = response.result;
if (Array.isArray(result)) {
  console.log(result.length);
} else if (Array.isArray(result?.results)) {
  console.log(result.results.length);
} else {
  console.log(0);
}
BUN
}

run_companion_flow() {
  log_event "policy" "using the private Action Chrome Companion connection"
  local before_json="$OUTPUT_DIR/companion-before.json"
  local submit_json="$OUTPUT_DIR/companion-submit.json"
  local poll_json="$OUTPUT_DIR/companion-poll.json"

  companion_rpc "midjourney.readResults" "$before_json" || return 1
  local before_count
  before_count=$(companion_result_count "$before_json")

  companion_rpc "midjourney.submitPrompt" "$submit_json" || return 1
  log_event "act" "submitted prompt through Chrome Companion DOM bridge"

  for attempt in {1..24}; do
    sleep 6
    companion_rpc "midjourney.observe" "$poll_json" || return 1
    local count
    count=$(companion_result_count "$poll_json")
    log_event "observe" "companion poll $attempt: results=$count before=$before_count"
    if [[ "$count" -gt "$before_count" ]]; then
      break
    fi
  done

  PREVIEW_IMAGE="$OUTPUT_DIR/midjourney-window.png"
  "$APP_EXECUTABLE" screenshot-app-window \
    --bundle-id "$CHROME_BUNDLE_ID" \
    --output "$PREVIEW_IMAGE" >/dev/null

  log_event "done" "captured current Midjourney Create page"
  printf 'Trace: %s\n' "$TRACE_FILE"
  printf 'Artifacts: %s\n' "$OUTPUT_DIR"
  printf 'Preview: %s\n' "$PREVIEW_IMAGE"
  printf 'Companion: %s\n' "$poll_json"
}

navigate_background() {
  log_event "act" "open Midjourney Create without activation"
  open -gj -a "Google Chrome" "$TARGET_URL" >/dev/null 2>&1 || true
  sleep 2
  select_midjourney_tab >/dev/null
  restore_frontmost
}

ensure_midjourney_surface() {
  if select_midjourney_tab >/dev/null 2>&1; then
    log_event "resolve" "selected existing Midjourney Create tab"
    restore_frontmost
    return 0
  fi

  navigate_background
}

submit_prompt_background() {
  log_event "act" "set prompt through Chrome AXTextArea without frontmost focus"
  "$APP_EXECUTABLE" set-accessibility-value \
    --bundle-id "$CHROME_BUNDLE_ID" \
    --role AXTextArea \
    --value "$PROMPT" >/dev/null
  sleep 0.25
  log_event "act" "submit prompt with process-directed Return"
  "$APP_EXECUTABLE" press-app-key --bundle-id "$CHROME_BUNDLE_ID" --key return >/dev/null
}

if ! pgrep -f "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" >/dev/null 2>&1; then
  log_event "abort" "Google Chrome is not running; refusing to launch it during background test"
  overlay "Chrome not running" 2200 "open Chrome first"
  wait || true
  exit 1
fi

FRONT_BEFORE=$(front_bundle)
TARGET_IS_FRONTMOST=false
if [[ "${FRONT_BEFORE:-}" == "$CHROME_BUNDLE_ID" ]]; then
  TARGET_IS_FRONTMOST=true
fi
log_event "observe" "frontmost before: ${FRONT_BEFORE:-unknown}"
log_event "policy" "submitting the prompt may consume Midjourney generation credits"
log_event "policy" "frontmost app should be preserved; no global typing is used"
if [[ "$SHOW_OVERLAY" == "1" ]]; then
  log_event "policy" "overlay enabled for visible dogfood capture"
else
  log_event "policy" "overlay disabled for hidden background operation"
fi
overlay "Observe" 1200 "scan Create page"

if [[ "$USE_COMPANION" != "0" ]] && companion_available; then
  if run_companion_flow; then
    exit 0
  fi
  if [[ "$USE_COMPANION" == "1" ]]; then
    log_event "abort" "Chrome Companion bridge failed and fallback was disabled"
    exit 1
  fi
  log_event "warn" "Chrome Companion bridge failed; falling back to native AX path"
elif [[ "$USE_COMPANION" == "1" ]]; then
  log_event "abort" "Chrome Companion bridge is required but not connected"
  exit 1
else
  log_event "policy" "Chrome Companion bridge not connected; using native AX fallback"
fi

ensure_midjourney_surface
BEFORE_JSON=$(snapshot_chrome "01-before")
log_event "resolve" "before: $(summarize_snapshot "$BEFORE_JSON")"
if ! grep -qi "midjourney.com" "$BEFORE_JSON" || ! grep -qi "AXTextArea" "$BEFORE_JSON"; then
  log_event "abort" "Midjourney Create tab is not exposing an AXTextArea; refusing to type globally"
  exit 1
fi

BEFORE_REFS="$OUTPUT_DIR/before-refs.txt"
extract_image_refs "$BEFORE_JSON" > "$BEFORE_REFS"

submit_prompt_background

AFTER_TYPE_JSON=$(snapshot_chrome "02-after-type")
log_event "observe" "after submit: $(summarize_snapshot "$AFTER_TYPE_JSON")"

RESULT_JSON=""
RESULT_REFS="$OUTPUT_DIR/result-refs.txt"
NEW_REF=""
for attempt in {1..24}; do
  sleep 6
  CANDIDATE_JSON=$(snapshot_chrome "03-poll-$attempt")
  extract_image_refs "$CANDIDATE_JSON" > "$RESULT_REFS"
  NEW_REF=$(comm -13 "$BEFORE_REFS" "$RESULT_REFS" | head -1 || true)
  log_event "observe" "poll $attempt: $(summarize_snapshot "$CANDIDATE_JSON")"
  if [[ -n "$NEW_REF" ]] || page_contains_prompt "$CANDIDATE_JSON" "$PROMPT"; then
    RESULT_JSON="$CANDIDATE_JSON"
    break
  fi
done

PREVIEW_IMAGE="$OUTPUT_DIR/midjourney-window.png"
"$APP_EXECUTABLE" screenshot-app-window \
  --bundle-id "$CHROME_BUNDLE_ID" \
  --output "$PREVIEW_IMAGE" >/dev/null

MOONDREAM_JSON="$OUTPUT_DIR/moondream.json"
MOONDREAM_RENDERED=false
if verify_with_moondream "$PREVIEW_IMAGE" "$MOONDREAM_JSON"; then
  MOONDREAM_RENDERED=true
  log_event "verify" "Moondream sees rendered result"
else
  log_event "verify" "Moondream did not confirm rendered result"
fi

if [[ -n "$NEW_REF" ]]; then
  log_event "done" "new image detected: $NEW_REF"
  overlay "Rendered" 5500 "new image detected" --preview-image "$PREVIEW_IMAGE"
elif [[ "$MOONDREAM_RENDERED" == "true" ]]; then
  log_event "done" "screen capture verified by Moondream"
  overlay "Rendered" 5500 "Moondream verified screenshot" --preview-image "$PREVIEW_IMAGE"
elif [[ -n "$RESULT_JSON" ]]; then
  log_event "done" "rendered prompt detected in Create page"
  overlay "Rendered" 5500 "prompt visible with image cards" --preview-image "$PREVIEW_IMAGE"
else
  log_event "warn" "no new image detected before timeout"
  overlay "Preview" 5500 "captured current Create page" --preview-image "$PREVIEW_IMAGE"
fi

wait || true
FRONT_AFTER=$(front_bundle)
if [[ -n "${FRONT_BEFORE:-}" && -n "${FRONT_AFTER:-}" && "$FRONT_BEFORE" == "$FRONT_AFTER" ]]; then
  log_event "done" "frontmost preserved: $FRONT_AFTER"
else
  log_event "warn" "frontmost changed: ${FRONT_BEFORE:-unknown} -> ${FRONT_AFTER:-unknown}"
  if [[ -n "${FRONT_BEFORE:-}" ]]; then
    "$APP_EXECUTABLE" activate-app --bundle-id "$FRONT_BEFORE" >/dev/null || true
  fi
fi

printf 'Trace: %s\n' "$TRACE_FILE"
printf 'Artifacts: %s\n' "$OUTPUT_DIR"
printf 'Preview: %s\n' "$PREVIEW_IMAGE"
printf 'Moondream: %s\n' "$MOONDREAM_JSON"
if [[ -n "$NEW_REF" ]]; then
  printf 'New image: %s\n' "$NEW_REF"
elif [[ "$MOONDREAM_RENDERED" == "true" ]]; then
  printf 'Rendered: Moondream verified screenshot\n'
elif [[ -n "$RESULT_JSON" ]]; then
  printf 'Rendered: prompt visible with image cards\n'
else
  exit 1
fi
