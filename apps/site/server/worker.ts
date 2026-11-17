import protectedPaths from '../.generated/protected-paths.json'
import { accessPaths } from '../src/lib/access-paths'
import { handleAccess, hasAccess, type AccessEnv } from './access'

interface Env extends AccessEnv { ASSETS: { fetch(request: Request): Promise<Response> } }
const paths = protectedPaths as { artifacts: Record<string, string>; docs: Record<string, string> }
export async function serve(request: Request, env: Env) {
  const url = new URL(request.url)
  let pathname: string
  try { pathname = decodeURIComponent(url.pathname) } catch { return new Response('Not found', { status: 404 }) }
  // Internal asset paths must never be reachable through the public origin.
  if (pathname.toLowerCase().includes('__private') || pathname.includes('%') || pathname.includes('\\') || pathname.split('/').includes('..')) return new Response('Not found', { status: 404 })
  const api = await handleAccess(request, env)
  if (api) return api
  const docPrefix = '/api/access/docs/'
  const doc = pathname.startsWith(docPrefix) ? paths.docs[pathname.slice(docPrefix.length)] : undefined
  const artifact = paths.artifacts[pathname] || paths.artifacts[pathname.replace(/\/$/, '')]
  if (pathname.startsWith('/api/') && !doc) return new Response('Not found', { status: 404 })
  if (doc || artifact) {
    const allowed = await hasAccess(request, env)
    if (doc && !allowed) return Response.json({ error: 'Enter your access code to continue.' }, { status: 401, headers: { 'Cache-Control': 'private, no-store' } })
    if (allowed) {
      const target = new URL(`${accessPaths.privatePrefix}${doc || artifact}`, url)
      const response = await env.ASSETS.fetch(new Request(target, { method: request.method === 'HEAD' ? 'HEAD' : 'GET' }))
      const headers = new Headers(response.headers)
      headers.set('Cache-Control', 'private, no-store')
      headers.set('X-Robots-Tag', 'noindex')
      headers.set('X-Content-Type-Options', 'nosniff')
      return new Response(response.body, { status: response.status, headers })
    }
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405 })
  return env.ASSETS.fetch(request)
}
export default { fetch: (request: Request, env: Env) => serve(request, env) }
