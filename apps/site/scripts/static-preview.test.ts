import { afterAll, beforeAll, expect, test } from 'bun:test'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { createServer, preview } from 'vite'
import { staticPreview } from './static-preview'

let root: string
let previewServer: Awaited<ReturnType<typeof preview>>
let devServer: Awaited<ReturnType<typeof createServer>>
let previewURL: string
let devURL: string

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'lattices-static-preview-'))
  const files: Record<string, string> = {
    'index.html': '<html><body>development SPA</body></html>',
    'dist/index.html': '<html><body>exported home</body></html>',
    'dist/lattices/docs/concepts/index.html': '<html><head><link rel="canonical" href="https://lattices.dev/lattices/docs/concepts"></head><body>exported concepts</body></html>',
    'dist/llms.txt': '# Lattices documentation',
    'dist/.well-known/agent.json': '{"name":"Lattices docs"}',
  }
  for (const [name, content] of Object.entries(files)) {
    const file = join(root, name)
    await mkdir(dirname(file), { recursive: true })
    await writeFile(file, content)
  }
  const config = { root, configFile: false as const, plugins: [staticPreview()], logLevel: 'silent' as const }
  previewServer = await preview({ ...config, preview: { host: '127.0.0.1', port: 0 } })
  previewURL = `http://127.0.0.1:${(previewServer.httpServer.address() as AddressInfo).port}`
  devServer = await createServer({ ...config, server: { host: '127.0.0.1', port: 0, watch: null } })
  await devServer.listen()
  devURL = `http://127.0.0.1:${(devServer.httpServer!.address() as AddressInfo).port}`
})

afterAll(async () => {
  await Promise.all([previewServer?.close(), devServer?.close()])
  if (root) await rm(root, { recursive: true, force: true })
})

test('preview redirects exported directories and serves their own metadata', async () => {
  const path = '/lattices/docs/concepts'
  const redirect = await fetch(`${previewURL}${path}?from=agent`, { redirect: 'manual' })
  expect(redirect.status).toBe(301)
  expect(redirect.headers.get('location')).toBe(`${path}/?from=agent`)
  const response = await fetch(`${previewURL}${path}`)
  const html = await response.text()
  expect(response.status).toBe(200)
  expect(html).toContain('exported concepts')
  expect(html).toContain('https://lattices.dev/lattices/docs/concepts')
  expect(html).not.toContain('exported home')
})

test('preview serves actual text and well-known JSON without redirects', async () => {
  const text = await fetch(`${previewURL}/llms.txt`, { redirect: 'manual' })
  expect(text.status).toBe(200)
  expect(text.headers.get('content-type')).toContain('text/plain')
  expect(await text.text()).toBe('# Lattices documentation')
  const json = await fetch(`${previewURL}/.well-known/agent.json`, { redirect: 'manual' })
  expect(json.status).toBe(200)
  expect(json.headers.get('content-type')).toContain('application/json')
  expect(await json.json()).toEqual({ name: 'Lattices docs' })
})

test('preview gives real 404s for missing artifacts, discovery files, and routes', async () => {
  for (const path of ['/missing-agent-doc.json', '/.well-known/missing-agent.json', '/lattices/docs/missing', '/lattices/docs/missing/']) {
    for (const accept of ['*/*', 'text/html']) {
      const response = await fetch(`${previewURL}${path}`, { headers: { accept } })
      expect(response.status).toBe(404)
      expect(await response.text()).not.toContain('exported home')
    }
  }
  const head = await fetch(`${previewURL}/missing-agent-doc.json`, { method: 'HEAD' })
  expect(head.status).toBe(404)
  expect(await head.text()).toBe('')
})

test('development keeps its SPA fallback for client-side routes', async () => {
  const response = await fetch(`${devURL}/lattices/docs/concepts`)
  expect(response.status).toBe(200)
  expect(await response.text()).toContain('development SPA')
  expect(devServer.config.appType).toBe('spa')
})
