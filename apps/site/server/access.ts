import { accessPaths } from '../src/lib/access-paths'

const COOKIE = 'lattices_docs'
const SESSION_SECONDS = 60 * 60 * 24 * 30
const encoder = new TextEncoder()
type Limiter = { limit(input: { key: string }): Promise<{ success: boolean }> }
export interface WelcomeEmail {
  from: { email: string; name: string }
  to: string
  subject: string
  text: string
}
export interface AccessEnv {
  ACCESS_CODE_SECRET?: string
  EMAIL_FROM?: string
  EMAIL?: { send(message: WelcomeEmail): Promise<{ messageId: string }> }
  ACCESS_CONTACTS?: { put(key: string, value: string): Promise<void> }
  EMAIL_RATE_LIMITER?: Limiter
  CODE_RATE_LIMITER?: Limiter
}
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) => Response.json(body, {
  status, headers: { 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff', ...headers },
})

function configuredSecret(env: AccessEnv) {
  return /^[A-F0-9]{64}$/.test(env.ACCESS_CODE_SECRET || '') ? env.ACCESS_CODE_SECRET! : null
}
async function emailDigest(email: string) {
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(email.trim().toLowerCase()))
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, '0')).join('')
}
export async function emailCode(email: string, secret: string) {
  return `${(await emailDigest(email)).slice(0, 8).toUpperCase()}-${secret.slice(0, 8)}`
}
async function key(secret: string) {
  return crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
}
const hex = (bytes: ArrayBuffer) => Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, '0')).join('')
const unhex = (value: string) => Uint8Array.from(value.match(/.{2}/g) || [], (pair) => parseInt(pair, 16))

export async function hasAccess(request: Request, env: AccessEnv, now = Date.now()) {
  const secret = configuredSecret(env)
  if (!secret) return false
  const cookie = request.headers.get('cookie')?.split(';').map((part) => part.trim()).find((part) => part.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1)
  if (!cookie || !/^\d{10}\.[a-f0-9]{64}$/.test(cookie)) return false
  const [expiry, signature] = cookie.split('.')
  if (Number(expiry) <= now / 1000 || Number(expiry) > now / 1000 + SESSION_SECONDS + 60) return false
  return crypto.subtle.verify('HMAC', await key(secret), unhex(signature), encoder.encode(`docs:${expiry}`))
}

async function body(request: Request): Promise<Record<string, unknown> | null> {
  if (!request.headers.get('content-type')?.startsWith('application/json')) return null
  const reader = request.body?.getReader()
  if (!reader) return null
  const chunks: Uint8Array[] = []
  let length = 0
  for (;;) {
    const result = await reader.read()
    if (result.done) break
    length += result.value.length
    if (length > 2048) { await reader.cancel(); return null }
    chunks.push(result.value)
  }
  try {
    const bytes = new Uint8Array(length)
    let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    const parsed = JSON.parse(new TextDecoder().decode(bytes))
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
  } catch { return null }
}

/** No accounts. Cloudflare KV stores the contact; the code grants shared access. */
export async function handleAccess(request: Request, env: AccessEnv): Promise<Response | null> {
  const url = new URL(request.url)
  if (url.pathname === accessPaths.session && request.method === 'GET') return json({ unlocked: await hasAccess(request, env) })
  if (!([accessPaths.welcome, accessPaths.unlock] as string[]).includes(url.pathname)) return null
  if (request.method !== 'POST') return json({ error: 'Use POST.' }, 405, { Allow: 'POST' })
  if (request.headers.get('origin') !== url.origin) return json({ error: 'Open this form on the Lattices website.' }, 403)
  const secret = configuredSecret(env)
  if (!secret) return json({ error: 'Email access is not connected yet. Please try again later.' }, 503)
  const input = await body(request)
  if (!input) return json({ error: 'Please check the form and try again.' }, 400)
  const ip = request.headers.get('cf-connecting-ip') || 'local'
  const limiter = url.pathname === accessPaths.welcome ? env.EMAIL_RATE_LIMITER : env.CODE_RATE_LIMITER
  // Production fails closed if abuse controls have not been provisioned.
  if (!limiter) return json({ error: 'Access is temporarily unavailable. Please try again later.' }, 503)
  if (!(await limiter.limit({ key: `docs:${ip}` })).success) return json({ error: 'Too many attempts. Please wait a minute and try again.' }, 429, { 'Retry-After': '60' })

  if (url.pathname === accessPaths.unlock) {
    const code = typeof input.code === 'string' ? input.code.trim().toUpperCase() : ''
    const match = code.match(/^(?:[A-F0-9]{8}-)?([A-F0-9]{8})$/)
    if (!match || match[1] !== secret.slice(0, 8)) return json({ error: 'That code doesn’t match. Copy the access code from your welcome email.' }, 401)
    const expiry = String(Math.floor(Date.now() / 1000) + SESSION_SECONDS)
    const signature = hex(await crypto.subtle.sign('HMAC', await key(secret), encoder.encode(`docs:${expiry}`)))
    const secure = url.protocol === 'https:' ? '; Secure' : ''
    return json({ ok: true }, 200, { 'Set-Cookie': `${COOKIE}=${expiry}.${signature}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_SECONDS}${secure}` })
  }

  const email = typeof input.email === 'string' ? input.email.trim().toLowerCase() : ''
  if (email.length > 254 || !/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email)) return json({ error: 'Enter a valid email address.' }, 400)
  if (!env.EMAIL || !env.EMAIL_FROM || !env.ACCESS_CONTACTS) return json({ error: 'Email delivery is not connected yet. Please try again later.' }, 503)
  const code = await emailCode(email, secret)
  try {
    // Capture requests for access only; this does not subscribe anyone to marketing.
    await env.ACCESS_CONTACTS.put(`email:${await emailDigest(email)}`, JSON.stringify({ email, source: 'docs-access', requestedAt: new Date().toISOString() }))
  } catch { return json({ error: 'We couldn’t save your email. Please try again shortly.' }, 502) }
  try {
    await env.EMAIL.send({
      from: { email: env.EMAIL_FROM, name: 'Lattices' }, to: email, subject: 'Welcome to Lattices — your docs access code',
      text: `Welcome to Lattices.\n\nYour access code is:\n${code}\n\nReturn to the page you were reading and enter this code to continue. It unlocks detailed guides and studies in this browser for 30 days.\n\nInstallation and the first steps stay public.\n\n${url.origin}/docs\n\nYou requested this email on the Lattices website. If that wasn’t you, you can ignore it.`,
    })
    return json({ ok: true }, 202)
  } catch { return json({ error: 'We couldn’t send your code. Please try again shortly.' }, 502) }
}
