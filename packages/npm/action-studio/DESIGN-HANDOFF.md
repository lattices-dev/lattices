# Action Studio — design handoff

Design/prototype pass on the two local previews, 2026-09-12.
Owner of this pass: `session-mtyj2ruc-phvcqf` (design + prototype).
Functional wiring (persistence, validation, bridge, tests) is owned separately.

Surfaces:

- `http://localhost:4177/` — `packages/npm/action-studio` (the shipping web component)
- `http://localhost:3051/studio/studies/action-definitions` — the design study in
  the `lattices-action-definition-study` worktree

## File ownership

Design owns:

| File | Scope |
|---|---|
| `packages/npm/action-studio/editor.html` | Shadow-DOM template |
| `packages/npm/action-studio/action-studio.css` | Component styles |
| `packages/npm/action-studio/index.mjs` | Render layer only (`#render*`, `#setLinked`, `#growInstruction`, and the `#bindEvents` calls into them) |
| `packages/npm/action-studio/demo/index.html` | Host chrome + Talkie/Lattices skins |
| `design/studio/src/studio/studies/ActionDefinitions.tsx` | Study page |
| `design/studio/src/studio/studies/action-definitions/ActionDefinitionEditor.tsx` | Study editor |
| `design/studio/app/globals.css` | `.action-*` block only |

Implementation owns: `demo/demo.js`, `demo/storage.mjs`, `demo/server.mjs`,
`test/`, `index.d.ts`, and the README API/host-contract sections.

`index.mjs` is the one shared file. This pass did **not** touch
`normalizeDefinition`, `DEFAULT_DEFINITION`, `DEFAULT_CAPABILITIES`, or the
event contract. The only model-state change is in `#emitChange`.

## Status

The first pass was **rejected** by the user: "this is what we already had, not
new." That was correct — it refined the existing layout and fixed bugs, but it
kept the form-with-a-thumbnail model. The component at `:4177` has since been
rebuilt around a different thesis. **Acceptance has not been given on the
rebuild either; it has not been reviewed yet.**

## Thesis of the rebuild

*You edit the workspace, not a description of the workspace.*

An action is screen geometry. The old editor made you describe geometry in
words — pick "Upper Right" from a `<select>` — and showed the result as a
300px thumbnail that was output-only. The canvas is now the input:

- **Placement is direct manipulation.** Drag a window; a 3×3 grid of the nine
  placements appears beneath it and the target cell lights up. The dragged
  block is translucent so it does not hide the cell it is being dropped into.
  The 3×3 is not decoration — there are exactly nine placement values, so the
  grid *is* the value set.
- **Windows are drawn at the frame they will really occupy.** `left` is a
  full-height left half; `keep-visible` is a small corner block. The picture
  carries the information the dropdown used to.
- **The step table is gone.** A thin "Windows" index remains for naming and
  targeting, expanding in place for the selected window. Rows no longer imply
  a sequence that an arrangement does not have.
- **The prompt is demoted.** It was a permanent slab across the top for a
  one-shot input; it now lives behind a `Describe` toggle, open by default only
  when the action has no windows yet.
- **Three input paths, not one.** Drag (pointer), arrow keys on a focused
  window (keyboard walks the same 3×3), and the placement `<select>` in the
  inspector (explicit/assistive). Drag-only would not have been accessible.

This follows the repo's existing idiom rather than inventing one: the Deck
Builder study already uses cell-snapped pointer drag with a valid/invalid ghost
for its span grid.

## Design decisions

**1. The written plan and the picture of the plan are one object.**
Outcome rows are numbered, and the same numeral appears on the matching preview
tile. Hovering or focusing a row lights both (`data-linked`). This replaced the
study's legend, which restated target + placement already shown in the rows —
the same three strings appeared in three places.

**2. The preview column earns its width.**
It was a small tile grid over ~200px of dead space. It now carries a framed
screen with a menubar strip (so the miniature reads as a Mac screen, not four
empty boxes) and a *When this runs* list. Every line of that list is read back
off the definition — step count, reuse, preserve, ambiguity — so the panel can
never claim behavior the action does not have. `Advanced definition` is pinned
to the column bottom with `margin-top: auto`.

**3. Editable things look editable, without moving.**
Inline fields carried no affordance. Each now has a transparent bottom border at
rest that colors on hover and focus, so the state change never reflows the row.
Outcome rows gained a `STEP / TARGET / PLACE` header.

**4. The Lattices skin was unfinished.**
The rail mark stayed navy "T", the active rail item stayed light blue on a dark
shell, and the navy live composer collapsed into the dark background — losing
the one structural anchor of the design. The composer now carries its own
accent-tinted inset edge, so it holds on light and dark hosts alike; the mark is
driven from `data-talkie` / `data-lattices` attributes (no `demo.js` change);
the rail, library, segmented control, stage and shadow all have dark
counterparts.

**5. Affordances tell the truth.**
The study's step rows showed a rotated `••` drag handle but nothing dragged
(reordering is ↑/↓ inside the expanded editor). That is now a chevron that
rotates on expand, with `aria-expanded`. The decorative host rail in the demo is
`disabled` with the nav labelled "not part of this preview" — no caption, since
the disabled state already says it.

**6. Type floor.**
The study bottomed out at 8–9.5px in ~20 places, which was shrink-to-fit rather
than hierarchy. Instrument/eyebrow labels are now ≥10px, body copy ≥11px. The
step numerals inside the miniature screen are 10px in a 15px circle.

## Bugs fixed (not styling)

1. **Header overflow.** In the `unavailable` and `failed` scenes the longer
   button label plus a two-word state chip pushed *Save action* past the panel
   edge, clipping it. The heading block now shrinks (`min-width: 0` on both the
   heading and the title row, `flex: 0 1 auto` on the name field) and the button
   group does not. Verified across all 8 scenes: chip/actions gap is ≥18px
   everywhere (it was **−7.6px**, an actual overlap, in `unavailable`).
2. **The empty scene contradicted itself.** The canvas said "No actions yet"
   while the library beside it listed three actions and the footer read
   "3 available on this Mac". The library now derives from the scene, so the
   empty state reads 0 rows / "0 available on this Mac" / empty canvas.
3. **Three names for one thing.** The blocked step was "GitHub unavailable" in
   the row, "App unavailable" on the tile and "Unavailable" in the legend. One
   `BLOCKED_TARGET` constant now feeds all of them.
4. **Empty ring.** The neutral runtime state rendered a bordered circle with no
   icon inside, reading as a broken glyph. It is a dot now.
5. **Resize grabber.** `resize: vertical` put an OS handle in the corner of the
   navy composer. The field auto-grows to its 92px cap instead.
6. **Saved badge lied after edits** (requested by the implementation worker).
   `#emitChange` now returns a `saved` definition to `draft` and updates the
   chip, so the badge cannot claim "saved" while the document has changes.

## Notes for the implementation worker

New selectors, if you need them:

- `.summary-list` — the derived *When this runs* list (`li[data-on]` = active)
- `.step-index` / `.tile-index` — paired step numerals
- `.screen-frame` — preview chrome wrapper (`.screen` is still the tile grid)
- `.action-step__chevron[data-open]` — study disclosure state

Unchanged: the five events, `setDefinition` / `getDefinition` /
`setCapabilities` / `setStatus`, the `--las-*` theme contract (no new public
tokens — new surfaces derive from existing ones via `color-mix`), and the
`idle | working | success | warning | error` status tones.

`demo.js` renders the library list into `.library`, so the static group markup
was removed from `demo/index.html` (it was being wiped at runtime anyway, after
a flash of fake rows). The bare `<p>` your empty state emits is styled via
`.group > p`.

## Deliberately not changed

The study header repeats `bucket / surface`, the label and the blurb that the
studio shell already prints above it. Every sibling study (`DeckBuilder`,
`CrossAppTabs`, `PlaceholderPage`) does the same — it is house style, and
changing it here would either make this page an outlier or require a
cross-cutting edit to the shared studio shell. Worth raising separately.

## Checks

- `bun test` in `packages/npm/action-studio` — 6 pass, 0 fail
- `npx tsc --noEmit` in the studio worktree — clean
- Scripted DOM audit over all 8 study scenes — no editor overflow, no clipped
  or overlapping header actions, no wrapped state chip, no sub-10px text, and
  the library agrees with the canvas in the empty scene
- Visual: both host skins on both surfaces, plus the component at 760px where
  the container query collapses it to one column
