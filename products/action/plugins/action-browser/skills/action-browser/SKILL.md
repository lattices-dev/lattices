---
name: action-browser
description: Use Action Browser when the user wants an agent to open a URL in a real Chrome session, inspect a page, click or fill a DOM element, or capture a browser screenshot without setting up a headless browser.
metadata:
  internal: true
---

# Action Browser

Action Browser drives **Action-owned Chrome identities**. It never drives the
user's regular Chrome.

The `browser_*` tools are served by the lattices MCP, which ships with the
`lattices` CLI. Agent config names the binary, never a path:

```json
{ "command": "lattices", "args": ["mcp"] }
```

If the tools are missing, check `lattices mcp --list`, then the harness's MCP
configuration. This plugin carries the skill; it no longer carries the server.

## Which browser are we talking about?

Three different browsers can be in play. Pick deliberately, and say which one
you picked.

| | What it is | How you control it |
|---|---|---|
| **The user's regular Chrome** | Their everyday browser — real profiles (`Default`, `Profile 1` / "Work"), their tabs, history, extensions, logins | `browser_open { mode: "regular" }` opens a URL and stops there. **No DOM tools.** Drive that window with Action's native macOS control: `action.observe.snapshot` (screen + accessibility), `action.resolve.target`, `action.act.execute` |
| **An Action browser** | Real, non-headless Chrome that Action owns, on its own user-data-dir. Default identity `agent-browser` is blank and signed into nothing | Full DOM tools over CDP: `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot` |
| **An Action browser identity seeded from a regular Chrome profile** | The same Action-owned Chrome under a name like `work`, carrying cookies copied from one of the user's real profiles for an allowlist of domains | Full DOM tools, on sites the user is already signed in to |

The tradeoff in one line: **regular Chrome gives you their real session but only
screen-and-accessibility control; an Action browser gives you DOM control but
starts as a stranger.** Seeding is how you get both.

Regular mode is not a limitation Action can lift. [Chrome 136 and later ignore
remote-debugging switches for the user's default data
directory](https://developer.chrome.com/blog/remote-debugging-port), and Action
does not attempt to bypass that boundary.

## Choose the surface

Use HTTP retrieval when reading public content is sufficient. Use this plugin
when the task needs a real page, DOM interaction, or a browser screenshot.

`background: true` controls how Action requests browser opening; it does not
create a private display or prove continuous desktop preservation. If the user
requires private-display isolation, route to Action MCP `layer_open
{ browser: true }` after the capability, quarantine, and acceptance checks in
the [agent-layer guide](https://github.com/arach/lattices/blob/main/products/action/docs/agent-layer.md).
Missing tools or acceptance means stop and report the gap. Do not silently
substitute this plugin for a requested private layer.

## Inspect, act, verify, close

1. Pick the requested identity with `browser_use_profile` or `browser_open`'s
   `profile`; otherwise use `agent-browser`. Retain the identity and session
   reported by `browser_open`.
2. Open the URL with `background: true`, unless the user requests visibility.
   Opening reuses this session's current tab. Use `newTab: true` only for
   intentional parallel page state. Retain the returned tab `id` and pass it
   as `tabId` to subsequent inspection, input, screenshots, and closure.
3. Inspect with `browser_snapshot`. Use observed selectors for `browser_click`
   and `browser_fill`; refresh the snapshot after navigation or page changes.
4. Verify the resulting URL, content, or application state. Capture and show a
   `browser_screenshot` when visual confirmation matters. Input success alone
   does not establish task completion.
5. Close task-created tabs with `browser_close { tabId }`. When finished with
   the identity, release this session with `browser_close { scope: "browser" }`.
   Check `closed` and `liveOwners`; another live owner can keep Chrome running.

## Ownership and recovery

- `browser_tabs` lists the active identity's tabs, including tabs this task
  did not create. Listing a tab does not authorize navigating or closing it.
  Reuse a user-designated tab; otherwise retain ownership of your created tabs.
- Serialize profile switches, opens, and actions on this MCP connection. The
  active identity and current-tab default are shared mutable state. Parallel
  callers must coordinate ownership and pass explicit `tabId` values.
- After a timeout, inspect `browser_tabs` and the intended tab before retrying:
  navigation or a submitted action may already have succeeded. Do not repeat
  consequential input until its outcome is known.
- After disconnect or profile change, confirm the identity, tab ID, and URL
  again. A missing tab is not permission to act on whichever tab is now current.
- CDP errors, unavailable selectors, native dialogs, or login failures do not
  authorize foregrounding Chrome or switching to native pointer/keyboard
  input. Report the blocked operation; use another surface only when the
  user's task authorizes its effects.

## Responsive checks: resize, then screenshot

`browser_resize` sets an already-open tab to an explicit width and height, so a
breakpoint can be captured rather than guessed at.

```text
browser_open   { url: "http://localhost:3000" }
browser_resize { width: 1440, height: 900 }
browser_screenshot

browser_resize { width: 390, height: 844, mobile: true,
                 matchMedia: ["(max-width: 767px)"] }
browser_screenshot

browser_resize { reset: true }
```

- `target: "tab"` (default) emulates the size for that one tab. It is exact, it
  leaves every other tab alone, and `deviceScaleFactor: 1` makes screenshot
  pixels equal CSS pixels — a 390-wide viewport returns a 390px-wide PNG.
- `target: "window"` resizes the real Chrome window instead. Use it when
  emulation is not trustworthy for what is being checked; it moves every tab in
  that window, the display is a hard ceiling, and it drops the tab's emulated
  viewport first.
- The size **sticks to that tab** across later `browser_open`, `browser_snapshot`,
  and `browser_screenshot` calls until `reset: true`. It is dropped when the tab
  or the browser closes, and nothing is written to the profile.
- Pass `matchMedia` to have the breakpoint answered rather than eyeballed, and
  read `exact` in the reply — a page with a hard `min-width` can refuse to lay
  out as narrow as requested.
- `mobile: true` additionally honours the viewport meta tag and enables touch,
  which is what makes a real phone layout appear instead of a squeezed desktop one.

## Signed-in work: seed, then drive

When the page needs the user's login, seed an identity instead of handing off to
regular Chrome. `source` is the profile **directory** name, not the display
name — a browser the user calls "Work" is usually the `Profile 1` directory.

```text
browser_import_cookies { listSourceProfiles: true }
# -> maps display names to directories, e.g. "Work" -> "Profile 1"

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"] }
# dry run: lists the cookies that would be copied

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"], confirm: true }
# writes them, after the user approves

browser_open { url: "https://github.com/notifications", profile: "work" }
browser_snapshot
browser_screenshot
```

Rules for seeding:

- Always pass a domain allowlist. Never copy the whole cookie jar.
- Dry-run first; `confirm: true` needs the user's approval.
- Cookies are not a complete identity. localStorage and passkeys may still need
  a one-time interactive login in the Action browser.
- Never claim a page is authenticated without observing it after the seed.

## Handing off to regular Chrome

When the user explicitly asks to open something in *their* browser:

```text
browser_open { url: "https://github.com", mode: "regular" }
```

This is a visible, open-only handoff. Do not follow it with `browser_snapshot`,
`browser_click`, `browser_fill`, or `browser_screenshot` — those stay attached
to the Action browser. If the user then wants the agent to act on that window,
switch to Action's native tools rather than the browser tools.

## Identities and companion

- Identities live under `~/Library/Application Support/Action/ChromeProfiles/<name>`.
- Default is `agent-browser` unless `ACTION_BROWSER_PROFILE` is set.
- `browser_profiles` lists identities; `browser_profile_info` shows the active one.
- Any unused name creates a fresh blank identity on first open.
- `browser_companion_status` reports the Chrome Companion extension dist and
  localhost bridge. Richer DOM tooling lives in Action's
  `packages/chrome-companion`; load its `dist` unpacked once per identity when
  the user wants that path. It needs an Action checkout: set `ACTION_ROOT` if
  the tools run from a published `lattices` install, where the companion is not
  included and status reports it missing.

## Important behavior

- Real Chrome with CDP — not headless.
- `browser_open` defaults to `mode: "action"`; `mode: "regular"` truthfully
  returns `controlAvailable: false` plus the native control path.
- `browser_open` creates one working tab per agent session, then navigates that
  tab on later calls. Use `newTab: true` for an intentional additional tab.
- `browser_screenshot` saves a PNG artifact and returns the image in the tool
  response, and reports the `viewport` it was captured at.
- `browser_resize` needs a tab already open; it changes size, never navigation.
- Prefer a stable CSS selector from `browser_snapshot` over text matching.
- The session releases its browser claim on exit, after fifteen idle minutes,
  or on `browser_close { scope: "browser" }`. Chrome may remain while another
  live session owns it.
- Call `browser_close` with `scope: "browser"` when a browsing task is finished
  and nothing further is expected.

## Safety

Opening, inspecting, and capturing pages are ordinary read actions. Treat clicks
and form fills according to their actual consequence. Do not submit purchases,
publish content, delete data, or confirm other consequential actions without
the user's authority. Cookie import requires an explicit `confirm: true`.
