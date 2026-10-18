/**
 * Colours and geometry the product marks share with the brand exporter
 * (`scripts/export-brand.tsx`). They live apart from the components so that
 * each component module exports only its component.
 */

export type BrandTheme = 'light' | 'dark'

/** A grid mark's baked colours: the lit ink and the dim cells beside it. */
export interface MarkPalette {
  ink: string
  dim: string
  dimOpacity: number
}

/**
 * The family ink for exported kits. Every product mark draws in it, and every
 * app icon sits on a tile of the light ink. Theme names describe the intended
 * background, so `light` is dark ink. The live site leaves `theme` unset and
 * reads the `--logo-ink` / `--logo-dim` tokens instead, which lets hover states
 * recolour it.
 */
export const latticesPalette = {
  light: { ink: '#101518', dim: '#101518', dimOpacity: 0.22 },
  dark: { ink: '#f2f2f2', dim: '#ffffff', dimOpacity: 0.18 },
} as const

/**
 * Each mark carries one accent, on the part doing the work: the pointer
 * Lattices aims with, Action's cursor, Blink's front note, Speech's current bar.
 * All four take coral, the colour that already means "live" in Action's menu
 * bar. It holds 3:1 on white and about 6:1 on the dark tile, so one value
 * serves both themes. The live site reads `--logo-accent`; the site's UI keeps
 * `--green`.
 */
export const latticesAccent = { light: '#ef6a47', dark: '#ef6a47' } as const

/** The family grid: a 20-unit box, 2 units of padding, 1.2-unit gaps, 1-unit corners. */
export const latticesGrid = { box: 20, pad: 2, gap: 1.2, radius: 1 } as const

/**
 * The square the Action kit crops from ActionMark's 720 × 640 construction
 * drawing: the A's 460-unit square plus the family margin, so the glyph spans
 * 80% of the box, as the grid's 16 units span 20.
 */
export const actionMarkBox = [12.5, 12.5, 575, 575] as const

/**
 * Action's cursor in its own units: the tip at the origin, pointing along -x.
 * Turned 45°, it spans `span` units on each axis from tip to tail, which is how
 * ActionMark lays it on the A's diagonal and how LatticesMark fits it to a cell.
 */
export const actionCursor = {
  d: 'M 0 0 C 0 -2 3 -3 8 -3.730461265239989 L 170 -79.27230188634977 Q 180 -83.93537846789975 175 -73.93537846789975 L 140 -26 Q 124 0 140 26 L 175 73.93537846789975 Q 180 83.93537846789975 170 79.27230188634977 L 8 3.730461265239989 C 3 3 0 2 0 0 Z',
  span: 530 - 348.61256823541,
} as const

/**
 * The shapes the Lattices centre can take, each for one job. The pointer is the
 * mark. A surface swaps in another only while Lattices does that job there, and
 * goes back to the pointer when it's done.
 */
export const latticesCentres = {
  pointer: { name: 'Pointer', job: 'Aim', note: "Action's cursor with its tip in the crook of the L. The default." },
  knob: { name: 'Knob', job: 'Release', note: 'A knob on the dim cell: the spot to let go.' },
  sweep: { name: 'Sweep', job: 'Move', note: 'A quarter turn pivoting on the crook: a tile swinging into place.' },
  bracket: { name: 'Bracket', job: 'Session', note: 'The L again at small scale: a workspace inside the workspace.' },
  node: { name: 'Node', job: 'Live', note: 'A joint in the lattice: connected and running.' },
} as const

export type LatticesCentre = keyof typeof latticesCentres
