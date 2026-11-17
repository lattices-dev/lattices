import { afterAll, beforeAll, expect, test } from 'bun:test'
import { readFile, readdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { createServer, preview } from 'vite'
import { analyticsBootstrap, hasUnconditionalAnalytics, inspectAnalytics } from './analytics-test-utils'

const siteDir = fileURLToPath(new URL('..', import.meta.url))
const liveOrigin = 'https://lattices.dev'
const routes = ['/', '/action/', '/lattices/docs/concepts/', '/blog/', '/404.html']
let devServer: Awaited<ReturnType<typeof createServer>>
let previewServer: Awaited<ReturnType<typeof preview>>
let devOrigin: string
let previewOrigin: string

beforeAll(async () => {
  // This suite checks the real output of `bun run build`; never silently skip it.
  await readFile(join(siteDir, 'dist/action/index.html'), 'utf8')
  const config = { root: siteDir, logLevel: 'silent' as const }
  const previousNodeEnv = process.env.NODE_ENV
  try {
    process.env.NODE_ENV = 'development'
    devServer = await createServer({ ...config, server: { host: '127.0.0.1', port: 0, watch: null } })
  } finally {
    if (previousNodeEnv === undefined) delete process.env.NODE_ENV
    else process.env.NODE_ENV = previousNodeEnv
  }
  await devServer.listen()
  devOrigin = `http://127.0.0.1:${(devServer.httpServer!.address() as AddressInfo).port}`
  previewServer = await preview({ ...config, preview: { host: '127.0.0.1', port: 0 } })
  previewOrigin = `http://127.0.0.1:${(previewServer.httpServer.address() as AddressInfo).port}`
})

afterAll(async () => {
  await Promise.all([devServer?.close(), previewServer?.close()])
})

function expectDisabled(html: string, origin: string) {
  expect(hasUnconditionalAnalytics(html)).toBe(false)
  const { window, scripts } = inspectAnalytics(html, origin)
  expect(scripts).toHaveLength(0)
  expect(window.dataLayer).toBeUndefined()
  expect(window.gtag).toBeUndefined()
}

test('actual Vite dev responses disable analytics before host filtering', async () => {
  for (const route of routes.slice(0, 4)) {
    const response = await fetch(`${devOrigin}${route}`)
    expect(response.status).toBe(200)
    const html = await response.text()
    expect(html).not.toContain('%PROD%')
    expectDisabled(html, devOrigin)
    expectDisabled(html, liveOrigin)
  }
})

test('actual production exports stay untracked through Vite preview', async () => {
  for (const route of routes) {
    const response = await fetch(`${previewOrigin}${route}`)
    expect(response.status).toBe(200)
    const html = await response.text()
    expect(html).not.toContain('%PROD%')
    expectDisabled(html, previewOrigin)
    const { scripts } = inspectAnalytics(html, liveOrigin)
    expect(scripts.map((script) => new URL(script.src).hostname)).toEqual([
      'www.googletagmanager.com', 'pulse.arach.dev',
    ])
  }
})

test('every exported HTML page keeps the shared production guard', async () => {
  const files = (await readdir(join(siteDir, 'dist'), { recursive: true })).filter((file) => file.endsWith('.html'))
  let guarded = 0
  for (const file of files) {
    const html = await readFile(join(siteDir, 'dist', file), 'utf8')
    expect(hasUnconditionalAnalytics(html)).toBe(false)
    // Standalone redirects and agent documents deliberately have no trackers.
    if (!analyticsBootstrap(html)) continue
    expectDisabled(html, previewOrigin)
    expect(inspectAnalytics(html, liveOrigin).scripts).toHaveLength(2)
    guarded++
  }
  expect(guarded).toBeGreaterThan(0)
})
