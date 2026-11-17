import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { hasUnconditionalAnalytics, inspectAnalytics } from './analytics-test-utils'

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8')
function runAnalytics(origin: string, production?: boolean, privacy = {}) {
  const document = production === undefined ? html : html.replaceAll('%PROD%', String(production))
  return inspectAnalytics(document, origin, privacy)
}

test('shared HTML has no unconditional Google Analytics script request', () => {
  expect(hasUnconditionalAnalytics(html)).toBe(false)
})

test.each([
  'http://localhost:5291',
  'http://localhost',
  'http://127.0.0.1:4173',
  'http://[::1]:5291',
  'http://192.168.1.10:5291',
  'http://macbook.local:5291',
  'https://preview.lattices.dev',
  'https://lattices.pages.dev',
  'https://lattices.dev:5291',
  'https://lattices.dev.example.com',
  'http://lattices.dev',
])('production bundles do not track non-production origin %s', (origin) => {
  const { window, scripts } = runAnalytics(origin, true)
  expect(scripts).toHaveLength(0)
  expect(window.dataLayer).toBeUndefined()
  expect(window.gtag).toBeUndefined()
})

test.each([false, undefined])('development and unprocessed HTML do not track even on the production origin (%s)', (production) => {
  const { window, scripts } = runAnalytics('https://lattices.dev', production)
  expect(scripts).toHaveLength(0)
  expect(window.dataLayer).toBeUndefined()
  expect(window.gtag).toBeUndefined()
})

test('production keeps analytics initialization and events on the exact live origin', () => {
  const { window, scripts } = runAnalytics('https://lattices.dev', true)
  expect(scripts.map((script) => script.src)).toEqual([
    'https://www.googletagmanager.com/gtag/js?id=G-25C3DG2J2D',
    'https://pulse.arach.dev/track.js',
  ])
  expect(scripts.every((script) => script.async)).toBe(true)
  expect(scripts[1].dataset.property).toBe('552148955')
  expect(Array.from(window.dataLayer![1])).toEqual(['config', 'G-25C3DG2J2D'])
  window.gtag?.('event', 'cta_click', { product: 'action' })
  expect(Array.from(window.dataLayer![2])).toEqual(['event', 'cta_click', { product: 'action' }])
})

test.each([{ doNotTrack: '1' }, { globalPrivacyControl: true }])('preserves Pulse privacy opt-outs (%j)', (privacy) => {
  const { scripts } = runAnalytics('https://lattices.dev', true, privacy)
  expect(scripts).toHaveLength(1)
  expect(scripts[0].src).toContain('googletagmanager.com')
})
