---
title: Agent API proposal
description: Proposed design for a broader Blink agent API. Not implemented; see the agent socket API for the shipped subset.
---

# Blink v2 — The Agent API (live plane, over a Unix socket)

> **Status: proposal.** This document is a design proposal from July 2026, not a
> description of the shipped app. Blink implements only a small subset of it.
> For the methods that exist today, see [Agent socket API](/blink/docs/api).

> Draft 2026-07-15. Companion to `notes-representation.md` (what a note *is* and
> where its bytes live) and `cli.md` (the `blink` CLI, agent surface layer 2).
> This doc specifies **layer 2.5**: a live, bidirectional query/command surface
> the *running app* exposes over a Unix domain socket. Opinionated on purpose —
> argue with it before it's built. **Status: proposed.** A subset now ships (see the status note above). The
> rendering/safety substrate it depends on (§7) *is* implemented.

The one-line thesis:

> **Blink has two planes. The *durable* plane is the files — what a note is and
> how it prefers to look and sit (frontmatter). The *live* plane is the running
> app — what's actually on screen right now: which panels are open, where,
> focused, in what order. Files can't answer the second question; only the app
> can. The socket is the app's live face, and the verbs to change it.**

An agent uses the socket to *act*; the app persists the durable part of that
action back into frontmatter and `workspace.json`. That loop is the whole design.

---

## 1. Why a socket at all

The filesystem is already an API (layer 1), and the `blink` CLI wraps it with
atomic writes and slugging (layer 2). Both are about *files*. Neither can tell an
agent:

- which notes are **open** as panels right now,
- **where** each panel sits (frame, screen, grid slot, z-order, focus, shade),
- and neither offers a **low-latency, bidirectional, streaming** channel — every
  CLI call is a fresh process, and file writes race the app.

That runtime state lives only in `PanelManager` in memory. The socket exposes it,
lets an agent issue live desk verbs (open/move/focus a panel), and lets an agent
**subscribe** to changes (a spatial assistant reacting to where you put things).
It is also the seam a future MCP server sits on — MCP becomes a thin typed face
over the same in-process calls, never a second source of truth.

Crucially, the socket is the **serialization point for participating clients**
(this reframes `notes-representation.md` open-question #5 — it does *not* by itself
create "one writer, no races," a claim the review rightly rejected). `PanelManager`
holds unsaved editor text *outside* `NoteStore`, so a naive `notes.append` against
stale store content can be lost to a debounce flush. The socket therefore routes
every mutation through a coordinator that knows current panel text, and mutation
methods carry an opaque note **revision** (`ifRevision`) so a stale write is
rejected, not silently applied. Direct file editors and sync tools remain possible
— they're simply *non-participating*, and reconcile on the next FS event. A
request whose response is lost must never be blindly retried as a file write:
mutation IDs make the outcome unambiguous. See §11.1.

### Where it sits in the layering

```
layer 1  files            the .md files ARE the API                (always)
layer 2  blink CLI        atomic writes, slugging, --json          (shipped)
layer 2.5 Unix socket     LIVE query + command + subscribe         (THIS DOC)
layer 3  MCP server       typed conversational face over 2.5       (later, if earned)
```

Each layer is a nicer skin over the same file truth. An agent can always drop
down a layer to plain files when the abstraction is in the way.

---

## 2. The socket

| Property | Value |
|---|---|
| Path | `$BLINK_HOME/blink.sock` (honors `BLINK_HOME`; default `~/Library/Application Support/Blink/blink.sock`) |
| Type | `AF_UNIX`, `SOCK_STREAM` |
| Perms | `0600`, owner-only |
| Lifecycle | created on app launch, removed on clean quit; a stale socket from a crash is `unlink`'d (under a per-home lock, with inode-ownership checks to avoid a second-instance race) and recreated on next launch |
| Discovery | **successful connect + `system.hello` handshake**, never "the file exists" — a stale/half-open socket lies. Only an unambiguous pre-send connection refusal falls back to files/CLI |
| Trust | local only, no network. Verify the peer with `getpeereid` (owner UID only) and a secured parent directory; same trust boundary as the note files (see §6) |

Why under `$BLINK_HOME` rather than a temp/runtime dir: it's the one location the
app and every agent already agree on (same rule as `config.json` and `Notes/`),
and it honors the `BLINK_HOME` sandbox override that tests and experiments use.
**Caveat (review):** Darwin caps a Unix socket path at ~104 bytes, and an
arbitrary `BLINK_HOME` can exceed that — so the real path may need to be a hashed
per-user runtime path with `$BLINK_HOME/blink.sock` as a documented default, not a
hard guarantee.

---

## 3. Protocol — newline-delimited JSON-RPC

One JSON object per line, request and response. JSON-RPC 2.0 shape for
familiarity; trivially drivable from `socat`, `nc`, or any language, and easy to
eyeball. Boring on purpose.

```jsonc
→ {"id":1,"method":"placements.list"}
← {"id":1,"result":[ /* … */ ]}

→ {"id":2,"method":"panels.open","params":{"id":"q3-planning","slot":6}}
← {"id":2,"result":{"id":"q3-planning","frame":{"x":1240,"y":720,"w":380,"h":460}}}

→ {"id":3,"method":"nope"}
← {"id":3,"error":{"code":-32601,"message":"unknown method: nope"}}
```

- **Conform, or don't claim it.** To *be* JSON-RPC 2.0, every message carries
  `"jsonrpc":"2.0"`, and server-pushed events are **notifications** (a `method` +
  `params`, no `id`) — not bare `{"event":…}` objects. If we keep the lighter
  shape, call it "custom JSONL RPC," not JSON-RPC. Pick one (leaning: real 2.0).
- **`system.hello` first**: protocol + schema version and a server instance ID.
  This is version negotiation, **not** authentication (the socket's `0600` +
  `getpeereid` is the auth).
- `id` echoes back; specify allowed ID types, batch behavior, per-connection
  ordering, and a UTF-8 + max-line-length cap.
- Errors use JSON-RPC codes plus a human `message`, and a documented set of
  **domain** error codes (unknown id, stale revision, validation failure).
- Requests are size-capped and rate-limited (a runaway agent must not wedge the
  app); over-cap requests get an explicit error, never a silent truncation.

---

## 4. Methods

### 4.1 Read — "all the docs" and "all the placements"

| Method | Returns |
|---|---|
| `notes.list` | **all the docs** — served live from the in-memory `NoteStore` (no disk scan): `[{id, title, tags, pinned, created, updated, size, style?, sheet?, slot?, path}]` — the CLI `ls --json` shape, plus presentation keys |
| `notes.get {id, content?}` | one note; `content:true` adds the raw body + `extraFrontmatter` |
| `placements.list` | **all the placements** — the live desk (see §4.2) |
| `workspace.get` | the serializable layout as it persists to `.blink/workspace.json` (open list + per-note geometry) |
| `config.get` | the current effective `config.json` (mirrors the hot-reloaded config in memory) |

### 4.2 `placements.list` — the runtime truth no file holds

Almost pure serialization over state `PanelManager` already tracks
(`openPanelsByID`, `keyNotePanel`, `panel.frame`/`.screen`, z-order via
`NSApp.orderedWindows`, `sheetTemplate`, `currentMode`):

```jsonc
{
  "id": "q3-planning",
  "frame": {"x":1240,"y":720,"w":380,"h":460},   // AppKit points, screen coords
  "screen": {"label":"Built-in Retina Display","frame":{"x":0,"y":0,"w":1728,"h":1117}},
  "slot": 6,          // resolved 3×3 grid cell (1–9), or null if free-placed
  "mode": "read",     // read | edit
  "sheet": "dotted",  // resolved sheet template
  "shaded": false,    // shade-to-bar state (M3)
  "focused": true,    // is key window
  "z": 0              // 0 = frontmost among Blink panels
}
```

### 4.3 Command — the app acts

Every mutating method flows through the same `NoteStore` / `PanelManager` paths
the GUI uses, so the hard-requirement invariants hold automatically (atomic
writes, flush-on-close, one-panel-per-note, geometry persistence, no
`contentChanged` echo).

| Method | Effect |
|---|---|
| `notes.create {content, open?}` | create (atomic, slugged); `open:true` also deploys a panel |
| `notes.append {id, text}` | append a line — surfaces as the "visible hand" typed reveal in an open panel |
| `notes.update {id, content}` / `notes.delete {id}` | as the CLI, but in-process |
| `panels.open {id, mode?, slot?}` | deploy a panel, optionally into a grid cell |
| `panels.move {id, slot | frame}` | relocate (uses `NotePanel.animateLock` snap) |
| `panels.close {id}` / `panels.focus {id}` | dismiss / raise-and-key |
| `panels.shade {id, on}` / `panels.setMode {id, mode}` | shade-to-bar / flip read↔edit |
| `config.set {patch}` | JSON merge-patch `config.json`; the app hot-applies (the "Send to Blink" verb) |

### 4.4 Subscribe — watch the desk live

```jsonc
→ {"id":9,"method":"events.subscribe","params":{"topics":["notes","placements"]}}
← {"id":9,"result":{"subscribed":["notes","placements"]}}
← {"event":"note.updated","id":"standup"}
← {"event":"panel.moved","id":"q3-planning","frame":{ … }}
← {"event":"panel.focused","id":"standup"}
← {"event":"panel.opened","id":"idea"}  ← {"event":"panel.closed","id":"idea"}
```

Backed by the existing `NotificationCenter` note events plus new panel hooks
(`windowDidMove`/`DidBecomeKey`/open/close in `PanelManager`). Lets an agent
react to the spatial layout without polling.

---

## 5. The durable ↔ live bridge

An agent calls `panels.open {id:"q3-planning", slot:6}`. The app deploys the
panel, then splits persistence **by durability**:

- the **intent** (`slot: 6`) is written back to the note's **frontmatter** —
  portable, git-able, survives restart and travels to another machine;
- the resulting **pixel frame** is recorded in **`.blink/workspace.json`** — this
  device only (pixel frames don't transfer).

Reload from files alone and the note still *wants* cell 6. Reload on the same
machine and it lands exactly where it was. `rm -rf .blink/` loses the pixels,
keeps the intent. The representation's one invariant holds: **everything under
`.blink/` is disposable; nothing under `Notes/` is.**

This is why the socket is not "another store" — it's a *controller* that reads
live state and writes each change to whichever plane owns its durability.

---

## 6. Trust & safety model

**Assumption (owner's call, 2026-07-15): high trust.** Blink is local software
that the user and *their own* agents operate. The socket is `AF_UNIX`, `0600`,
owner-only, no network — the same trust boundary as the note files. Any process
that can open the socket can already read and write `~/…/Blink/Notes`. So the
socket grants no authority the filesystem didn't already grant.

Consequences of that assumption, made explicit:

- No auth token, no capability handshake in v1. (Reserve a `hello`/version
  negotiation slot for later, but don't gate on it.)
- Note content is treated as trusted (see §7) — no server-side sanitization.
- The one hard guard is **resource**, not authority: request size caps + rate
  limiting so a buggy agent can't wedge the UI thread.

If the trust boundary ever changes (a shared vault, a remote bridge, an
untrusted agent), this section is where the capability model gets added — and
§7's CSP decision gets revisited at the same time.

---

## 7. Rendering & safety substrate (implemented)

The socket makes agents first-class note *authors*, which stresses the read-mode
renderer (`marked` in `web/editor/src/reader.ts`). Validated and hardened
2026-07-15:

- **Navigation policy — DONE, deny-by-default** (`WebBridge.decidePolicyFor`).
  Previously the webview had a `WKNavigationDelegate` with *no* policy, so clicking
  any link navigated the whole webview away from `editor.html` and destroyed the
  editor. Now: in the **main frame** only the editor document itself (matched by
  path) + its own `#fragment` jumps may load; only a genuine `.linkActivated`
  click hands off — `blink://open/<id>` routes to the note, allowlisted schemes
  (`http`/`https`/`mailto`/`tel`/`file`) open via `NSWorkspace`. Scripted `.other`
  navigations, `about:`, `javascript:`, `data:` are cancelled. (Hardened after the
  review, which caught the original "allow all `file:`/`about:`, open all else"
  as deny-too-little.)
- **iframes — ALLOWED for `http(s)` (owner's call)**. Subframe navigations to
  remote `http(s)` are permitted so notes can embed remote HTML; a cross-origin
  frame is sandboxed from `window.blink`, so the native bridge stays unreachable.
  `file:`/`about:`/`data:`/`javascript:`/`srcdoc` subframes stay denied (those
  could reach the bridge or run same-origin script). A per-host allowlist in
  config is the tightening path if "any https origin" is later too broad.
- **`blink://` scheme — DONE + hardened** (`BlinkAssetSchemeHandler`).
  `blink://attachments/<path>` serves images from `$BLINK_HOME/attachments` with a
  lexical `..` guard **plus symlink resolution + re-containment check** (the
  original lexical-only guard was bypassable by a symlink), a **regular-file**
  requirement (no FIFO stall), and a **64 MB cap** (`Data(contentsOf:)` is
  whole-file). `blink://open/<id>` is intercepted by the nav policy and routed to
  `NoteStore`.
- **Wiki-links — DONE**. A `marked` extension renders `[[id]]` / `[[id|Label]]`
  as `blink://open/<id>` links, closing the loop with `panels.open`. (Escaping
  verified correct in review.)
- **CSP — still skipped** under the §6 high-trust assumption *and* the iframe
  decision above. Consequence, stated plainly: **every byte of note content and
  every referenced remote resource is trusted, executable input.** Main-frame
  inline handlers (`<img onerror=…>`) still run with bridge access; remote images
  and now iframes still beacon. Accepted deliberately. If the trust boundary ever
  changes (shared vault, untrusted agent), a nonce-based `script-src` + `img-src`/
  `frame-src` allowlist is the ready fallback and this bullet is where it lands.

---

## 8. Swift integration points (sketch, for the build)

- **`BlinkSocketServer`** (new, `Sources/BlinkApp`) — owns the `AF_UNIX` listener
  + `DispatchSource` accept loop, sibling to the existing `config.json` watcher
  and `DirectoryWatcher`. Per-connection line framing + JSON-RPC dispatch. Survey
  HudsonKit first for an IPC/RPC primitive to reuse or upstream (per the CLAUDE.md
  "survey the ecosystem first" convention); hand-roll only if none fits.
- **Read serializers** — `notes.*` off `AppModel`/`NoteStore.all()`; `placements.list`
  off `PanelManager.openPanelsByID` + `keyNotePanel` + `NSApp.orderedWindows`.
- **Command dispatch** — `panels.*` call straight into `PanelManager`
  (`openPanel`, `animateLock`, `close`, `makeKey`); `notes.*` into `NoteStore`;
  `config.set` merges into the `config.json` the watcher already hot-applies.
- **Events** — fan `NotificationCenter` note events + new panel hooks out to
  subscribed connections.

---

## 9. Build order (proposed)

1. **Read-only first**: `notes.list` + `placements.list` + `events.subscribe`.
   Proves the live plane end-to-end (an agent can *see* the desk) with zero
   mutation risk.
2. **Note commands**: `notes.create/append/update/delete` — parity with the CLI,
   in-process, resolving the concurrency story (open-question #5).
3. **Panel commands + the durable/live bridge**: `panels.*`, `config.set`, and
   the frontmatter/`workspace.json` split from §5.
4. **MCP face** (layer 3) — only if agents need typed, multi-step, conversational
   interaction the socket's raw RPC doesn't give.

---

## 10. Open questions

1. **Framing**: newline-delimited JSON-RPC vs. length-prefixed vs. plain JSONL
   events? (Leaning NDJSON-RPC for inspectability.)
2. **Coordinate space** in `placements.list`: AppKit points in global screen
   coords (proposed) vs. a normalized per-screen fraction that survives display
   changes?
3. **Subscribe fan-out cost**: is `NotificationCenter` → socket write per event
   fine at tens of panels, or do we coalesce/debounce moves?
4. **Does the CLI adopt the socket** when present (route through the app), or stay
   pure-file and rely on reconcile? (§1 argues adopt; needs a fallback contract.)
5. **`config.set` scope**: full merge-patch of arbitrary keys, or a curated
   allow-list of agent-writable config paths?

---

## 11. Review resolutions (2026-07-15, Codex design review)

Contract decisions the review forced, to fold into §§3–8 as they're built.

### 11.1 Concurrency — participating clients + revisions
The socket serializes *participating* clients only; it is not a global lock.
Mutations route through a coordinator that reads live panel text (so an append
can't be lost to a debounce flush), and carry an opaque `revision`/`ifRevision`
so a stale write is rejected. Cross-file persistence (frontmatter + `workspace.json`)
is **not transactional** — define write order, the acknowledgement point, and
partial-failure results. Never retry a lost-response mutation as a file write;
mutation IDs make the outcome unambiguous.

### 11.2 Three durability scopes, one authority matrix
"Two planes" was really three scopes. Precedence must be explicit:

| Scope | Owns | Store |
|---|---|---|
| portable | presentation, `preferredSlot` | frontmatter (`blink:` block) |
| device | open set, mode, shade, actual frame/screen, resting z-order | `.blink/workspace.json` |
| runtime | focus, transient animation/z-order, current visibility | memory only |

An old workspace frame and a freshly edited frontmatter `slot` can disagree —
store a `preferredSlotAtSave` / presentation fingerprint beside the geometry so
stale geometry self-invalidates, or specify an unambiguous restore order. **Note:**
`.blink/workspace.json` is **disposable local state, not derived** — deleting it
loses real layout/session choices that can't be rebuilt from the notes. Keep the
"no note-*content* loss" invariant, but stop calling all of `.blink/` "derived"
(fix the wording in §1/§3 and `notes-representation.md` §3.2). Also drop the older
line that says workspace *owns grid slots* — intent is portable (frontmatter),
resolved slot is device (workspace).

### 11.3 Placement payload — an envelope, not a bare array
`placements.list` returns `{revision, coordinateSpace, panels:[…]}`. Per panel,
separate **intent from runtime**: `preferredSlot` vs `currentSlot`; a stable
display ID + label + full frame + visible frame + scale; `visible` / `activeSpace`
/ `occluded`; raw vs effective presentation; z-order across Blink note panels only.
Coordinates are **AppKit points, bottom-left origin, may be negative** — not
"pixels." The 3×3 slot type is currently private and Q/W/E/A/S/D/Z/X/C-based
(`GridOverlay.swift`); promote a shared type and lock the numeric 1–9 mapping +
screen-selection/collision rules.

### 11.4 Subscribe — snapshot + revision, or events race
`events.subscribe` must return an **atomic snapshot or a monotonic revision** so
list-then-subscribe can't drop events and subscribe-then-list can't duplicate
them. Add bounded per-client queues, move-event coalescing, slow-consumer
disconnect behavior, and an `origin`/`mutationId` on events so a subscriber that
also mutates doesn't react to its own change (loop prevention).

### 11.5 Method set — the metadata the concurrency story needs
Add conditional `notes.patch` / `notes.presentation.patch` (tags, pinned, owned
`blink:` fields) so agents don't have to edit frontmatter directly while Blink
runs. Give `panels.open {slot}` an explicit `scope: session | device | portable`
instead of silently editing Git-visible frontmatter — or split it into
`notes.presentation.patch` (portable intent) + `panels.open` (device placement).
Define whether a free-frame move clears or retains `preferredSlot`, and route GUI
snap, API move, and restore through **one placement reducer**. Also: pagination/
filtering or `notes.search`; raw vs effective `config.get`; validated/allowlisted
`config.set` + config-change events; exact `append` newline semantics.

### 11.6 Presentation-only reconciliation (blocks the frontmatter work)
`PanelManager.applyExternalUpdate` early-outs when content is unchanged
(`PanelManager.swift:147-150`), so an external `blink:`-block edit (style/sheet/
slot) never reaches an open panel. When presentation becomes typed, `NoteStore.update`
must merge it from disk before content saves, and one resolver must serve panel-open,
presentation-only update, and config/style hot-reload. A `slot`-only edit should
**not** bump `updated` (don't reorder "recent notes" for a placement tweak).

### 11.7 Latent, outside the socket: slug/id as a path
`NoteFileStore.loadAll` trusts the frontmatter `id`, and `url(for:)` uses it as a
path — a malformed `id: ../../x` can turn a later save/delete into traversal
outside `Notes/`. Enforce the slug/filename invariant at ingestion and at every
RPC boundary. Independent of the socket; worth a guard regardless.

### 11.8 Scale
Full-directory `reconcile` after every write is O(n) churn at thousands of notes —
reconcile the changed file incrementally and suppress redundant self-write scans.
Formalize `notes.list` field semantics: byte definition of `size`, ISO date
format, null-vs-omitted, raw vs effective presentation, absolute `path`.
