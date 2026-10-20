---
title: Stage
description: Present listed windows on a flat backdrop for a clean take
order: 9
---

Action owns the look of a take. The wallpaper is never written.

`action.stage.set` is the primitive: declare the world, Action makes it so.

```json
{
  "mode": "drape",
  "color": "0e0d0a",
  "subjects": [
    { "bundleId": "to.talkie.agent.dev", "title": "Settings" },
    { "bundleId": "com.googlecode.iterm2" }
  ]
}
```

## What it does

- Puts up a flat color sheet at ordinary window level (`NSWindow.Level.normal`).
- `AXRaise`s only the listed windows. Same level is what lets them sit on the sheet.
- Reads on-screen window order in the staged bounds (or the sheet's frames). The scene is the listed subjects on the sheet. Anything else above the sheet, including the driver terminal, is an intruder unless it was listed.
- Fails `stage.set` if a listed subject is still buried or a non-subject occupies the scene. It raises again a couple of times before refusing. The sheet stays up so `stage.status` can show who is actually on top.
- Leaves every other app alone. No hiding. No desktop-picture writes.
- Dies with the process that asked for it. `action.stage.clear` takes it down on purpose.

## Lifetime

`action.stage.clear` is the intended teardown. Two backstops cover the case where it never runs:

- **Owner.** A drape set through MCP watches the MCP server and dismisses itself if that server dies. A drape set through the CLI cannot do this: the CLI process exits the moment the sheet is up, so a drape watching it would take itself down immediately. CLI drapes are detached.
- **`seconds`.** An optional lifetime after which the drape dismisses itself. The CLI defaults to 1800; pass `--seconds` to change it. MCP omits it by default because the owner check already covers a dead server.

`stage status` reports `owner`, `pid`, whether the drape is still up, and `scene`: the windows actually on top of the sheet.

`mode: "space"` keeps the sheet on the current Space only. Instantiate subjects on that Space; windows on other Spaces will not compose into the frame.

`level: "desktop"` is the other sheet in the repertoire. It sits under all app windows and is the wrong default for a take.

## Surfaces

- MCP: `action.stage.set`, `action.stage.clear`, `action.stage.status`
- CLI: `bun packages/cli/src/main.ts stage set|clear|status`

To work an app out of the user's sight instead of staging it for a take, see [Agent layer](/action/docs/agent-layer).
