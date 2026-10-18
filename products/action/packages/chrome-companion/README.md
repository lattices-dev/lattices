# Action Chrome Companion

Minimal Manifest V3 companion extension for Action browser-surface experiments.

It contains:

- a service worker that can route `action.*` messages to a tab selected by URL
- a localhost WebSocket bridge for Action runtime experiments
- a bridge extension page for a long-lived connection in Action-owned profiles
- a content script with DOM observe/resolve/act helpers
- Midjourney Create helpers for prompt submission and result extraction
- self-contained Bun scripts for typechecking and building the unpacked extension

## Commands

```bash
bun run typecheck
bun run build
bun run install:dev
bun run launch:profile
bun run bridge
bun run health
```

The build output is written to `dist/` and can be loaded in Chrome as an unpacked
extension.

`bun run install:dev` builds the extension, opens `chrome://extensions`, and
reveals `dist/` in Finder. Chrome still requires the user to approve the unpacked
extension in the UI for their real profile.

The local bridge listens on `http://127.0.0.1:4321`. When the extension is
installed, its service worker connects to `ws://127.0.0.1:4321/chrome-companion`.
`bun run health` exits successfully only when that bridge connection is live.

## Profile Policy

Action should run Chrome browser-surface work in an Action-owned Chrome profile
by default. This keeps extension state, tabs, cookies, cache, and other browser
settings deterministic and avoids mutating the user's daily Chrome profile.

For authenticated tools, use a named persistent Action profile and either:

1. sign in once interactively in that profile, or
2. **selectively import cookies** from a regular Chrome profile (domain allowlists).

The user's regular Chrome is never an automation target here. It is reachable
only as an open-only handoff, and is driven with Action's native screen and
accessibility tools instead. Full product docs: [docs/browser-profiles.md](../../docs/browser-profiles.md).

Create and prepare a named profile with:

```bash
bun run profile -- setup work
# or the creative identity used by the companion tooling:
bun run profile -- setup mira
```

This builds the extension, creates the profile directory, opens that profile to
`chrome://extensions`, and reveals the extension `dist/` folder in Finder.
Named identities (for example `work` or `mira`) are persistent Chrome profiles
for observing and acting in web tools without touching the regular browser.

### Cookie seeding

```bash
bun run import:cookies -- --list-profiles
bun run import:cookies -- --list-action-profiles
bun run import:cookies -- list --into work --source "Profile 1" --domains github.com
bun run import:cookies -- import --into work --source "Profile 1" --domains github.com --confirm
```

Also available as:

```bash
bun run profile -- import-cookies import --into work --source "Profile 1" --domains github.com --confirm
```

### Launch and check

```bash
bun run profile -- launch work
bun run profile -- check work
```

If `check` reports a companion extension id, open the persistent bridge page:

```bash
bun run profile -- bridge work --extension-id <id-from-check>
```

Profiles live under:

`~/Library/Application Support/Action/ChromeProfiles/<name>`

Examples:

- `.../ChromeProfiles/agent-browser` — Action Browser MCP default
- `.../ChromeProfiles/work` — seeded from a regular Chrome profile
- `.../ChromeProfiles/mira`

Override the root with `ACTION_CHROME_COMPANION_PROFILE_ROOT` or a single profile
with `ACTION_CHROME_COMPANION_PROFILE_DIR`. Action Browser MCP shares the same
root via `ACTION_BROWSER_PROFILE` / `ACTION_BROWSER_PROFILE_ROOT`.

Chrome Stable may ignore command-line `--load-extension`, so the reliable setup
is:

1. Launch the Action-owned profile.
2. Load `dist/` as an unpacked extension once in that profile.
3. Click the extension reload button after rebuilding `dist/`.
4. Keep using that profile for Action browser-surface work.

When the extension is installed, it opens `bridge.html` to keep the localhost
bridge alive. If you need the launch script to open that page explicitly, pass
`ACTION_CHROME_COMPANION_EXTENSION_ID`.

## Surface Routing

Messages can include a `surface` target so Action does not depend on whichever
tab is frontmost:

```json
{
  "method": "midjourney.submitPrompt",
  "params": {
    "surface": {
      "urlMatches": ["https://www.midjourney.com/imagine*"],
      "createUrl": "https://www.midjourney.com/imagine",
      "activate": false
    },
    "prompt": "Action app logo, abstract A cursor mark, no text"
  }
}
```

Send it through the bridge:

```bash
curl -s http://127.0.0.1:4321/rpc \
  -H 'content-type: application/json' \
  -d @message.json
```

## Message API

Send messages to the extension service worker with one of these methods:

- `action.tabs.query`
- `action.tabs.ensure`
- `action.observe`
- `action.resolve`
- `action.setValue`
- `action.click`
- `action.rect`
- `midjourney.observe`
- `midjourney.setPrompt`
- `midjourney.submitPrompt`
- `midjourney.readResults`

Example:

```js
chrome.runtime.sendMessage({
  method: "action.observe",
  params: { selector: "button, input, textarea, a" }
});
```

## Experimental fast actions

The companion also supports observation-bound `action.fast.observe` and
`action.fast.act`. See [the experiment guide](../../docs/fast-browser-experiment.md)
for the bounded model loop, target guards, timing, and verification requirements.
