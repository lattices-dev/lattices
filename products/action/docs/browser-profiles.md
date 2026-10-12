# Browser Identity: Regular Chrome, Action Browsers, Seeded Identities

How Action gives an agent a **browser identity** without taking over your daily
Chrome — and which kind of control you get in each case.

## Three browsers, two kinds of control

When an agent says "I'll open it in Chrome", it can mean one of three things.
They are not interchangeable.

| | What it is | What the agent can do |
|---|---|---|
| **1. Your regular Chrome** | The browser you use all day. Your real profiles (`Default`, `Profile 1` / "Work"), your tabs, history, extensions, and logins. | **Open a URL, and that's it.** `browser_open { mode: "regular" }` is a visible handoff with no DevTools attachment. To make the agent *act* there, use Action's native macOS control: screen capture + accessibility (`action.observe.snapshot`, `action.resolve.target`, `action.act.execute`). |
| **2. An Action browser** | A real, non-headless Chrome that Action owns, on its own user-data-dir under `~/Library/Application Support/Action/ChromeProfiles/`. The default identity `agent-browser` is blank and signed into nothing. | **Full DOM control** over CDP: `browser_snapshot`, `browser_click`, `browser_fill`, `browser_resize`, `browser_screenshot`, `browser_tabs`. |
| **3. An Action browser identity seeded from one of your Chrome profiles** | The same Action-owned Chrome under a name you choose (`work`, `mira`, …), carrying cookies copied from one of your real profiles for an explicit allowlist of domains. | **Full DOM control, on sites you're already signed in to.** |

The tradeoff in one line: **your regular Chrome has your session but only
screen-and-accessibility control; an Action browser has DOM control but starts
as a stranger.** Seeding (option 3) is how you get both.

This is a boundary Action does not try to cross. [Chrome 136 and later ignore
remote-debugging switches for the default personal data
directory](https://developer.chrome.com/blog/remote-debugging-port), and Action
does not attempt to bypass it. Pointing automation at your everyday user-data-dir
would also fight Chrome's directory lock and hand an agent your full history,
extensions, and sessions by accident.

### Picking one

- The user wants to *look* at something in their own browser → **regular**.
- The agent needs to click through a public site → **Action browser**.
- The agent needs to click through a site you're logged into → **seeded identity**.
- The agent needs to act inside your real signed-in session, and cookies aren't
  enough (passkeys, SSO device trust, an extension's state) → **regular Chrome
  plus Action's native observe/act**, not the browser tools.

## The canonical example: seed "Profile 1" into `work`, then drive it

Your Chrome profile *directory* names are `Default`, `Profile 1`, `Profile 2`, …
and are not the display names you see in Chrome's avatar menu. A browser you
call "Work" is usually the `Profile 1` directory. Map them first, then seed.

From an agent, over MCP:

```text
browser_import_cookies { listSourceProfiles: true }
# -> [{ dir: "Default", name: "Personal" }, { dir: "Profile 1", name: "Work" }, ...]

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"] }
# dry run: lists exactly which cookies would be copied

browser_import_cookies { into: "work", source: "Profile 1", domains: ["github.com"], confirm: true }
# writes them into the Action identity `work`

browser_open { url: "https://github.com/notifications", profile: "work" }
browser_snapshot
browser_screenshot
```

The same thing from the terminal:

```bash
# map display names to profile directories
bun run chrome:companion:import:cookies -- --list-profiles

# dry run
bun run chrome:companion:import:cookies -- list --into work --source "Profile 1" --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --source "Profile 1" --domains github.com --confirm
```

After that, `work` is an ordinary Action identity: `browser_use_profile
{ profile: "work" }` or `browser_open { url, profile: "work" }`, and every DOM
tool works against it.

## Named identities

Identities are created on first use — any unused name gives you a fresh blank
one. Shipped conventions:

- `agent-browser` — the default blank agent identity
- `work` — seeded from your work Chrome profile, per the example above
- `mira` — the creative/Midjourney identity used by the companion tooling

Create and prepare one with the companion extension loaded:

```bash
# from the Action product root (`products/action`)
bun run chrome:companion:profile -- setup work
```

This builds the companion extension, creates the profile directory, opens
`chrome://extensions` in that profile, and reveals `packages/chrome-companion/dist`
so you can **Load unpacked** once.

Later:

```bash
bun run chrome:companion:profile -- launch work
bun run chrome:companion:profile -- check work
bun run chrome:companion:profile -- path work
```

Environment aliases (shared between companion tooling and Action Browser MCP):

| Variable | Meaning |
|----------|---------|
| `ACTION_BROWSER_PROFILE` / `ACTION_CHROME_COMPANION_PROFILE` | Active identity name |
| `ACTION_BROWSER_PROFILE_DIR` / `ACTION_CHROME_COMPANION_PROFILE_DIR` | Absolute user-data-dir override |
| `ACTION_BROWSER_PROFILE_ROOT` / `ACTION_CHROME_COMPANION_PROFILE_ROOT` | Root for named identities |
| `ACTION_BROWSER_DEBUG_PORT` | CDP port (MCP default `9334`) |
| `ACTION_ROOT` | Action product root (`<lattices-checkout>/products/action`); cookie tools use it when the MCP process starts elsewhere |

## Cookie seeding

Copy **selected** cookies from a regular Chrome profile into an Action identity:

```bash
# list your Chrome profiles (directory + display name)
bun run chrome:companion:import:cookies -- --list-profiles

# list Action identities
bun run chrome:companion:import:cookies -- --list-action-profiles

# dry-run
bun run chrome:companion:import:cookies -- list --into work --domains github.com

# write
bun run chrome:companion:import:cookies -- import --into work --domains github.com --confirm

# narrow to specific cookies
bun run chrome:companion:import:cookies -- import --into mira \
  --domains midjourney.com \
  --only cf_clearance \
  --confirm
```

Or via the profile CLI:

```bash
bun run chrome:companion:profile -- import-cookies import --into work --domains github.com --confirm
```

Notes:

- Requires a Keychain allow for Chrome Safe Storage only when decrypting values;
  the import path copies encrypted blobs as-is for same-machine use.
- Prefer domain allowlists over full-jar dumps.
- Cookies are not a complete identity (localStorage / passkeys may still need a
  one-time interactive login in the Action identity).

## Chrome Companion (generic extension)

Package: `packages/chrome-companion`

- Manifest V3 extension with DOM observe / resolve / act helpers
- Localhost bridge on `http://127.0.0.1:4321` (WebSocket for the extension)
- One-time **Load unpacked** per Action identity (`dist/` after build)

```bash
bun run chrome:companion:build
bun run chrome:companion:bridge
bun run chrome:companion:health
bun run chrome:companion:profile -- setup work
```

Chrome Stable often ignores `--load-extension`; the reliable path is manual
unpacked install inside the Action-owned identity.

## Action Browser MCP

Server: `bin/mcp/toolsets/browser/index.ts` in the lattices repo root — the
browser tools are a toolset inside the lattices MCP, served by `lattices mcp`.
See [the lattices MCP doc](../../../docs/mcp.md).

### Tools

| Tool | Purpose |
|------|---------|
| `browser_profiles` | List Action identities, the active one, and the three-surface policy |
| `browser_use_profile` | Switch the active identity (`agent-browser`, `work`, `mira`, …) |
| `browser_profile_info` | Active path, cookie readiness, companion hints |
| `browser_import_cookies` | Dry-run or confirm a seed from a regular Chrome profile |
| `browser_companion_status` | Extension dist + bridge health |
| `browser_open` | Open in an Action browser, or `mode: "regular"` for an open-only handoff |
| `browser_tabs` / `browser_snapshot` / `browser_click` / `browser_fill` / `browser_screenshot` / `browser_close` | DOM automation via CDP — Action browsers only |
| `browser_resize` | Set a tab to an explicit viewport width and height for responsive checks; `target: "window"` resizes the real Chrome window instead |

### Two MCP surfaces

- **Native runtime MCP** (`action`): observe / resolve / act / record on macOS
  through Action.app. This is what controls your *regular* Chrome window, and
  every other native app, via screen capture and accessibility.
- **Browser MCP** (the `browser` toolset of `lattices mcp`): Action-owned Chrome
  identities plus DOM-level tools over CDP.

Register it. The entry names the `lattices` binary and no path, so a repo move or
a version bump cannot break it:

```bash
claude mcp add lattices -s user -- lattices mcp
```

To pin a default identity, add the environment variable to that same entry:

```bash
claude mcp add lattices -s user -e ACTION_BROWSER_PROFILE=work -- lattices mcp
```

`ACTION_ROOT` is only needed for the Chrome Companion paths below, and only when
the tools run from a published `lattices` install rather than a checkout.

### Agent workflow

```text
browser_profiles                                   # what identities exist
browser_use_profile { profile: "work" }            # pick one
browser_open { url: "https://github.com" }         # drive it
browser_snapshot
browser_screenshot
browser_companion_status                           # optional richer DOM path
browser_close { scope: "browser" }                 # when the task is done
```

To open a URL in the user's own Chrome instead:

```text
browser_open { url: "https://github.com", mode: "regular" }
```

Regular mode is deliberately not controllable, and the result says so:
`controlAvailable: false`, plus the native control path. Snapshot, click, fill,
and screenshot continue to target the Action browser.

### Responsive breakpoints

`browser_resize` gives an already-open tab an explicit viewport, so a narrow
layout can be captured instead of assumed.

```text
browser_open   { url: "http://localhost:3000" }
browser_resize { width: 1440, height: 900 }
browser_screenshot
browser_resize { width: 390, height: 844, mobile: true, matchMedia: ["(max-width: 767px)"] }
browser_screenshot
browser_resize { reset: true }
```

Two targets, deliberately not interchangeable:

| | What moves | Cost |
|---|---|---|
| `target: "tab"` (default) | CSS emulation for that one tab | Exact to the pixel, other tabs unaffected, fully reversible |
| `target: "window"` | The real Chrome window hosting the tab | Every tab in that window moves, the display is a hard ceiling, and the tab's emulated viewport is dropped first |

A device-metrics override belongs to the CDP session that set it, and Action
Browser opens a fresh session per tool call. Two consequences shape the design:

- The server keeps the requested viewport in memory and re-applies it on every
  session, so a resize survives the later `browser_screenshot` that is the whole
  point of it. It is per-tab, in-memory only, and dropped when the tab or the
  browser closes — nothing is written to the profile.
- `reset` cannot simply call `clearDeviceMetricsOverride`: a foreign session's
  clear is accepted and does nothing, leaving Chrome stuck at the stale size. The
  reset re-sets the metrics to adopt ownership first, then clears them.

`deviceScaleFactor` defaults to `1`, which makes screenshot pixels equal CSS
pixels — a 390-wide viewport returns a 390px-wide PNG. Read `exact` in the reply
before trusting a capture: a page with a hard `min-width` can refuse to lay out
as narrow as it was asked to.

## Plugin versioning

Harnesses cache the Action Browser skill and interface metadata by plugin
version. Bump all seven manifests together when that metadata changes:

```bash
bun run plugin:version              # check that every manifest agrees
bun run plugin:version -- 0.4.1     # set them all
```

The check covers the root and Action product marketplace/Kimi manifests, plus
the browser plugin's Claude, Codex, and Kimi manifests. Reinstall or refresh the
plugin in each harness so its cached skill is replaced.

The plugin no longer carries an MCP server or a `SERVER_VERSION`. Browser tools
ship with the lattices CLI; updating that CLI and restarting its MCP process
updates the server separately from refreshing this skill-only plugin.

## What is intentionally not done

- Automation attachment to the currently open regular Chrome window
- Silent full cookie jar import
- Claiming a page is authenticated without observing it after seed/login

## Related

- [packages/chrome-companion/README.md](../packages/chrome-companion/README.md)
- [ACT-001 surface adapter architecture](decisions/ACT-001-surface-adapter-architecture.md)
- [plugins/action-browser/skills/action-browser/SKILL.md](../plugins/action-browser/skills/action-browser/SKILL.md)

## Browser request deadlines

`browser_open.waitMs` is the total operation budget (15,000 ms by default),
including profile selection, Chrome startup, HTTP/CDP connection, navigation,
and readiness checks. Zero fails immediately without opening a tab. Expiry
returns an MCP tool error and cancels pending transport work; increasing
`waitMs` does not remove the 10-second limit on individual HTTP/CDP operations.

Configure the MCP server as `command: "lattices", args: ["mcp"]` — no path, so it
cannot be pinned to a stale checkout or plugin cache. On the next MCP process
start, `initialize` reports the lattices version, and `tools/list` exposes
`browser_open.mode`, `profile`, and `newTab`. Existing MCP processes retain their
loaded implementation until reloaded.

The `lattices` launcher resolves Bun from `LATTICES_BUN_BIN`, PATH, or the
standard user and Homebrew locations, so it survives the bare system PATH a
GUI-launched harness hands it. An explicit invalid override fails with an
actionable error.
