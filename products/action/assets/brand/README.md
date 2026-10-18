# Action's mark

A sharp capital A whose right foot is taken by a cursor. The A fills a square,
and the cursor lies on the square's diagonal: its tip sits on the counter's
right edge and its tail touches the square's right and bottom sides. The glyph
is exactly the square, as every Lattices mark fills the same 16 units of its
20-unit box. The letter is cut back from both of the cursor's arms by an even
gap, so the cursor reads as working inside the letter rather than lying on top
of it.

## Where it comes from

`ActionMark` in `apps/site/src/components/ActionMark.tsx` is the source of
truth: the construction drawing, now STUDY 03. The site's brand exporter
renders everything on disk from it, and the app ports its numbers to draw the
mark live:

| Surface | Drawn by | Colour source |
| --- | --- | --- |
| Logo kit (`apps/site/public/brand/action/`) | `apps/site/scripts/export-brand.tsx` | baked, see below |
| App icon (`Action.icns`) | `apps/site/scripts/export-brand.tsx` | baked |
| In-app brand chip | `ActionBrandTile` in `Sources/ActionBrandMarkView.swift` | live theme |
| Menu bar status item | `ActionBrandMark.statusItemImage(live:)` | template, or coral |

`native/engine/CoreSources/ActionBrandMark.swift` is the port. It copies the
component's coordinates and cuts the counter and the cursor's clearance as real
path subtractions, so one path fills identically in CoreGraphics, in an
`NSImage`, and in a SwiftUI `Shape`. It places the glyph on the tile the way
the exporter does, at 56% of the tile like every product icon, so the chip in
a header and the icon in the Dock are one mark. Change the component first, then carry
the numbers across by hand.

## Colour

| Role | Value |
| --- | --- |
| Ink on light | `#101518` |
| Ink on dark | `#f2f2f2` |
| Icon tile | `#101518` |
| Live (status item only) | coral `#EF6A47` |

The mark is one colour, the Lattices family ink: the letter and the cursor
share it, and the gap separates them. The icon sits on the family's tile, like
every product's. The in-app chip's tile and glyph read `StageHUDTheme` instead,
so they follow a theme switch. An `.icns` cannot, which is the one place the
two are allowed to differ.

The theme's coral keeps meaning runtime truth — a recording, a drive holding
the machine — so the resting mark never uses it.

## Menu bar

At rest the status item is a **template** image: the system tints it for the
current appearance and inverts it on highlight, like every other extra. While a
drive holds the machine it is drawn in coral instead — the same thing coral means
everywhere else. A template image cannot carry colour, so the live variant gives
up template tinting; a coral mark is legible against both a light and a dark bar.

The status item widens the gap between the letter and the cursor from the kit's
10 units to 36. Drawn in one colour, the gap is all that separates the two, and
with a 14 pt glyph ten units come to about a third of a point, so the cursor
fuses into the leg. Thirty-six open it to about a point.

Liveness comes from `ActionSupervisionRegistry.activeRegistrations()`, polled
every two seconds. It is polled rather than watched because a lease can lapse by
running past its TTL, and an expiry writes nothing a file-system watcher sees.

## Regenerating the icon

```sh
cd apps/site && bun run brand action
# or, from this product:
native/engine/scripts/build-app-icon.sh
```

Writes `Action.icns` plus `action-icon-512.png` and `action-icon-1024.png` here,
and the logo kit in `apps/site/public/brand/action/`. Commit the result —
`build-app.sh` copies the `.icns`, it does not build it, so an ordinary app
build stays fast and offline.

## Earlier work

The app's first mark was a play triangle breaking out of four capture-corner
marks: the frame Action puts around a region, and the take. An earlier round had
drawn a capital A with the play triangle as its counter, and it was rejected as
too on the nose — a letter A for an app called Action says the name, not the
job. PR #121 brought the A back, this time with a cursor, for the site and the
logo kit (STUDY 02). The app now follows the kit, so the Dock, the menu bar and
lattices.dev carry one mark. STUDY 03 squared the A and laid the cursor on the
diagonal, so the glyph sits on the family grid, and traded the cream tile and
the clay cursor for the family ink.

`explorations/` holds the first round of mark studies. `02-stage-frame.svg` is
the corner-marks mark's ancestor — viewport corner brackets around a play
triangle, with a coral record dot. `01-capture-a.svg` is the first letter-A
study. `landing/` holds the landing-page art and its palette.
