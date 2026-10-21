<div align="center">

# Canvas

### Put notes where your work is.

Native floating notes for macOS, with an agent-first CLI over the same local Markdown files.

[![npm](https://img.shields.io/npm/v/%40arach%2Fblink?style=flat-square&color=38bdf8&label=npm)](https://www.npmjs.com/package/@arach/blink)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white)](https://lattices.dev/canvas)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-native-111827?style=flat-square)](https://github.com/arach/lattices/releases)
[![MIT](https://img.shields.io/badge/license-MIT-111827?style=flat-square)](https://github.com/arach/lattices/blob/main/products/blink/LICENSE)

</div>

<p align="center">
  <a href="https://lattices.dev/canvas">
    <img src="https://raw.githubusercontent.com/arach/lattices/main/products/blink/landing/public/hero-desk.png" width="900" alt="A borderless Canvas note floating over the macOS desktop" />
  </a>
</p>

<p align="center"><sub>A real Canvas note on the desktop: native dark glass, edge-to-edge Markdown, exactly where you left it.</sub></p>

## Zero to a spatial note

```sh
npm install -g @arach/blink  # install the CLI + app installer command
canvas app install            # install the latest stable Canvas (or legacy Blink) app
canvas app open               # launch the installed menubar app

# Create content, presentation, and placement in one atomic write.
canvas present q3-plan $'# Q3 plan\n\nShip something people love.' \
  --slot 6 --accent '#7dd3fc'
```

The note is immediately available to Canvas. If the app is open, it appears and
updates live; otherwise it is waiting in the same place the next time Canvas
launches.

## Why Canvas

| Principle | What it means |
|---|---|
| **Spatial by default** | Notes are borderless floating panels with per-note position, size, style, and grid placement. |
| **Made for agents** | Predictable verbs, JSON output, stdin support, and one command for content + presentation + placement. |
| **Local-first** | One human-readable Markdown file per note. No side database and no cloud account. |
| **Native where it counts** | Swift/AppKit panels, signed native CLI, global hotkeys, and a tiny Node shim for npm. |

## Write notes and manage the app

### `canvas` — write from anywhere

Existing `blink` commands accept the same arguments and access the same files.

```sh
canvas ls                                         # recent notes
canvas new "grocery run"                          # create
canvas cat q3-plan                                # read clean Markdown
canvas search "launch"                            # search titles + content
canvas present q3-plan "# Q3" --style focus       # content + look
canvas type q3-plan "One more thing…"              # visible typed reveal
canvas write q3-plan < revised.md                  # quiet replacement
canvas rm grocery-run                             # delete
```

Every mutation uses Canvas's atomic file store. The running app reconciles
external writes and reflects them across the menubar, palette, and open panels.

### `canvas app` — manage the macOS app

```sh
canvas app install   # fetch, validate, and install/reinstall the latest compatible stable app
canvas app update    # explicitly refresh the installed app
canvas app open      # launch the installed menubar app
canvas app path      # print the detected installed app path
```

The `canvas-app`, `blink`, and `blink-app` commands remain available. The npm
package name stays `@arach/blink` for compatibility. The installer accepts stable
`canvas-v` and legacy `blink-v` releases, validates the original bundle identity
and Developer ID team, and stages the replacement on the destination volume.
It waits for the app to finish saving and quit before replacing it, and restores
the previous app if the swap fails. An unrelated app with the same filename is
never replaced. Existing `Blink.app` installs and their data remain discoverable.

## An API made of files

```text
you or your agent
       │
       ▼
  canvas present ──────► ~/Library/Application Support/Blink/Notes/q3-plan.md
                                      │
                                      ▼ live reconcile
                          menubar · palette · floating panel
```

Notes carry their own metadata in YAML frontmatter, so presentation travels
with the content:

```md
---
id: q3-plan
blink:
  style: focus
  accent: "#7dd3fc"
  slot: 6
---
# Q3 plan

Ship something people love.
```

Set `CANVAS_HOME` to isolate a workspace for testing or automation. `BLINK_HOME`
remains the fallback. The default data directory and `blink` frontmatter keys
keep their original names so existing notes and settings remain available. Add `--json`
when another program needs structured output.

## Small package. Native core.

- **Zero runtime dependencies** and **no install lifecycle scripts**.
- The signed arm64 Swift CLI ships inside the tarball—there is no binary fetch
  when you run `canvas`.
- The macOS app is distributed separately as a signed and notarized DMG.
- Requires macOS 14+, Apple Silicon, and Node.js 18+ for the npm shims.

---

<p align="center">
  <a href="https://lattices.dev/canvas">Website</a> ·
  <a href="https://github.com/arach/lattices/blob/main/products/blink/docs/cli.md">CLI reference</a> ·
  <a href="https://github.com/arach/lattices/blob/main/products/blink/docs/config.md">Configuration</a> ·
  <a href="https://github.com/arach/lattices/releases">Releases</a> ·
  <a href="https://github.com/arach/lattices/issues">Issues</a>
</p>

<p align="center"><sub>macOS spatial notes for humans and the agents working beside them.</sub></p>
