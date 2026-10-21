# @arach/pi-lattices

Pi extension that exposes the local Lattices macOS daemon as typed `lattices_*`
tools. It wraps Lattices' existing API. Version 0.2.0 uses private IPC with Lattices 0.15.1. It
does **not** bundle `cua-driver`, replace the Lattices daemon, or silently enable
browser automation.

## Requirements

- macOS with the extension and Lattices app built from matching source.
- The Lattices menu bar app running so the daemon is available:

```bash
lattices app
```

If the daemon is not reachable, every tool returns a friendly Pi tool error with
this startup command instead of throwing during tool registration.

## Install

Local development from the Lattices repo:

```bash
pi install ./packages/pi-lattices --local
```

After the package is published:

```bash
pi install npm:@arach/pi-lattices
```

Restart Pi after installing so the extension can register tools on session start.

## Tools

All tools use the `lattices_` prefix.

### Read/discovery

| Tool | Daemon method |
| --- | --- |
| `lattices_status` | `daemon.status` |
| `lattices_api_schema` | `api.schema` |
| `lattices_windows_list` | `windows.list` |
| `lattices_windows_search` | `windows.search` |
| `lattices_window_get` | `windows.get` |
| `lattices_runs_list` | `runs.list` |
| `lattices_runs_get` | `runs.get` |
| `lattices_ocr_snapshot` | `ocr.snapshot` |
| `lattices_ocr_search` | `ocr.search` |

### Mutations / computer use

| Tool | Daemon method | Safety note |
| --- | --- | --- |
| `lattices_computer_window_state` | `computer.windowState` | `mode: "ax"` inspects only; `both`, `screenshot`, or `capture: true` create run artifacts. |
| `lattices_computer_element_action` | `computer.elementAction` | Defaults to `treatment: "stage"`; pass `execute` to perform AXPress/showMenu. |
| `lattices_computer_type_element` | `computer.typeElement` | Defaults to `treatment: "stage"`; pass `execute` to set or append AXValue text. |
| `lattices_computer_set_value` | `computer.setValue` | Defaults to `treatment: "stage"`; pass `execute` to replace AXValue. |
| `lattices_computer_press_key` | `computer.pressKey` | Defaults to `treatment: "stage"`; pass `execute` with an explicit target to press. |
| `lattices_computer_hotkey` | `computer.hotkey` | Defaults to `treatment: "stage"`; pass `execute` with an explicit target to send. |
| `lattices_window_focus` | `computer.focusWindow` | Defaults to `treatment: "stage"`; pass `present` or `execute` to focus. |
| `lattices_window_place` | `windows.place` | Returns the daemon action receipt. |
| `lattices_capture_window` | `capture.screenshotWindow` | Creates a run artifact. |
| `lattices_capture_region` | `capture.screenshotRegion` | Creates a run artifact for an explicit rect or target window frame. |
| `lattices_capture_zoom_artifact` | `capture.zoomArtifact` | Crops/scales an existing image artifact and links the derived artifact. |
| `lattices_vision_analyze_window` | `vision.analyzeWindow` | Captures a target window, then runs local OCR-backed analysis. |
| `lattices_vision_analyze_artifact` | `vision.analyzeArtifact` | Runs local OCR-backed analysis over an existing image artifact. |
| `lattices_computer_verify` | `computer.verify` | Verifies AX, OCR, text containment, or artifact-change expectations. |
| `lattices_computer_prepare` | `computer.prepare` | Stages/observes a terminal target. |
| `lattices_computer_launch_app` | `computer.launchApp` | Defaults to `treatment: "stage"`; pass `present` or `execute` to launch/focus. |
| `lattices_computer_click` | `computer.click` | Defaults to `treatment: "stage"`; pass `execute` to click. |
| `lattices_computer_double_click` | `computer.doubleClick` | Defaults to `treatment: "stage"`; pass `execute` to double-click. |
| `lattices_computer_right_click` | `computer.rightClick` | Defaults to `treatment: "stage"`; pass `execute` to right-click. |
| `lattices_computer_scroll` | `computer.scroll` | Defaults to `treatment: "stage"`; pass `execute` to scroll. |
| `lattices_computer_drag` | `computer.drag` | Defaults to `treatment: "stage"`; pass `execute` to drag. |
| `lattices_computer_type_window_text` | `computer.typeWindowText` | Defaults to `treatment: "stage"`; pass `execute` to insert text. |
| `lattices_computer_type_text` | `computer.typeText` | Defaults to `treatment: "stage"`; pass `execute` to insert text. |
| `lattices_browser_get_text` | `browser.getText` | Read-only AX text extraction for supported browser windows. |
| `lattices_browser_query_dom` | `browser.queryDom` | Requires `allowAutomation: true`; returns selector summaries from the active page. |
| `lattices_browser_execute_javascript` | `browser.executeJavascript` | Requires `allowAutomation: true` and `treatment: "execute"` before running script. |
| `lattices_call` | caller-selected | Escape hatch; prefer typed tools first. |

The default `source` for run-backed tools is `pi-lattices` unless the caller
passes a more specific `source`.

`lattices_call` intentionally does not add an extra safety layer; it is for
daemon methods that are not yet typed here. Prefer typed tools for actions and
keep destructive daemon methods out of normal prompts.

## Smoke checks

Registration only:

```bash
node packages/pi-lattices/test/smoke.mjs
```

Graceful daemon-down behavior (uses an intentionally unreachable port):

```bash
bun run --cwd packages/pi-lattices smoke:no-daemon
```

Live status + safe staged action:

```bash
lattices app
bun run --cwd packages/pi-lattices smoke:live
```

The live smoke calls `lattices_status`, then stages `computer.launchApp` for
Finder with `capture: false`; it does not launch or focus Finder because the
`treatment` is `stage`.

## Configuration

Version 0.2.0 finds `~/.lattices/run/lattices.sock` and its private token by
default. Use Lattices 0.15.1 and extension 0.2.0, with no host or port overrides for normal local use.

Set a request timeout before starting Pi if needed:

```bash
export LATTICES_DAEMON_TIMEOUT_MS=3000
```

For local TCP compatibility, enable `LATTICES_ALLOW_LOOPBACK_TCP=1` in both the
app and Pi environment. Explicit host/port overrides receive no local token
without that flag, even when a loopback address could be an SSH tunnel. Do not
enable compatibility for a tunnel; non-loopback targets never receive local
tokens.

The Pi extension does not sign remote gateway requests. An explicit remote
host/port cannot use a paired gateway on its own. Use the paired Lattices CLI
or native app for remote access.

## CUA implementation status

The LAT-008 computer-use surface is exposed here as typed Pi tools through
Phase 6: AX snapshots and element IDs, rich keyboard/mouse primitives,
region/zoom/vision/verification helpers, and browser page read/automation
primitives with explicit gates. Prefer the typed tools above; use
`lattices_call` only for new daemon methods that have not yet been added here.
