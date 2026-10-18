import type { SVGProps } from 'react'
import { latticesAccent, latticesPalette, type BrandTheme } from '../../lib/marks'

export interface BlinkMarkProps extends Omit<SVGProps<SVGSVGElement>, 'children' | 'color'> {
  /** Bake the family ink in for export. Omit to follow `currentColor`. */
  theme?: BrandTheme
  /** Explicit ink. Overrides `theme`. */
  color?: string
  /** The front note's colour, or `false` for one ink. Defaults to the family coral. */
  accent?: string | false
  /** Accessible name. Ignored when decorative. */
  label?: string
  decorative?: boolean
}

/**
 * The frame: a ring the grid's 1.2-unit gap wide, drawn as a 3.5-radius stroke
 * around the 14.8 square at 2.6 would draw it, so its outer edge is the 16-unit
 * square with 4.1 corners and its inner edge has 2.9 corners. It is a filled
 * ring rather than a stroke because the app icon's layers take every shape as a
 * fill.
 */
const frame =
  'M6.1 2H13.9A4.1 4.1 0 0 1 18 6.1V13.9A4.1 4.1 0 0 1 13.9 18H6.1A4.1 4.1 0 0 1 2 13.9V6.1A4.1 4.1 0 0 1 6.1 2Z' +
  'M6.1 3.2H13.9A2.9 2.9 0 0 1 16.8 6.1V13.9A2.9 2.9 0 0 1 13.9 16.8H6.1A2.9 2.9 0 0 1 3.2 13.9V6.1A2.9 2.9 0 0 1 6.1 3.2Z'

/**
 * A panel frame with two blocks stepping across it, on the family grid: the
 * frame's outer edge sits on the 16-unit guides and it is as thick as the
 * grid's 1.2-unit gap. The front block, the note in hand, carries the accent.
 */
export function BlinkMark({
  theme, color, accent, label = 'Blink', decorative = true, ...svgProps
}: BlinkMarkProps) {
  const ink = color ?? (theme ? latticesPalette[theme].ink : 'currentColor')
  const front = accent === false ? ink : accent ?? (theme ? latticesAccent[theme] : undefined)

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="none"
      role={decorative ? undefined : 'img'}
      aria-hidden={decorative || undefined}
      aria-label={decorative ? undefined : label}
      {...svgProps}
    >
      <path d={frame} fill={ink} fillRule="evenodd" />
      <rect x="6.3" y="6.3" width="3.7" height="3.7" fill={ink} />
      <rect
        x="10" y="10" width="3.7" height="3.7"
        fill={front ?? ink}
        style={front ? undefined : { fill: 'var(--logo-accent, currentColor)' }}
      />
    </svg>
  )
}
