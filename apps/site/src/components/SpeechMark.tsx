import type { SVGProps } from 'react'
import { latticesAccent, latticesGrid, latticesPalette, type BrandTheme, type MarkPalette } from '../lib/marks'

/**
 * Two bars of a waveform, frozen at the playhead: the word just spoken in ink
 * and the one sounding now, the accent. The rest of the readout is left out.
 * Short then tall, the pair also draws a speaker. Each bar is a Lattices cell
 * wide, the tall one a full column of the grid, and the pair sits centred.
 */
const speechBars = [0.5, 1] as const

/** The accent: the bar sounding now. */
const accentBar = 1

export interface SpeechMarkProps extends Omit<SVGProps<SVGSVGElement>, 'children'> {
  size?: number
  /** Bake a palette in for export. Omit to follow the page's logo tokens. */
  theme?: BrandTheme
  /** The current bar's colour, or `false` for one ink. Defaults to the family coral. */
  accent?: string | false
  /** Ink over `theme`'s. The brand exporter paints one role at a time to split the mark into icon layers. */
  palette?: Partial<Pick<MarkPalette, 'ink'>>
  label?: string
  decorative?: boolean
}

export function SpeechMark({
  size = 20, theme, accent, palette, label = 'Speech', decorative = true,
  className = theme ? undefined : 'site-mark', ...svgProps
}: SpeechMarkProps) {
  const { box, pad, gap, radius } = latticesGrid
  const span = box - 2 * pad
  const cell = (span - 2 * gap) / 3
  const left = (box - speechBars.length * cell - (speechBars.length - 1) * gap) / 2
  const ink = theme ? palette?.ink ?? latticesPalette[theme].ink : 'var(--logo-ink)'
  const accentFill = accent === false ? undefined : accent ?? (theme ? latticesAccent[theme] : 'var(--logo-accent)')

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      width={size}
      height={size}
      viewBox={`0 0 ${box} ${box}`}
      fill="none"
      role={decorative ? undefined : 'img'}
      aria-hidden={decorative || undefined}
      aria-label={decorative ? undefined : label}
      {...svgProps}
    >
      {speechBars.map((height, index) => {
        const fill = accentFill !== undefined && index === accentBar ? accentFill : ink
        return (
          <rect
            key={index}
            x={left + index * (cell + gap)}
            y={(box - height * span) / 2}
            width={cell}
            height={height * span}
            rx={radius}
            className={theme ? undefined : 'site-mark-cell'}
            fill={theme ? fill : undefined}
            style={theme ? undefined : { fill }}
          />
        )
      })}
    </svg>
  )
}
