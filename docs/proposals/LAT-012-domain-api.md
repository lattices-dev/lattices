# LAT-012: One API, domain namespaces, embedded helpers

Status: Proposed, 2026-09-23. Partially supersedes [LAT-011](LAT-011-companion-app-architecture.md)
(distribution and discovery). LAT-011's runtime boundaries still stand: ports,
tokens, leases and credentials.

## Summary

Lattices is a framework for operating a workspace, with parity between the user
and agents. Every capability is addressed as `lattices.<domain>.<verb>`:

```
lattices.windows.place(wid, "left")
lattices.canvas.pin(note, at: "top-right")
lattices.computer.click(target)
lattices.voice.say("Build finished")
```

Some verbs are served by helpers (Voice, Blink, Action), which are separate
processes embedded in Lattices.app. Agents, skills, the CLI and MCP never see
helpers, only domains.

## Glossary

| Use | Meaning |
| --- | --- |
| **domain** | An API namespace agents see, such as `voice` or `windows`. |
| **verb** | One method on a domain, such as `say` or `place`. |
| **backend** | The process that serves a verb: the daemon itself, or a helper. |
| **helper** | An app embedded in `Lattices.app/Contents/Helpers`: Voice, Blink or Action. It has its own process, bundle ID and settings window. |
| **daemon** | The Lattices process that hosts the router and the native backends. |
| **router** | The daemon layer that resolves a name, applies aliases, and dispatches to a backend. |
| **surface** | One projection of a name: SDK, CLI, daemon RPC or MCP. |

**Retired:**
- *companion* becomes helper.
- *product*, *module* and *engine* become helper or backend.
- *overlay* becomes canvas.
- *Speech* becomes Voice. The name survives only in the frozen bundle ID `dev.lattices.Speech`.
- Action's *drive* and *stage* vocabulary maps to verbs, as listed below.
- *app* now means only Lattices.app itself, or a third-party app the user runs.

## Naming rules

1. **The domain is one lowercase noun, and the method is a verb.** One verb per
   call, and never a compound verb such as `act_execute`.
2. **Domains are plural where they name a collection**: `windows`, `spaces`,
   `layers`, `sessions`, `tabs`, `apps`, `artifacts`. Mass nouns stay singular:
   `canvas`, `computer`, `voice`, `capture`.
3. **Read verbs** are `status`, `list`, `get` and `search`. Every domain that has
   state answers `status`; there is no separate `health`, `recording` or `staged`.
4. **Sub-nouns only name a collection the domain owns**: `mouse.shortcuts.set`,
   `canvas.notes.create`, `sessions.layers.list`.
5. **Exclusive access is always `lease` and `release`**, in every domain.
6. **One operation, one verb, in the domain it acts on.** How the verb gets done
   is the backend's business, and `via` selects it. The default is native: the
   daemon calls macOS directly, which is fast and exact. `via: "computer"` does the
   same thing through computer use, visibly, the way a person would. That is
   useful for recorded demos, or when the native route cannot reach the target.

   ```
   lattices.windows.focus(wid)                      // native
   lattices.windows.focus(wid, { via: "computer" }) // cursor and clicks, on screen
   ```

   `computer.*` keeps only what has no structural equivalent: observe, click,
   type, press, drag, scroll, aim.
7. **Rename only on a real collision.** A name stays unless two verbs could be
   mistaken for each other, or a name reads as something it is not. Otherwise
   the fix is a "use when" line (below), not a new word. Two verbs that do the
   same job merge into the one that already exists.
8. **Surface forms.** MCP turns every dot after the domain into `_`, because MCP
   forbids dots, and the server name supplies `lattices`.

| Surface | Form | Example |
| --- | --- | --- |
| SDK | `lattices.<domain>.<verb>(…)` | `lattices.mouse.shortcuts.set(…)` |
| CLI | `lattices <domain> <verb> …` | `lattices mouse shortcuts set …` |
| Daemon RPC | `<domain>.<verb>` | `mouse.shortcuts.set` |
| MCP | `<domain>_<verb>` | `mouse_shortcuts_set` |

## Which do I call?

| I want to… | Call |
| --- | --- |
| See what is on screen right now | `computer.observe({ mode })`, where mode is `snapshot`, `ax`, `ocr` or `vision` |
| Search what has been on screen before | `ocr.search` |
| Find a window by name or project | `windows.search` |
| Bring a window forward | `windows.focus`, adding `{ via: "computer" }` to do it visibly |
| Open an app | `apps.open` |
| Click or type somewhere | `computer.click`, `computer.type` |
| Save a screenshot or recording | `capture.screenshot`, `capture.record` |
| Put something on the screen for the user | `canvas.pin` for something that stays, `canvas.draw` for something transient |
| Say something out loud | `voice.say` |
| Work in a browser page | `browser.*`. `target: "agent"` (the default) is the agent's own Chrome; `"user"` is the user's browser. |

`mouse.*` is the user's physical pointer (find it, summon it, its shortcuts).
The agent's synthetic cursor is `computer.aim`.

## Use when

A cold test (a fresh agent given only the verb list, 2026-09-23) scored 4 of 11
tasks confident. The misses were clusters of neighbouring verbs with no stated
boundary. Each verb in these clusters carries its "use when" line into
`api.schema`, the MCP tool description and the skill. The line is the contract;
the name only has to not mislead.

**Moving windows**

| Verb | Use when |
| --- | --- |
| `windows.place` | Put a window at a position: `left`, `top-right`, a grid cell, or a frame, on this display or another (`display`). Takes `wid`, `session` or `app`. The answer to "put Xcode on the left half". |
| `windows.move` | Send a window to another Space, or to another display keeping its relative size and position. Use `place` when you want a specific position. |
| `windows.present` | Bring a window to the Space you are on and raise it, optionally placing it. Use it when the window may be on another Space. |
| `windows.focus` | Raise and activate a window where it already is. |
| `windows.pick` | Ask the user to click a window. Returns its `wid`. |
| `windows.resolve` | Dry run: which window a target means, and where `place` would put it. Moves nothing. |
| `layout.distribute` | Arrange several windows at once in a grid. |

**Reading the screen**

| Verb | Use when |
| --- | --- |
| `desktop.snapshot` | Workspace state in one call: front window, layer, displays, sessions, permissions. No pixels. |
| `computer.observe` | What an app shows right now: screenshot, AX tree, OCR text or a vision read, for the agent to act on. |
| `ocr.search` | Text that has been on screen before, across all windows. |
| `ocr.history` | The text timeline of one window (`wid`), or of all windows when `wid` is omitted. |
| `ocr.scan` | Force a fresh OCR pass now instead of waiting for the next scheduled one. |
| `capture.screenshot`, `capture.record` | Save a file for a person to look at. The agent reads the screen with `computer.observe`. |

**Terminals**

| Verb | Use when |
| --- | --- |
| `sessions.*` | Lattices project sessions: launch, kill, restart. |
| `terminals.list`, `terminals.search` | Terminal tabs as the user sees them: app, cwd, running command, Claude or not. |
| `terminals.capture` | Exact pane text from tmux. Better than OCR for terminals. |
| `tmux.list` | Raw tmux sessions, including ones Lattices did not launch. |
| `processes.list`, `processes.tree` | Developer processes and their children, linked to windows. |

**Exclusive access and modes**

| Verb | Use when |
| --- | --- |
| `computer.lease` / `release` | Take and give back the screen for computer use. Other agents wait. |
| `voice.lease` / `release` | Hold the speaker so other agents do not talk over you. |
| `solo.enter` / `exit` | The user's Focus Mode: resizes the front window and blacks out everything around it; the frame is restored on exit. Not a lock. |

**Doing things by description**

| Verb | Use when |
| --- | --- |
| `intents.run` | Do something described as an intent with slots, like voice does. Returns a receipt. |
| `runs.create` / `list` / `get` | A run is one piece of agent work with an artifact directory (recordings, screenshots, traces). Use it to group outputs, not to undo. |
| `history.list` / `undo` | Receipts of workspace changes (`intents.run`), and undo of the latest undoable one. |
| `assistant.preview` | Dry-run the hands-off planner on a transcript or snapshot. Executes nothing. |
| `deck.*` | The iPad cockpit's buttons and state. Only the cockpit needs it. |

**Notes**

| Verb | Use when |
| --- | --- |
| `canvas.notes.*` | Markdown notes that live in the workspace and can be pinned. |
| `canvas.pin` | Show something to the user on screen until it is unpinned. |
| `computer.caption` | One line in the computer-use HUD saying what the agent is about to do. |

## Domains and backends

The backend is chosen per verb, not per domain. If a verb's helper is not
installed, the call fails with `helper_not_installed`, names the helper, and
gives the fix: "Lattices › Apps › Install Voice". There are no fallbacks.

| Domain | Verbs | Backend |
| --- | --- | --- |
| `windows` | list, get, preview, search, place, move, present, focus, resolve, pick | daemon |
| `spaces` | list, optimize | daemon |
| `layers` | list, activate, switch, assign, unassign, map | daemon |
| `layout` | distribute | daemon |
| `desktop` | snapshot (front window, layer, displays, sessions, permissions) | daemon |
| `sessions` | launch, kill, detach, restart, sync, `layers.*` | daemon |
| `groups` | launch, kill | daemon |
| `tabs` | list, stack, add, select, layout, unstack | daemon |
| `apps` | open | daemon |
| `projects`, `processes`, `terminals`, `tmux` | list, scan, tree, search, capture (unchanged, except `tmux.list`) | daemon |
| `mouse` | find, summon, `shortcuts.*` | daemon |
| `ocr` | search, history, scan. This is the index of past screen text. Live reading is `computer.observe`. | daemon |
| `solo` | enter, exit, toggle, status (Focus Mode) | daemon |
| `capture` | screenshot, record, stop, status, stage, unstage | daemon now; Action's recording is folded in during phase 3 |
| `artifacts` | list, analyze, zoom | daemon |
| `runs` | create, list, get. A run is a receipt plus an artifact directory for one piece of agent work. | daemon |
| `computer` | observe, resolve, click, type, press, drag, scroll, aim, caption, play, verify, lease, release, status | daemon now; the Action helper from phase 3 |
| `canvas` | draw, clear, `actors.*` | daemon (the LAT-002 overlay canvas) |
| `canvas` | pin, unpin, move, focus, list, `notes.*`, `workspaces.*` | Blink helper |
| `voice` | say, stop, pause, resume, skip, seek, list, select, lease, release | Voice helper |
| `voice` | listen, stopListening, simulate, reconnect, status | daemon (`status` also reports the Voice helper) |
| `browser` | open, tabs, snapshot, click, fill, screenshot, console, close, profiles, …, with `target: "agent"` (default) or `"user"` | Action helper for `agent`; daemon (Accessibility) for `user` |
| `intents` | list, run | daemon |
| `history` | list, undo | daemon |
| `deck` | manifest, snapshot, perform. The iPad cockpit's state and actions. | daemon |
| `assistant` | preview | daemon |
| `search`, `settings`, `daemon`, `diagnostics`, `api` | unchanged | daemon |

## Renames

The router keeps each old name as an alias for its new name. `api.schema` and MCP
advertise only new names. There is one exception, listed under breaking changes.

### Core

| Old | New |
| --- | --- |
| `window.focus/move/place/present/resolve` | `windows.focus/move/place/present/resolve` |
| `window.tile` (session only) | merged into `windows.place`, which already takes `session` |
| `window.pick.start` | `windows.pick` |
| `window.assignLayer`, `window.removeLayer`, `window.layerMap` | `layers.assign`, `layers.unassign`, `layers.map` |
| `layer.activate`, `layer.switch` | `layers.activate`, `layers.switch` |
| `space.optimize` | `spaces.optimize` |
| `session.*`, `session.layers.*` | `sessions.*`, `sessions.layers.*` |
| `group.launch/kill` | `groups.launch/kill` |
| `tabStacks.create/delete` and the rest of `tabStacks.*` | `tabs.stack/unstack` and `tabs.*` |
| `lattices.search` | `search.query`. The `lattices.` prefix is reserved for the SDK root. |
| `focus.enter/exit/toggle/status` (Focus Mode) | `solo.enter/exit/toggle/status`. `focus` collides with `windows.focus`. |
| `ocr.recent` | merged into `ocr.history` with `wid` optional |
| `tmux.sessions`, `tmux.inventory` | `tmux.list({ includeOrphans })` |
| `actions.execute` | merged into `intents.run`. A domain named `actions` next to the retired Action helper reads as computer use. `intents.run` takes on the action runtime's receipts, batch and `dryRun`, so `history.undo` keeps working. |
| `intents.execute` | `intents.run` |
| `actions.history`, `actions.undo` | `history.list`, `history.undo` |
| `handsoff.run` | merged into `assistant.preview({ transcript, snapshot })`. Both dry-run the same planner. |
| daemon `browser.*` (user's browser) | `browser.*({ target: "user" })` |

### voice

| Old | New |
| --- | --- |
| `speech.enqueue` | `voice.say` |
| `speech.stop` / `pause` / `resume` / `next` / `seek` | `voice.stop` / `pause` / `resume` / `skip` / `seek` |
| `speech.voices` | `voice.list` |
| `speech.preferredVoice.set` (new in phase 1) | `voice.select({ voice, provider })`, matching `tabs.select`. The helper keeps one choice per provider; `voice.status` reports them as `helper.status.preferredVoices`. An empty `voice` clears that provider's choice. |
| `speech.status` | merged into `voice.status`, which adds `helper: { installed, authorized, reachable, speaking, status }` to the listening state |
| `speech.playback.reserve` | `voice.lease`, plus `voice.release`. The helper has no release method: a lease ends when its connection closes, so `voice.release` closes the client's helper connection. |
| `speech.changed` (event) | `voice.changed` |
| `voice.stop` (stop listening) | `voice.stopListening`. **Breaking**: see below. |

The daemon forwards output verbs to the Voice helper. The helper's own RPC keeps
accepting `speech.*`, so the daemon and helper protocols can change independently.

### computer, capture and apps (daemon `computer.*` and Action merged)

| Old | New |
| --- | --- |
| Action `act_execute` with kind click / type / press-key / drag / scroll | `computer.click` / `type` / `press` / `drag` / `scroll` |
| Action `act_execute` with kind focus-window, and `computer.focusWindow` | `windows.focus({ via: "computer" })` |
| Action `act_execute` with kind open-app, and `computer.launchApp` | `apps.open({ via: "computer" })` |
| `computer.doubleClick`, `computer.rightClick` | `computer.click({ count: 2 })`, `computer.click({ button: "right" })` |
| `computer.typeText`, `computer.typeWindowText`, `computer.typeElement`, `computer.setValue` | `computer.type`, with the target given as a point, window or element |
| `computer.pressKey`, `computer.hotkey` | `computer.press` |
| `computer.elementAction` | `computer.click` on an element target; other AX actions use `computer.click({ action })` |
| Action `observe_snapshot/ocr/vision/ax`, `computer.windowState`, `ocr.snapshot`, `vision.analyzeWindow` | `computer.observe({ mode })` |
| Action `resolve_target`, `computer.prepare` | `computer.resolve` |
| Action `drive_begin/release/status`, `session_create`, `driver_identify` | `computer.lease` (identity and task go in its arguments) / `computer.release` / `computer.status` |
| Action `drive_aim`, `computer.magicCursor`, `computer.showCursor` | `computer.aim` |
| Action `drive_note`, `drive_play` | `computer.caption`, `computer.play`. Not `note`, which collides with `canvas.notes`. |
| Action `health` | `computer.status` |
| Action `record_start/stop/status`, `capture.recordWindow/Region`, `capture.stopRecording` | `capture.record` / `capture.stop` / `capture.status` |
| `capture.screenshotWindow/Region/Display` | `capture.screenshot({ target })` |
| Action `stage_set/clear/status` | `capture.stage` / `capture.unstage` / `capture.status` |
| Action `artifacts_list`, `runs.artifacts` | `artifacts.list` |
| `vision.analyzeArtifact`, `capture.zoomArtifact` | `artifacts.analyze`, `artifacts.zoom` |
| `computer.demoScout`, `computer.demoTerminal` | removed from the API; they become scripts |

### canvas

Provisional until Blink has an RPC (phase 4):

| Old | New |
| --- | --- |
| `overlay.publish`, `overlay.clear` | `canvas.draw`, `canvas.clear` |
| `overlay.actor.publish/moveTo/visibility/hud` | `canvas.actors.put/move/show/attach` |
| Blink `show` / `rm` / `desk open` / `desk move` / `ls` | `canvas.pin` / `canvas.unpin` / `canvas.focus` / `canvas.move` / `canvas.list` |
| Blink `new` / `cat` / `write` / `append` / `search` | `canvas.notes.create/get/write/append/search` |
| Blink `workspace init` / `workspace notes` | `canvas.workspaces.create` / `canvas.workspaces.list` |

## Breaking changes

- **`voice.stop` changes meaning.** It used to stop listening; now it stops
  speaking. There is no alias. The daemon has no in-repo RPC callers (the Swift
  code already calls `stopListening()`); `lattices voice stop` and the voice docs
  are updated in the same change. For one release, a `voice.stop` call made while
  listening and not speaking returns a hint pointing to `voice.stopListening`.

## Packaging: helpers inside Lattices.app

```
Lattices.app/Contents/Helpers/
  Voice.app     dev.lattices.Speech   (bundle ID frozen)
  Blink.app     dev.arach.blink
  Action.app    dev.lattices.Action   (no longer shipped on its own)
```

- **Bundle IDs do not change.** All three shipped on 2026-09-15, and TCC grants,
  preferences, Keychain approvals and the lease token directory are keyed to them.
- **Discovery** prefers the embedded helper and ignores standalone copies in
  `/Applications` or `~/Applications`. The Apps menu can offer to move them to the Trash.
- **Signing** goes inside out: each helper first, then Lattices.app, under team
  `2U83JFPW66`, with one notarization.
- **Lifecycle** follows LAT-011. Helpers launch on demand or from the Apps menu,
  and quitting Lattices does not kill them.
- **Size:** Voice does not embed its Phonon model. The model downloads to
  `~/Library/Application Support/Speech/Phonon` on the first Phonon request.
- **Action stops shipping on its own.** Its DMG, MCP server, plugins and
  `lattices.dev/action` are retired after phase 3, once `lattices mcp` serves
  `computer_*`, `capture_*` and `browser_*`. The per-helper DMG workflows and the
  installer are removed once the embedded build ships.

## Phases

1. **Voice.** Rename Speech to Voice (display name, executable, strings, skill),
   embed it, add the `voice.*` output verbs, rename `voice.stop` to
   `voice.stopListening`, and fix the dark-mode text in the controls window.
2. **Router.** Add the alias table, apply the core renames, and update
   `api.schema`, the CLI, the SDK and `skills/lattices`.
   *Status (2026-10-08):* the alias table (`MethodAliases.swift`), the core
   renames, and the `window.tile`, `tmux.inventory` and `ocr.recent` merges are
   in; `api.schema` lists aliases under `aliases`, and the CLI and LatticesKit
   retry old names against older daemons. Still to do: `actions.execute` into
   `intents.run`, and `handsoff.run` into `assistant.preview`. Both change
   behavior, not just names.
3. **Computer.** Audit the daemon's `computer.*` against Action one verb at a time,
   port daemon-only verbs into Action, make Action the backend, serve
   `computer_*` / `capture_*` / `browser_*` from `lattices mcp`, embed Action, and
   retire the standalone product.
4. **Canvas.** Add a Blink RPC, forward the Blink verbs, move `overlay.*`, and embed Blink.
5. **Docs and skills.** One skill with a section per domain; update docs,
   llms.txt and the site.

## Decisions (2026-09-23)

- `voice.stop` stops speaking; `voice.stopListening` stops listening.
- Observe is one verb with a mode.
- `canvas` is one domain: Blink's persistent pins and notes, plus the overlay canvas.
- Action stops shipping as its own product. Its native code becomes the only backend
  for `computer.*`, and the daemon's duplicates are removed as they are ported.
- Helper bundle IDs are frozen.
- An operation has one verb in the domain it acts on, and `via` chooses native (the default) or computer use. Computer use does not duplicate window, app or space verbs.
- Rename only on a real collision (rule 7). Kept despite the cold test, with a
  "use when" line instead: `windows.present`, `windows.move`, `mouse.find`,
  `desktop.snapshot`, `deck.*`, and the separate `capture` and `computer.observe`.
- `windows.tile` merges into `windows.place`; `ocr.recent` into `ocr.history`;
  `handsoff.run` into `assistant.preview`; `actions.execute` into `intents.run`.
- Focus Mode becomes `solo.*`. `computer.note` becomes `computer.caption`.
  `voice.use` becomes `voice.select`.
- `browser` is one domain with `target: "agent"` (default) or `"user"`.

## Open questions

None open. `solo` was the one new word in the last pass. The alternatives were
`focusMode`, which breaks rule 1, and `spotlight`, which collides with macOS
Spotlight. Review kept it: it is the standard mixer term for isolating one
channel.
