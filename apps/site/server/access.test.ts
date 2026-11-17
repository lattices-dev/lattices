import { describe, expect, test } from 'bun:test'
import { emailCode, handleAccess, hasAccess, type AccessEnv, type WelcomeEmail } from './access'
import { serve } from './worker'

const origin = 'https://lattices.example'
const secret = 'A1B2C3D4'.repeat(8)
const limit = { async limit() { return { success: true } } }
const env: AccessEnv = {
  ACCESS_CODE_SECRET: secret, EMAIL_FROM: 'welcome@example.com',
  EMAIL: { async send() { return { messageId: 'test-response' } } },
  ACCESS_CONTACTS: { async put() {} },
  EMAIL_RATE_LIMITER: limit, CODE_RATE_LIMITER: limit,
}
const post = (path: string, input: unknown, requestOrigin = origin) => new Request(origin + path, { method: 'POST', headers: { Origin: requestOrigin, 'Content-Type': 'application/json' }, body: JSON.stringify(input) })
async function unlock(code = 'A1B2C3D4') {
  const response = await handleAccess(post('/api/access/unlock', { code }), env)
  return response!.headers.get('set-cookie')!.split(';')[0]
}

describe('emailed access without accounts', () => {
  test('normalizes contact and sends a welcome code, without returning it to the requester', async () => {
    const contacts: { key: string; value: string }[] = []
    const messages: WelcomeEmail[] = []
    const response = await handleAccess(post('/api/access/welcome', { email: ' Reader@Example.com ' }), {
      ...env,
      ACCESS_CONTACTS: { async put(key, value) { contacts.push({ key, value }) } },
      EMAIL: { async send(message) { messages.push(message); return { messageId: 'test-response' } } },
    })
    expect(response!.status).toBe(202)
    expect(contacts[0].key).toMatch(/^email:[a-f0-9]{64}$/)
    expect(JSON.parse(contacts[0].value)).toMatchObject({ email: 'reader@example.com', source: 'docs-access' })
    expect(messages[0].to).toBe('reader@example.com')
    expect(messages[0].from).toEqual({ email: 'welcome@example.com', name: 'Lattices' })
    expect(messages[0].text).toContain(await emailCode('reader@example.com', secret))
    expect(await response!.text()).not.toContain('A1B2C3D4')
    expect(JSON.stringify({ contacts, messages })).not.toContain(secret)
  })
  test('email failure is recoverable and never reports sent', async () => {
    expect((await handleAccess(post('/api/access/welcome', { email: 'reader@example.com' }), {
      ...env, EMAIL: { async send() { throw new Error('E_SENDER_NOT_VERIFIED') } },
    }))!.status).toBe(502)
  })
  test('never sends a code if contact capture fails or required bindings are missing', async () => {
    let sent = false
    const failed = await handleAccess(post('/api/access/welcome', { email: 'reader@example.com' }), {
      ...env,
      ACCESS_CONTACTS: { async put() { throw new Error('KV unavailable') } },
      EMAIL: { async send() { sent = true; return { messageId: 'unexpected' } } },
    })
    expect(failed!.status).toBe(502)
    expect(sent).toBe(false)
    expect((await handleAccess(post('/api/access/welcome', { email: 'reader@example.com' }), { ...env, EMAIL: undefined }))!.status).toBe(503)
    expect((await handleAccess(post('/api/access/welcome', { email: 'reader@example.com' }), { ...env, ACCESS_CONTACTS: undefined }))!.status).toBe(503)
  })
  test('rejects invalid input, cross-origin requests, missing credentials and missing rate controls', async () => {
    expect((await handleAccess(post('/api/access/welcome', { email: 'invalid' }), env))!.status).toBe(400)
    expect((await handleAccess(post('/api/access/unlock', { code: 'A1B2C3D4' }, 'https://elsewhere.example'), env))!.status).toBe(403)
    expect((await handleAccess(post('/api/access/unlock', { code: 'A1B2C3D4' }), {}))!.status).toBe(503)
    expect((await handleAccess(post('/api/access/unlock', { code: 'A1B2C3D4' }), { ...env, CODE_RATE_LIMITER: undefined }))!.status).toBe(503)
  })
  test('wrong codes and rate limits fail closed', async () => {
    expect((await handleAccess(post('/api/access/unlock', { code: 'FFFFFFFF' }), env))!.status).toBe(401)
    expect((await handleAccess(post('/api/access/unlock', { code: 'A1B2C3D4' }), { ...env, CODE_RATE_LIMITER: { async limit() { return { success: false } } } }))!.status).toBe(429)
  })
  test('personalized and shared codes work; cookie tampering, expiry and secret rotation do not', async () => {
    const response = await handleAccess(post('/api/access/unlock', { code: await emailCode('reader@example.com', secret) }), env)
    expect(response!.status).toBe(200)
    expect(response!.headers.get('set-cookie')).toContain('HttpOnly; SameSite=Lax')
    expect(response!.headers.get('set-cookie')).toContain('; Secure')
    const cookie = await unlock()
    const request = (value: string) => new Request(origin + '/docs/api', { headers: { Cookie: value } })
    expect(await hasAccess(request(cookie), env)).toBe(true)
    expect(await hasAccess(request(cookie.slice(0, -1) + (cookie.endsWith('0') ? '1' : '0')), env)).toBe(false)
    expect(await hasAccess(request(cookie), { ...env, ACCESS_CODE_SECRET: 'B'.repeat(64) })).toBe(false)
    expect(await hasAccess(request(cookie), env, Date.now() + 31 * 86_400_000)).toBe(false)
  })
  test('private docs, raw exports and internal asset URLs cannot bypass the gate', async () => {
    const assets = { async fetch(request: Request) { return new Response(new URL(request.url).pathname.startsWith('/__private/') ? 'PRIVATE BODY' : 'PUBLIC PREVIEW') } }
    const workerEnv = { ...env, ASSETS: assets }
    const full = (path: string, cookie?: string) => serve(new Request(origin + path, { headers: cookie ? { Cookie: cookie } : {} }), workerEnv)
    expect((await full('/api/access/docs/lattices%3Aapi')).status).toBe(401)
    expect(await (await full('/agent-docs.json')).text()).toBe('PUBLIC PREVIEW')
    expect(await (await full('/agent-docs.json', await unlock())).text()).toBe('PRIVATE BODY')
    expect(await (await full('/api/access/docs/lattices%3Aapi', await unlock())).text()).toBe('PRIVATE BODY')
    expect((await full('/__private/docs/lattices/api.json', await unlock())).status).toBe(404)
    expect((await full('/%5f%5fprivate/docs/lattices/api.json', await unlock())).status).toBe(404)
    expect((await full('/__PRIVATE/docs/lattices/api.json', await unlock())).status).toBe(404)
    expect((await full('/%255f%255fprivate/docs/lattices/api.json', await unlock())).status).toBe(404)
    expect((await full('/api/access/docs/nonexistent', await unlock())).status).toBe(404)
  })
})
