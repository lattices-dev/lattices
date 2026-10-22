# Pi Lattices Extension

`@arach/pi-lattices` is a Pi package that turns the Lattices daemon into
first-class Pi tools. It is implemented in `packages/pi-lattices/` and registers
strictly-prefixed `lattices_*` tools on Pi session start.

The extension preserves the Lattices runtime model:

- It calls the existing macOS-native daemon. Lattices 0.15.1 uses
  private IPC by default. Install the compatible extension from this checkout.
- It does not bundle or route through `cua-driver`.
- Run-backed computer-use tools keep Lattices `treatment` semantics.
- Mutation wrappers prefer `treatment: "stage"` unless the caller explicitly
  asks for `present` or `execute`.
- Daemon-down failures are tool results with guidance, not registration-time
  crashes.

## Install

From this repo during development:

```bash
pi install ./packages/pi-lattices --local
```

Published package form:

```bash
pi install npm:@arach/pi-lattices
```

Start Lattices before using the tools:

```bash
lats app
```

## Private connection

Use the extension and app from matching source. The extension finds
`~/.lattices/run/lattices.sock` and its private token; no host or port setting
is needed. Use the compatible extension from this checkout with Lattices 0.15.1.

An explicit `LATTICES_DAEMON_HOST` or `LATTICES_DAEMON_PORT` selects TCP. The
extension sends no local token to that target unless
`LATTICES_ALLOW_LOOPBACK_TCP=1` is also set and the target is loopback. Enable
that flag in the app too if you need its compatibility listener. An SSH tunnel
on `127.0.0.1` is still a network target, so do not enable compatibility for it.

The Pi extension does not sign remote gateway requests. A remote host/port
override alone cannot use a paired gateway; use the paired Lattices CLI or
native app for that path.

## High-value tools

| Pi tool | Lattices method |
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
| `lattices_computer_window_state` | `computer.windowState` |
| `lattices_computer_element_action` | `computer.elementAction` |
| `lattices_computer_type_element` | `computer.typeElement` |
| `lattices_computer_set_value` | `computer.setValue` |
| `lattices_computer_press_key` | `computer.pressKey` |
| `lattices_computer_hotkey` | `computer.hotkey` |
| `lattices_window_focus` | `computer.focusWindow` |
| `lattices_window_place` | `windows.place` |
| `lattices_capture_window` | `capture.screenshotWindow` |
| `lattices_capture_region` | `capture.screenshotRegion` |
| `lattices_capture_zoom_artifact` | `capture.zoomArtifact` |
| `lattices_vision_analyze_window` | `vision.analyzeWindow` |
| `lattices_vision_analyze_artifact` | `vision.analyzeArtifact` |
| `lattices_computer_verify` | `computer.verify` |
| `lattices_computer_prepare` | `computer.prepare` |
| `lattices_computer_launch_app` | `computer.launchApp` |
| `lattices_computer_click` | `computer.click` |
| `lattices_computer_double_click` | `computer.doubleClick` |
| `lattices_computer_right_click` | `computer.rightClick` |
| `lattices_computer_scroll` | `computer.scroll` |
| `lattices_computer_drag` | `computer.drag` |
| `lattices_computer_type_window_text` | `computer.typeWindowText` |
| `lattices_computer_type_text` | `computer.typeText` |
| `lattices_browser_get_text` | `browser.getText` |
| `lattices_browser_query_dom` | `browser.queryDom` |
| `lattices_browser_execute_javascript` | `browser.executeJavascript` |
| `lattices_call` | caller-selected escape hatch |

Use `lattices_call` only when a method is not typed yet. It passes through the
requested daemon method and does not add an additional confirmation layer.
Browser DOM/JavaScript tools are intentionally explicit: DOM queries require
`allowAutomation: true`, and JavaScript execution also requires
`treatment: "execute"`.

## Smoke/manual test path

Automated registration smoke:

```bash
node packages/pi-lattices/test/smoke.mjs
```

Daemon-down behavior:

```bash
bun run --cwd packages/pi-lattices smoke:no-daemon
```

Live status + safe staged call:

```bash
lats app
bun run --cwd packages/pi-lattices smoke:live
```

The live smoke checks `daemon.status`, then stages a `computer.launchApp` run for
Finder with `capture: false`. Because the call uses `treatment: "stage"`, it
records intent without launching or focusing the app.
