import { describe, test, expect } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { SpeechMark } from './SpeechMark'
import { latticesGrid } from '../lib/marks'

const render = (props = {}) => renderToStaticMarkup(createElement(SpeechMark, props))

/** Each bar's geometry and fill, in drawing order. */
function bars(html: string) {
  return [...html.matchAll(/<rect ([^>]+?)\/?>/g)].map(([, attrs]) => {
    const get = (name: string) => attrs.match(new RegExp(`(?:^| )${name}="([^"]+)"`))?.[1]
    return { x: Number(get('x')), y: Number(get('y')), width: Number(get('width')), height: Number(get('height')), fill: get('fill') }
  })
}

describe('SpeechMark', () => {
  const { box, pad, gap } = latticesGrid
  const span = box - 2 * pad
  const cell = (span - 2 * gap) / 3

  test('draws two cell-wide bars, short in ink then tall in the accent, centred in the box', () => {
    const [short, tall] = bars(render({ theme: 'light' }))
    expect(short.fill).toBe('#101518')
    expect(tall.fill).toBe('#ef6a47')
    for (const bar of [short, tall]) {
      expect(bar.width).toBeCloseTo(cell)
      expect(bar.y + bar.height / 2).toBeCloseTo(box / 2)
    }
    expect(short.height).toBeCloseTo(span / 2)
    expect(tall.height).toBeCloseTo(span)
    expect(tall.x - (short.x + short.width)).toBeCloseTo(gap)
    expect(short.x + tall.x + tall.width).toBeCloseTo(box)
  })

  test('accent={false} draws both bars in one ink', () => {
    const drawn = bars(render({ theme: 'dark', accent: false }))
    expect(drawn).toHaveLength(2)
    expect(drawn.map((bar) => bar.fill)).toEqual(['#f2f2f2', '#f2f2f2'])
  })

  test('follows the page tokens when no theme is set', () => {
    const html = render()
    expect(html).toContain('style="fill:var(--logo-ink)"')
    expect(html).toContain('style="fill:var(--logo-accent)"')
  })
})
