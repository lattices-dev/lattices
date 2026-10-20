---
title: Placement
description: The grid placement model for note panels: what ships today and what is proposed.
---

# Canvas — Desk placement model

> Draft 2026-07-15. How agents (and the user) put notes *where they go* on screen.
> Canvas's own design; the good ideas are adapted from **Lattices'** placement
> engine (one primitive + aliases, declarative, deterministic, provenance-gated)
> — the ideas, not a dependency. Companion to `agent-integration.md` (the verbs)
> and `cli.md`.

> **Status: mixed.** Shipped: the `BlinkGrid` primitive and the `slot 1…9`
> home (`blink present --slot N`, `notes.present` on the
> [agent socket](/canvas/docs/api)), plus named desks (`blink desk save` /
> `restore`). Proposed and not built: named-zone and span targets in the CLI or
> frontmatter, `auto`, provenance-gated collisions, `tidy`, scenes, and display
> addressing by stable id. The agent socket exists, but these parts did not ship
> with it.

## Thesis: one primitive, everything else is sugar

There is exactly one placement primitive; every target an agent can name compiles
down to it:

```
grid:C×R : col,row (+colSpan×rowSpan)
frame = visibleFrame.origin + visibleFrame.size × fraction    // per target screen
```

`slot 1…9` is sugar for a single cell in a 3×3 grid (row-major, matching the
`Q W E / A S D / Z X C` keys). Named zones, halves, thirds, quarters, and `full`
are just other `C×R` shapes. Spans are two inclusive corners. All of it is one
function — `BlinkGrid.frame(for:in:)` — so halves and 2×2 blocks fall out for
free and never drift from the visual grid overlay (which shares the same code).

**Why a primitive and not N hard-coded cells:** reproducibility. A placement is
fully described by a tiny string, so the same request always yields the same
frame — the property that lets an agent *and* the user build spatial memory.

## Agent-facing targets

| Form | Example | Status |
|---|---|---|
| slot number | `--slot 6` | **shipped** (frontmatter `blink.slot`) |
| named zone | `top-left`, `center`, `right` | geometry ready; CLI/frontmatter next |
| half / third / quarter | `left-half`, `middle-third`, `top-left-quarter` | geometry ready |
| full area | `full` / `fill` | geometry ready |
| raw spec | `3x3:2,1`, `2x2:1,0+1x2` | geometry ready |
| **auto** | `--slot auto` | with the socket (needs live occupancy) |

Named targets are the point — agents reason in "top-right / next to the outline /
somewhere sensible," not pixels. Pixels stay an escape hatch, never the interface.

## Declarative home, not imperative moves

`blink.slot` (and later `blink.place`) is the **source of truth**. `present`
*converges* the panel to it: **idempotent** (already there → no-op) and it should
**echo the resolved placement** back in its output. This is why placement survives
restarts and stays reproducible — the note carries its home.

## Determinism is non-negotiable

`auto` = the first free slot in a **fixed priority order** ("edges first, keep the
center clear"), never random or time-based. Deterministic auto is what makes an
agent's "put this somewhere sensible" predictable enough to trust.

## Provenance-gated collisions *(live plane)*

Every placement is tagged `user` or `agent`. Precedence:

```
user-pinned  >  declarative-home  >  agent-auto
```

- **Master rule: never auto-move a panel the user placed by hand.** A user drag
  pins the note; agents route around it. This single rule preserves spatial memory.
- **Occupied cell → route around, don't displace:** spiral to the nearest free
  cell in a *fixed* order (deterministic; not a pixel cascade, which drifts
  off-grid and accumulates mess).
- **Displace only** when a declarative-home placement lands on a *homeless agent*
  panel — and move that occupant to nearest-free, never onto a pinned one.
- **One writer:** slot allocation serializes through the menubar process, so two
  agents placing at once can't race.

## Reflow: sticky by default, explicit `tidy`

Adding or removing a note **frees a slot but moves nothing**. Motion the user
didn't ask for is the fastest way to lose their trust. A dedicated `tidy` /
`relayout` verb is the *sanctioned* moment things rearrange — never a side effect.

## Scenes: declarative sets

A **scene** is a named `{ note → placement }` mapping applied in one atomic pass
(conflicts resolved by the scene's own order). Plus **capture-current-as-scene**:
the user arranges panels by hand, then snapshots that arrangement into a named
scene. Cheap, high value.

## Multi-screen

- Default to the note's **current screen** (the display containing its center).
- The grid is **per-screen**; a display is an optional *axis* of the same
  primitive (`slot 6 on display 2`).
- Address displays by **stable id** (UUID / friendly name), never array index —
  index is fragile across hotplug and rearrangement.
- Resolver order: explicit display → screen-containing-center → main → first.

## Deliberately skipped

Lattices tiles arbitrary *foreign* windows over Accessibility APIs; Canvas owns its
panels and gives each note a declarative home, so we skip its scar tissue:

- **masonry / bin-packing / auto-tiling** — non-reproducible in a fixed-home model
- **implicit reflow on add/remove** — the single biggest trust trap
- **pixel cascade** as a collision primary — nearest-free *cell* stays crisp
- **nondeterministic `auto`**
- **heavy ghost/screenshot preview + fly-in** — highlighting the target cell
  outline is enough; the rest is polish, not core
- **capture-frontmost dance** — we address notes by id, so we never "act on
  whatever's focused"
- **drag-notification logic** — if we add snap-on-drag, act on gesture end
  (mouseUp + distance threshold), not the ~60fps move stream

## Where each piece lives

- **Shipped:** `BlinkGrid` primitive + spans + named/spec resolver; `slot 1…9`
  place-on-open (declarative home) and live slot-move via `blink present --slot N`;
  shared geometry with the visual `GridOverlay`.
- **Shipped, related:** named desks. `blink desk save` captures the current
  arrangement, which covers the "capture-current-as-scene" idea above without
  the declarative scene format.
- **Proposed, not built:** `blink.place` (named + span) via `--place`;
  deterministic `auto`; provenance + collision routing; `tidy`; declarative
  scenes; multi-screen by stable id. Today `blink desk` addresses displays by
  one-based index.
