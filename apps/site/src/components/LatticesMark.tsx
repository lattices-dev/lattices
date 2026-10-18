import { Fragment, type SVGProps } from 'react'
import {
  actionCursor, latticesAccent, latticesGrid, latticesPalette,
  type BrandTheme, type LatticesCentre, type MarkPalette,
} from '../lib/marks'

/** Left column and bottom row lit — the L — with the rest of the 3 × 3 grid dim. */
const cells = [true, false, false, true, false, false, true, true, true]

/** The accent sits in the centre cell, in the crook of the L. */
const accentCell = 4

const n = (v: number) => Number(v.toFixed(3))

/**
 * The default centre: Action's cursor with its tip on the cell's bottom-left
 * corner, in the crook of the L. Turned 45°, the cursor spans a square, so its
 * tail reaches the cell's top and right edges.
 */
function pointer(x: number, y: number, side: number) {
  const k = side / actionCursor.span / Math.SQRT2
  return actionCursor.d.replace(/([MCLQ])([^MCLQZ]+)/g, (_, command: string, args: string) => {
    const values = args.trim().split(/\s+/).map(Number)
    const points: string[] = []
    for (let i = 0; i < values.length; i += 2) {
      const [u, v] = [values[i], values[i + 1]]
      points.push(`${n(x + k * (u + v))} ${n(y + side - k * (u - v))}`)
    }
    return command + points.join(' ')
  })
}

/**
 * A quarter turn filling the cell, the arc a tile sweeps as it swings into the
 * crook. It pivots on the cell's bottom-left corner, where the L's arms meet,
 * which keeps the cells' corner radius; its two tips ease by half that radius.
 */
function sweep(x: number, y: number, side: number, corner: number) {
  const tip = corner / 2
  const px = x, py = y + side
  // Each tip's fillet touches the straight edge and runs inside the arc.
  const reach = Math.sqrt((side - tip) ** 2 - tip ** 2)
  const out = side / (side - tip)
  return [
    `M${n(px)} ${n(py - corner)}`,
    `V${n(py - reach)}`,
    `A${n(tip)} ${n(tip)} 0 0 1 ${n(px + tip * out)} ${n(py - reach * out)}`,
    `A${n(side)} ${n(side)} 0 0 1 ${n(px + reach * out)} ${n(py - tip * out)}`,
    `A${n(tip)} ${n(tip)} 0 0 1 ${n(px + reach)} ${n(py)}`,
    `H${n(px + corner)}`,
    `A${n(corner)} ${n(corner)} 0 0 1 ${n(px)} ${n(py - corner)}Z`,
  ].join('')
}

type Point = readonly [number, number]

/** A polygon listed clockwise on screen, each corner rounded with its own radius. */
function roundedPolygon(points: readonly Point[], radii: readonly number[]) {
  return points.map((p, i) => {
    const prev = points[(i + points.length - 1) % points.length]
    const next = points[(i + 1) % points.length]
    const unit = (to: Point) => {
      const length = Math.hypot(to[0] - p[0], to[1] - p[1])
      return [(to[0] - p[0]) / length, (to[1] - p[1]) / length] as const
    }
    const [a, b] = [unit(prev), unit(next)]
    const angle = Math.acos(Math.max(-1, Math.min(1, a[0] * b[0] + a[1] * b[1])))
    const r = radii[i]
    const t = r / Math.tan(angle / 2)
    const turn = (p[0] - prev[0]) * (next[1] - p[1]) - (p[1] - prev[1]) * (next[0] - p[0]) > 0 ? 1 : 0
    return `${i ? 'L' : 'M'}${n(p[0] + a[0] * t)} ${n(p[1] + a[1] * t)}A${n(r)} ${n(r)} 0 0 ${turn} ${n(p[0] + b[0] * t)} ${n(p[1] + b[1] * t)}`
  }).join('') + 'Z'
}

/** The L again at small scale, its arms 40% of the cell, set into the crook. */
function bracket(x: number, y: number, side: number, corner: number) {
  const arm = side * 0.4
  const inner = corner * 0.4
  return roundedPolygon(
    [[x, y], [x + arm, y], [x + arm, y + side - arm], [x + side, y + side - arm], [x + side, y + side], [x, y + side]],
    [corner, inner, inner, inner, corner, corner],
  )
}

type Role = 'ink' | 'dim' | 'accent'
type Paint = (role: Role) => Pick<SVGProps<SVGElement>, 'className' | 'style' | 'fill' | 'fillOpacity'>

/** The centre's shapes, in the accent over a dim cell where the shape leaves the cell showing. */
function centreShapes(centre: LatticesCentre, x: number, y: number, side: number, corner: number, paint: Paint) {
  const cx = x + side / 2
  const cy = y + side / 2
  const cell = <rect x={x} y={y} width={side} height={side} rx={corner} {...paint('dim')} />
  switch (centre) {
    case 'pointer':
      return <path d={pointer(x, y, side)} {...paint('accent')} />
    case 'sweep':
      return <path d={sweep(x, y, side, corner)} {...paint('accent')} />
    case 'node':
      return <circle cx={cx} cy={cy} r={side / 2} {...paint('accent')} />
    case 'knob':
      return <>{cell}<circle cx={cx} cy={cy} r={n(side * 0.29)} {...paint('accent')} /></>
    case 'bracket':
      return <>{cell}<path d={bracket(x, y, side, corner)} {...paint('accent')} /></>
  }
}

export interface LatticesMarkProps extends Omit<SVGProps<SVGSVGElement>, 'children'> {
  size?: number
  /** Bake a palette in for export. Omit to follow the page's logo tokens. */
  theme?: BrandTheme
  /** The accent's colour, or `false` for one ink, which draws the centre as a plain dim cell. Defaults to the family coral. */
  accent?: string | false
  /** The centre's shape. The pointer is the mark; `latticesCentres` says when to swap in another. */
  centre?: LatticesCentre
  /** Colours over `theme`'s. The brand exporter paints one role at a time to split the mark into icon layers. */
  palette?: Partial<MarkPalette>
  /** Accessible name. Ignored when decorative. */
  label?: string
  decorative?: boolean
}

export function LatticesMark({
  size = 20, theme, accent, centre = 'pointer', palette, label = 'Lattices', decorative = true,
  className = theme ? undefined : 'site-mark', ...svgProps
}: LatticesMarkProps) {
  const { box, pad, gap, radius } = latticesGrid
  const cell = (box - 2 * pad - 2 * gap) / 3
  const colors = theme ? { ...latticesPalette[theme], ...palette } : undefined
  const accentFill = accent === false ? undefined : accent ?? (theme ? latticesAccent[theme] : 'var(--logo-accent)')
  const paint: Paint = (role) => colors
    ? {
        fill: role === 'accent' ? accentFill : colors[role],
        fillOpacity: role === 'dim' ? colors.dimOpacity : undefined,
      }
    : {
        className: 'site-mark-cell',
        style: { fill: role === 'accent' ? accentFill : `var(--logo-${role})` },
      }

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
      {cells.map((lit, index) => {
        const x = pad + (index % 3) * (cell + gap)
        const y = pad + Math.floor(index / 3) * (cell + gap)
        if (accentFill !== undefined && index === accentCell) {
          return <Fragment key={index}>{centreShapes(centre, x, y, cell, radius, paint)}</Fragment>
        }
        return <rect key={index} x={x} y={y} width={cell} height={cell} rx={radius} {...paint(lit ? 'ink' : 'dim')} />
      })}
    </svg>
  )
}
