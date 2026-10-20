---
title: Agent integration proposal
description: Proposed agent verb set and integration surfaces (CLI, MCP, skill, SDK). Not implemented beyond the current CLI.
---

# Blink v2 — Agent Interface: verbs & surfaces

> **Status: proposal.** This document is a design proposal, not a description of
> the shipped app. There is no Blink MCP server or SDK today. For current agent
> surfaces, see the [`blink` CLI](/blink/docs/cli) and the
> [Agent socket API](/blink/docs/api).

> Draft 2026-07-15. Sits **above** `agent-api.md` (the raw Unix-socket JSON-RPC,
> layer 2.5) and beside `cli.md`. This doc specifies two things:
> **(A) the verb set** — the small phrasebook an agent actually thinks in, and
> **(B) the integration layer** — the surfaces (CLI, MCP, skill, SDK) that carry
> those verbs to an agent *who is not developing for Blink*. Status: proposed.

## Thesis

> Define the verb set **once** against the socket, then *project* it onto every
> surface. CLI subcommands, MCP tools, and the TS SDK are three skins over one
> phrasebook. "Which surface" then stops mattering — an agent uses whatever its
> harness gives it, and the mental model is identical.

The nouns are the `blink:` frontmatter keys (`style`, `slot`, `sheet`, `accent`,
`font`, …) — see `notes-representation.md`. The verbs move a note between the two
planes: **durable** (the `.md` file + frontmatter) and **live** (the running
app's panels on screen).

---

## Part A — The verbs (the phrasebook)

Six verbs plus a chainable handle. Everything an agent does is one of these.

### The handle

```ts
blink.note(id)          // get-or-create handle; no I/O until a write verb runs
  .style(name)          // → blink.style   (named Treatment preset)
  .sheet(name)          // → blink.sheet
  .accent(color)        // → blink.accent
  .slot(n | "S")        // → blink.slot    (placement INTENT: 1–9 or grid cell)
  .as(agent)            // attribution: chip, caret tint, durable source:
```

Chaining only *stages* intent; a write verb commits it. The handle carries the
note's `revision` invisibly and retries a stale write with a re-read, so agents
get concurrency safety without ever seeing `ifRevision` (see `agent-api.md` §11).

### The write verbs

```ts
// present — the compound arrival. content + presentation + placement + open,
// in ONE round-trip. The 80% verb.
await blink.note("q3-planning").style("focus").slot(6).as("scout")
  .present("# Q3 Planning\n\nThree bets, one page.\n");

// type — visible-hand reveal. Accepts a string OR an async iterable, so an LLM
// token stream maps straight onto the typed reveal. Live plane types in real
// time; durable plane gets ONE atomic write on settle.
await blink.note("overnight-prs").as("scout").type(llm.stream("summarize PRs"));

// write — the quiet sibling. Silent whole-document replace, no theater.
await blink.note("q3-planning").write(fullMarkdown);
```

`type` vs `write` is the API making *saying* distinct from *filing* — today that
split is an accident of whether an edit happens to be an anchored prefix
(`PanelManager.applyExternalUpdate`). Here it's a choice.

### The read verbs

```ts
const md   = await blink.note("q3-planning").read();   // durable content
const desk = await blink.desk();                        // live placements
desk.freeSlots();                                       // → [1,2,7,8,9]
desk.panels;                                            // open panels + frames + z

for await (const ev of blink.watch("placements")) {     // live event stream
  if (ev.type === "panel.closed" && ev.id === "q3-planning") break;
}
```

### Composition sugar

```ts
// a scene: several notes arrive as one composed thought (staggered entrances)
await blink.scene([
  blink.note("weather").slot(1),
  blink.note("calendar").slot(2),
  blink.note("overnight-prs").slot(3).style("focus"),
]).arrive({ deal: "left-to-right" });
```

### Verb → socket mapping

| Verb              | Socket method (`agent-api.md`)            | Plane            |
|-------------------|-------------------------------------------|------------------|
| `note(id)`        | *(lazy — no call until a write)*           | —                |
| `present`/`arrive`| **`notes.present`** *(NEW, compound)*      | live + durable   |
| `type`            | **`notes.type`** session *(NEW: open→chunk→commit)* | live → durable @ settle |
| `write`           | `notes.setContent`                         | live + durable   |
| `read`            | `notes.get`                                | durable          |
| `desk`            | `placements.list`                          | live             |
| `watch`           | `events.subscribe`                         | live             |
| `.as(agent)`      | **`system.hello {agent}`** *(NEW, identity in handshake)* | session |

Three additions to `agent-api.md`, not a rewrite: `notes.present` (compound
arrival, also resolves review items 11.5/11.6), a `notes.type` streaming session
(so a stream is one file write at settle, not N writes + N reconciles), and agent
identity promoted into `system.hello` so every mutation carries provenance instead
of hitching on the `source:` frontmatter key at reveal time.

---

## Part B — The integration layer (surfaces)

The verbs above reach an agent through one of four surfaces. They are **layers of
one stack**, not alternatives — an agent who is not developing for Blink only ever
touches the middle two.

| Surface        | Who it's for                          | Install cost / agent            |
|----------------|---------------------------------------|---------------------------------|
| Unix socket    | nobody, directly (it's bedrock)       | — every surface below is a client |
| **CLI (`blink`)** | any agent with a shell             | zero (binary on PATH) — *floor*  |
| **MCP server** | tool-using assistants (Claude, Codex, Cursor) | user installs *once*; all agents in the harness get the verbs — *ceiling* |
| Skill          | Claude Code specifically              | thin — guidance, not transport   |
| TS SDK         | someone *building* a Blink integration| `npm install` — the "developing for Blink" case |

The TS snippets in Part A are the **design language**, realized as CLI subcommands
and MCP tools. No ad-hoc agent `npm install`s a package to drop a note on a screen.

### CLI — the universal floor (extends `cli.md`)

Works in any harness, any shell, zero setup, even app-closed. New verb parity:

```sh
blink present q3-planning --slot 6 --style focus --as scout <<'MD'
# Q3 Planning
Three bets, one page.
MD

blink type overnight-prs --as scout        # reads stdin, streams the reveal
blink write q3-planning < final.md         # silent replace
blink desk --json                          # placements snapshot
blink watch placements                     # newline-delimited events
```

### MCP — the first-class ceiling

The strategic surface: the user installs the Blink MCP server once; every
tool-using agent then *discovers* the verbs as typed tools — no code, no per-agent
setup, and the agent never sees a file. The tool set **is** the phrasebook:

```jsonc
blink_present { id, content, style?, sheet?, accent?, slot?, as?, open? }  → { id, revision, frame }
blink_type    { id, content, as? }        // streaming chunks map to a notes.type session
blink_write   { id, content }
blink_read    { id }                       → { content, revision }
blink_desk    { }                          → { slots, free, panels }
blink_watch   { channel }                  → event stream
```

Each tool is a thin typed face over the same in-process socket call — never a
second source of truth (`agent-api.md` §1).

### Skill — etiquette, not mechanism

A Claude Code skill wraps the CLI/MCP with Blink's *manners*: when to `type` vs
`write`, always pass `--as`, never displace a user-placed panel, prefer `present`
over multi-step create+open. It teaches muscle memory; it is not a transport.

### SDK — for integrators only

`@blink/agent` (the Part A object) ships as an npm package **only** for developers
embedding Blink in their own TS/JS process. Excluded from the "agent not developing
for Blink" path by definition.

---

## Graceful degradation

Every verb has an app-closed answer. When the socket is absent, a write verb falls
through to BlinkCore: `present` writes the file **and** the `blink:` intent
(style/slot) to frontmatter. The note is *waiting on the desk when the lights come
on* — the arrival animation plays on next launch. Same agent code, both planes.

---

## Attribution & etiquette (carried by every surface)

- **`as(agent)`** resolves to an identity from config (`agents: { scout: { glyph:
  "✳", accent: "#9ece6a" } }`). During a reveal the caret, chip, and a 1px panel
  edge carry that accent, then exhale to the note's own style on settle — the whole
  multi-agent coexistence story in one tinted pixel.
- **Placement is a claim, not a seizure.** An agent never displaces a user-placed
  panel (spatial memory is sacred — a hard requirement). A contested slot spirals
  to the nearest free cell (`preferredSlot` vs `currentSlot`, `agent-api.md` §11.3).
- **The user outranks the theater.** A keystroke snaps any in-flight reveal; key
  focus is never stolen; layouts are never scrambled.

---

## Build order

1. **CLI verbs** (`present`/`type`/`write`/`desk`) — extends the shipped CLI, the
   floor that works today and app-closed. Cheapest, unblocks any agent immediately.
2. **Socket additions** — `notes.present`, `notes.type` session, `system.hello`
   identity. The seam everything else sits on.
3. **MCP server** — the six tools above over the socket. The strategic surface that
   makes Blink a place agents natively put things.
4. **Skill** — the etiquette layer, once the verbs are stable.
