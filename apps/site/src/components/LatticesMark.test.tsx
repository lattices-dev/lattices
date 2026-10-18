import { describe, test, expect } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { LatticesMark } from './LatticesMark'
import { actionCursor, latticesCentres, latticesGrid, type LatticesCentre } from '../lib/marks'

const render = (props = {}) => renderToStaticMarkup(createElement(LatticesMark, props))

type Point = readonly [number, number]

/** A Bézier curve's point at `t`, by de Casteljau. */
function bezier(controls: readonly Point[], t: number): Point {
  let points = controls
  while (points.length > 1) {
    points = points.slice(1).map(([x, y], i) => [points[i][0] + (x - points[i][0]) * t, points[i][1] + (y - points[i][1]) * t] as const)
  }
  return points[0]
}

/** A path of M, L, H, V, C, Q and A commands: each segment's end, and those ends with points along its C and Q curves. */
function outline(d: string) {
  let at: Point = [0, 0]
  const ends: Point[] = []
  const curves: Point[] = []
  for (const [, command, args] of d.matchAll(/([MLHVCQA])([^MLHVCQAZ]*)/g)) {
    const n = args.trim().split(/[\s,]+/).map(Number)
    if (command === 'C' || command === 'Q') {
      const controls: Point[] = [at]
      for (let i = 0; i < n.length; i += 2) controls.push([n[i], n[i + 1]])
      for (let step = 1; step < 64; step++) curves.push(bezier(controls, step / 64))
    }
    if (command === 'V') at = [at[0], n[0]]
    else if (command === 'H') at = [n[0], at[1]]
    else at = [n[n.length - 2], n[n.length - 1]]
    ends.push(at)
  }
  return { ends, points: [...ends, ...curves] }
}

describe('LatticesMark', () => {
  const { box, pad, gap } = latticesGrid
  const cell = (box - 2 * pad - 2 * gap) / 3
  const lo = pad + cell + gap, hi = lo + cell
  const round = (v: number) => Number(v.toFixed(3))

  test('draws the pointer by default, its tip in the crook of the L and its tail on the far edges', () => {
    const html = render({ theme: 'light' })
    expect(html.match(/<rect/g)).toHaveLength(8)
    const [, d, fill] = html.match(/<path d="([^"]+)" fill="([^"]+)"/)!
    expect(fill).toBe('#ef6a47')
    expect(d.startsWith(`M${round(lo)} ${round(hi)}`)).toBe(true)
    expect(d.replace(/[^A-Z]/g, '')).toBe(actionCursor.d.replace(/[^A-Z]/g, ''))
    const { points } = outline(d)
    expect(Math.max(...points.map(([x]) => x))).toBeCloseTo(hi, 2)
    expect(Math.min(...points.map(([, y]) => y))).toBeCloseTo(lo, 2)
  })

  test.each(Object.keys(latticesCentres) as LatticesCentre[])('draws the %s once in the accent, in the centre cell', (centre) => {
    const html = render({ theme: 'dark', centre })
    expect(html.match(/#ef6a47/g)).toHaveLength(1)
    const ends = [...html.matchAll(/<path d="([^"]+)"/g)].flatMap(([, d]) => outline(d).ends)
    const circles = [...html.matchAll(/<circle cx="([^"]+)" cy="([^"]+)" r="([^"]+)"/g)].flatMap(([, cx, cy, r]) => [
      [+cx - +r, +cy - +r], [+cx + +r, +cy + +r],
    ] as const)
    expect(ends.length + circles.length).toBeGreaterThan(0)
    for (const [x, y] of [...ends, ...circles]) {
      expect(x).toBeGreaterThanOrEqual(lo - 1e-3)
      expect(x).toBeLessThanOrEqual(hi + 1e-3)
      expect(y).toBeGreaterThanOrEqual(lo - 1e-3)
      expect(y).toBeLessThanOrEqual(hi + 1e-3)
    }
  })

  test('the sweep turns on a radius of one cell', () => {
    const [, d] = render({ theme: 'light', centre: 'sweep' }).match(/<path d="([^"]+)"/)!
    expect(d).toContain(`A${cell.toFixed(3)} ${cell.toFixed(3)} 0 0 1`)
  })

  test('accent={false} draws nine plain cells in one ink', () => {
    const html = render({ theme: 'dark', accent: false })
    expect(html).not.toContain('<path')
    expect(html.match(/<rect/g)).toHaveLength(9)
    expect(html).not.toContain('#ef6a47')
  })

  test('follows the page tokens when no theme is set', () => {
    const html = render()
    expect(html).toContain('style="fill:var(--logo-accent)"')
    expect(html).toContain('style="fill:var(--logo-ink)"')
  })
})
