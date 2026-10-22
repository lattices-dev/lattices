---
title: Browser
description: The three browser surfaces an agent can drive with Action, and which tools reach each one
order: 4
---

An agent can use a browser with Action in three ways. They differ in which
tools reach the page, which identity the page has, and whether the user sees it.

## Choose a surface

| Surface | Served by | Control | Identity |
| --- | --- | --- | --- |
| Your regular Chrome | Action MCP native tools | Screen capture and accessibility only (`observe_snapshot`, `resolve_target`, `act_execute`) | Your real Chrome profiles |
| An Action browser | Lattices MCP `browser_*` tools | DOM control over the Chrome DevTools Protocol (CDP) | An Action-owned Chrome profile, blank or seeded |
| A private-layer browser | Action MCP `layer_*` tools | CDP only, on a prepared virtual display | An Action-owned profile per workspace |

Use regular Chrome when the task needs your live session and visible tabs. Use
an Action browser for DOM-level work in a window you can watch. Use a
private-layer browser when the work must stay off your screens.

## Regular Chrome

`browser_open {mode:"regular"}` opens a URL in your own Chrome as a visible
handoff. Nothing attaches DevTools to it. To act in that window, use the Action
MCP native loop: `observe_snapshot`, then `resolve_target`, then
`act_execute`.

## Action browsers

The `browser_*` tools are part of the Lattices MCP server, not `Action.app`.
Register it once:

```sh
claude mcp add lattices -s user -- lattices mcp
```

The tools launch a real, non-headless Chrome on an Action-owned user data
directory and drive it over CDP. The debug port defaults to `9334` and can be
set with `ACTION_BROWSER_DEBUG_PORT`.

| Tool | Purpose |
| --- | --- |
| `browser_open` | Open a URL in an Action browser, or hand it to regular Chrome |
| `browser_snapshot` | Read the page as an element list with refs |
| `browser_click`, `browser_fill` | Act on an element ref |
| `browser_screenshot`, `browser_resize` | Capture or size the viewport |
| `browser_tabs`, `browser_close` | List or close tabs |
| `browser_console` | Read console output |
| `browser_profiles`, `browser_profile_info`, `browser_use_profile` | List and select browser identities |
| `browser_import_cookies` | Seed an identity with cookies from one of your Chrome profiles |
| `browser_companion_status` | Check the optional Chrome companion bridge on `ws://127.0.0.1:4321` |

Identities, cookie seeding, and the companion bridge are covered in
[Browser profiles](/action/docs/browser-profiles). The full tool reference is
in the [Lattices MCP](/lattices/docs/mcp) page.

## Private-layer browsers

A private-layer browser runs on a prepared virtual display in an agent-layer
workspace. Prepare the display once with the CLI, then use the Action MCP:

```text
layer_open     {workspace, browser:true, url, task}
layer_snapshot {workspace}
layer_click / layer_type / layer_press / layer_js / layer_go
layer_close    {workspace}
```

- `layer_open` begins a drive lease unless you pass an existing `leaseId`.
  `layer_close` releases it.
- Coordinates come from the last `layer_snapshot`.
- The path is CDP only. There is no native fallback, so do not mix in desktop
  `observe_*` or `drive_aim` calls.
- Browser flags, navigation, input, and JavaScript need MCP. The CLI `layer`
  commands cover lifecycle, snapshot, picture-in-picture, and recording.

Read `capabilities` first and confirm that the host and build accept private
layers. See [Agent layer](/action/docs/agent-layer).
