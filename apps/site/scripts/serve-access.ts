import { resolve, relative, sep } from 'node:path'
import { serve } from '../server/worker'
import type { AccessEnv } from '../server/access'

const root = resolve(import.meta.dir, '../.worker-assets')
const counters = new Map<string, { count: number; until: number }>()
const limiter = (name: string, limit: number) => ({ async limit({ key }: { key: string }) {
  const id = `${name}:${key}`
  const now = Date.now()
  // Local preview only. Production uses Cloudflare's rate-limit bindings.
  for (const [entry, state] of counters) if (state.until < now) counters.delete(entry)
  const state = counters.get(id) || { count: 0, until: now + 60_000 }
  state.count++
  counters.set(id, state)
  return { success: state.count <= limit }
} })
const env = {
  ACCESS_CODE_SECRET: process.env.ACCESS_CODE_SECRET,
  EMAIL_RATE_LIMITER: limiter('email', 3), CODE_RATE_LIMITER: limiter('code', 10),
  ASSETS: { async fetch(request: Request) {
    const url = new URL(request.url)
    let pathname: string
    try { pathname = decodeURIComponent(url.pathname) } catch { return new Response('Not found', { status: 404 }) }
    const target = resolve(root, `.${pathname}`)
    const within = relative(root, target)
    if (within === '..' || within.startsWith(`..${sep}`)) return new Response('Not found', { status: 404 })
    let file = Bun.file(target)
    if (!(await file.exists())) file = Bun.file(resolve(target, 'index.html'))
    if (!(await file.exists())) return new Response('Not found', { status: 404 })
    return new Response(request.method === 'HEAD' ? null : file, { headers: { 'Content-Type': file.type } })
  } },
} satisfies AccessEnv & { ASSETS: { fetch(request: Request): Promise<Response> } }
const server = Bun.serve({ hostname: '127.0.0.1', port: Number(process.env.PORT || 5187), fetch: (request) => serve(request, env) })
console.log(`Lattices access preview: ${server.url}`)
console.log('Email delivery: not connected in the static preview; use Wrangler for Cloudflare bindings.')
