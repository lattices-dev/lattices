# AGENTS.md

This tree is Canvas (formerly Blink) inside the Lattices monorepo
(`products/blink`). Keep `Canvas.app`, NoteStore, and the panel runtime separate
from the Lattices menu bar app even though they share this repository and website.

## Product and release names

Current source builds produce `Canvas.app` (executable `Canvas`) and the `canvas`
CLI. SwiftPM products `CanvasApp` and `canvas` are canonical; `BlinkApp` and
`blink` remain executable aliases over the same targets. The family CLI exposes
`lats canvas`, with `lats blink` as an alias. It forwards to this product without
sharing the Lattices app lifecycle.

The 2.3.0 release contract uses `canvas-v2.3.0` in
`lattices-dev/lattices`: `Canvas.dmg` contains `Canvas.app`. Its legacy
`blink-v2.3.0` channel and the `arach/blink` `v2.3.0` mirror use a distinct
`Blink.dmg` containing a real `Blink.app`. Both app directories have the same
signed contents, visible Canvas name, and identity. The npm package remains
`@arach/blink`; both CLI names are included. Check publication and the selected
artifact before describing installed behavior. See `docs/release.md`.

Keep existing identity and storage boundaries unchanged: macOS bundle ID
`dev.arach.blink`, iOS bundle ID `dev.arach.blink.mobile`, the default
`~/Library/Application Support/Blink` directory, `blink.sock`, `blink.*`
frontmatter, the `blink://attachments/` scheme, settings keys, Keychain items,
and Bonjour/peer protocol identifiers. `system.hello` retains `app: "Blink"` and
adds `displayName: "Canvas"`. The rename requires no note or settings migration.

## Canvas in use

Canvas is a native macOS spatial note-taking app. It is not a document library
with detachable windows: **the note is the window, and the desktop is the
workspace**.

The human loop is capture → place → recall:

1. Create or find a note from the menubar popover, command palette, or global
   new-note hotkey.
2. The note opens as its one floating `NSPanel`; reopening it focuses that panel
   rather than creating a duplicate.
3. Move, resize, shade, or focus panels to arrange a working set. Canvas restores
   each note to the same place.
4. Edit and read in the same panel. The menubar popover and command palette are
   launchers, not alternate document windows.

Canvas is an `LSUIElement` menubar-only app: floating note panels + menubar
popover + command palette, with no Dock icon and no main/library window. The v1
Tauri app remains at tag `v1-final`; port lessons and behavior, never its code.

When operating Canvas rather than changing its code, use `canvas` (or the
compatible `blink` command) for notes and edit `config.json` for behavior and
appearance. Drive the GUI only when a
task specifically requires the live visual surface. The installable agent skill
is `skills/blink` in the Lattices catalog:

```bash
npx skills add arach/lattices --skill blink --global --yes
```

## State model

The markdown files are the durable truth for notes. Runtime note state
converges through one path:

```text
panel edits / popover actions → PanelManager / AppModel → NoteStore → atomic .md
CLI / external writes → same .md → directory watcher → NoteStore.reconcile()
NoteStore notifications → AppModel snapshot → popover / palette / open panels
```

- Notes live at `~/Library/Application Support/Blink/Notes/<id>.md`, where `id`
  is a unique title-derived slug. Body and metadata travel together in each
  markdown file; metadata is YAML frontmatter. Unknown frontmatter must survive
  round trips verbatim. UUIDv5 identity is derived only for v1 compatibility.
- `NoteStore` owns note mutations and the in-memory index. `AppModel` mirrors it
  for UI surfaces; it is not a second store.
- `PanelManager` owns live windows, pending editor text, one-panel-per-note
  identity, geometry, and save flushing. Do not bypass it for panel lifecycle.
- Exact per-device panel frames (`NSWindow` frame autosave), the open-panel set,
  and each note's read/edit mode live in `UserDefaults`. Portable
  `blink.slot` frontmatter is placement intent; the autosaved frame is the
  device-specific position. `NotePanel` suspends frame autosave while physics
  owns a drag/fling/shade and persists the unshaded resting frame once settled.
- External writers are first-class. The directory watcher calls
  `NoteStore.reconcile()`, producing the same notifications as in-app edits.
- `config.json` owns behavior and appearance and hot-applies independently of
  note state. The first nonempty value of `CANVAS_HOME`, then `BLINK_HOME`,
  overrides the file-backed root (notes, config, attachments, ledger, and socket)
  for tests/agents; it does not redirect `UserDefaults`. Use
  `BlinkPaths.home(environment:)` and `BlinkPaths.hasHomeOverride(environment:)`
  for this policy. The Mac peer host is disabled with either nonempty override
  so sandbox notes cannot inherit the production device identity or trust list.
- Preserve explicit `behavior.mobileAccess` choices. For an absent key, only a
  valid, nonempty production Keychain approval list enables access. New installs,
  malformed intent or trust, and read failures stay off. Deriving this choice
  must not rewrite config/preferences or create identity. A later settings save
  stores the effective choice explicitly; per-request trust checks remain required.

## Source-of-truth order

When documents disagree, use this order:

1. Current code and tests describe source behavior. Verify released behavior
   against the selected release; source changes are not publication evidence.
2. This file's hard requirements are non-regression constraints.
3. `docs/cli.md`, `docs/config.md`, `docs/workspaces.md`, and `docs/release.md`
   describe agent-facing or release surfaces; respect their source/release labels.
4. `docs/placement.md` is mixed-status: the grid primitive is shipped; its
   live-plane collision, scene, and tidy semantics are proposed.
5. `docs/v2-plan.md`, `docs/v2-ui-map.md`, and
   `docs/notes-representation.md` are local, untracked design references absent
   from a fresh clone. They contain intent and history and may lag the code.
6. `docs/agent-api.md` and `docs/agent-integration.md` are proposals, not
   implemented surfaces.
7. `docs/functionality-v1.md` is a local, untracked v1 inventory and
   scope/lessons donor, not a description of the v2 codebase.

Other useful references:

- UI studies / visual spec: `design/studio` (tracked shared-Studio app;
  `bun dev` → `localhost:3060/studio`).
- The CLI operates on the same files as the app:
  `canvas ls/cat/new/present/type/write/search/rm/path/workspace`; see
  `docs/cli.md`.
- Agents configure Canvas by editing
  `~/Library/Application Support/Blink/config.json`, not by driving Settings;
  see `docs/config.md`.
- `canvas workspace` defines a named treatment in `config.json`; membership is
  one `blink.workspace` frontmatter key. See `docs/workspaces.md`. Brands are
  generic treatments—never hardcode a specific product identity into Canvas.

## Where changes belong

- `Sources/BlinkApp` — AppDelegate/status item/popover, command palette,
  AppModel, PanelManager, NotePanel, config hot reload, and WebBridge.
- `Sources/BlinkCore` — pure Swift with no AppKit: note model and identity,
  frontmatter, atomic file storage, NoteStore, treatments, workspaces, and grid
  math / panel physics.
- `Sources/BlinkCLI` — `swift-argument-parser` CLI over BlinkCore. `BlinkPaths`
  keeps the app and CLI on the same locations.
- `Sources/BlinkPeer` — encrypted Multipeer Connectivity discovery, pairing,
  and snapshot transport shared by macOS and iOS. Bonjour advertises presence;
  new devices request explicit Mac approval inside an encrypted session, and
  remembered device access remains revocable from the Mac. Both sides keep
  their private identity and trust material in non-synchronizing Keychain
  storage, never preferences; the iOS seed and note cache do not travel in
  device backups.
- `apps/ios` — XcodeGen source for the read-only, offline-first iPhone/iPad
  companion. It consumes the local BlinkCore and BlinkPeer package products.
- `Tests/BlinkCoreTests` — narrow tests for storage, frontmatter, identity,
  workspaces, grid placement, and panel physics; run the matching suite for
  domain changes.
- `web/editor` — vanilla CodeMirror 6 (no React), bundled into one
  `dist/editor.html` and hosted by each note panel. Load-bearing bridge contract:
  `ready` / user-only `contentChanged` / `saveRequested` → native;
  `setContent` / `getContent` / `focus` ← native.
- Generic panel or web-bridge primitives should be shaped for eventual
  HudsonKit upstreaming once proven here.

## Commands

```sh
swift build                  # resolves pinned Hudson (BLINK_HUDSON_SOURCE=path for local checkout)
swift test                   # BlinkCore tests
swift build --product canvas # notes CLI (blink remains a build alias)
(cd web/editor && bun install && bun run build)   # editor bundle
./scripts/run-app.sh --debug --restart            # bundle dist/Canvas.app + launch
(cd apps/ios && xcodegen generate)                 # generate BlinkMobile.xcodeproj
```

## Hard requirements (inherited from v1 bugs)

- Flush pending saves on note-switch, panel-close, and quit. Never trust a
  debounce alone.
- All note writes are atomic: temp file + `fsync` + rename.
- Note metadata lives in the markdown file's frontmatter, never only in a side
  index. Preserve foreign frontmatter verbatim.
- One panel per note—opening an open note focuses it.
- Panel geometry persists per note and restores exactly; never scramble a
  layout.
- Note mutations flow through `NoteStore` → notifications → `AppModel`; never
  mutate one UI surface as the source of truth.
- `contentChanged` fires on user edits only. Programmatic `setContent` must
  never echo (the v1 cross-note corruption bug).

## Conventions

- `AGENTS.md` and `CLAUDE.md` mirror the same instructions (apart from their
  title); keep them in sync.
- For larger initiatives/features, survey the ecosystem first: check HudsonKit
  (`../../../hudson/packages/native/apple/HudsonKit`) for reusable primitives and
  talkie / scout (`../../../talkie`, `../../../openscout`) for proven patterns.
  Small widgets/tweaks do not need the survey. This tree is already inside
  lattices at `products/blink`.
- Log prefix `[BLINK]` via HudLogger (HudsonObservability).
- Hyper = ⌃⌥⇧⌘. Global hotkeys use Carbon `RegisterEventHotKey` and do not
  require Accessibility permission.
- User-visible name is "Canvas"; retain existing storage and protocol identifiers.
- GUI verification: LSUIElement apps are invisible to System Events' "visible
  processes." Activate Canvas before synthesized keystrokes, and use `AXRaise`
  for restored panels.
