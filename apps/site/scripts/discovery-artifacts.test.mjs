import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'
import { discoveryPaths, writeDiscoveryArtifacts } from './discovery-artifacts.mjs'
import { docMarkdownUrl } from '../src/lib/doc-markdown-url.mjs'

const actualRepo = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')
const origin = 'https://lattices.dev'
const hash = (text) => `sha256:${createHash('sha256').update(text).digest('hex')}`

async function fixture({ actual = false } = {}) {
  const scratch = await mkdtemp(join(tmpdir(), 'discovery-artifacts-'))
  const repoRoot = actual ? actualRepo : scratch
  const distDir = join(scratch, 'dist')
  const catalog = actual ? JSON.parse(await readFile(join(repoRoot, 'apps/site/src/data/docs-catalog.json'), 'utf8')) : {
    products: ['lattices', 'action', 'blink', 'speech'].map((id) => ({
      id, title: id, description: `${id} product.`,
      agent: { guide: `/${id}/docs/agents`, firstCheck: `${id} status`, expect: 'Current status.', boundary: `${id} owns its product runtime.` },
    })),
    pages: ['lattices', 'action', 'blink', 'speech'].map((product) => ({
      id: `${product}:agents`, product, slug: 'agents', title: `${product} agent guide`,
      source: `docs/${product}.md`, canonicalPath: `/${product}/docs/agents`, agent: true, kind: 'guide',
    })),
  }
  const write = async (path, content) => {
    await mkdir(dirname(join(distDir, path)), { recursive: true })
    await writeFile(join(distDir, path), content)
  }
  // Model artifacts emitted by the parent generator without running a site build.
  for (const prefix of ['', ...catalog.products.map((product) => product.docsHome || `/${product.id}/docs`)]) {
    for (const name of ['llms.txt', 'llms-full.txt', 'AGENTS.md', 'agent-docs.json']) await write(`${prefix}/${name}`, '# Existing public artifact\n')
  }
  for (const page of catalog.pages.filter((page) => page.agent && ['guide', 'reference'].includes(page.kind) && page.canonicalPath)) {
    await write(docMarkdownUrl(page.canonicalPath), `# ${page.title}\n`)
  }
  const setup = '---\nname: action-setup\ndescription: Install and verify Action.\n---\n\n# Existing Action setup\n\nPreserve this exact file.\n'
  const setupPath = '/.well-known/agent-skills/action-setup/SKILL.md'
  await write(setupPath, setup)
  await write(discoveryPaths.skills, JSON.stringify({
    $schema: 'https://unverified.invalid/schema.json',
    skills: [{ name: 'action-setup', description: 'Install and verify Action.', type: 'skill-md', url: setupPath, digest: hash(setup) }],
  }))
  return { scratch, repoRoot, distDir, catalog, write, setup, setupPath, origin }
}

async function readJson(data, path) { return JSON.parse(await readFile(join(data.distDir, path), 'utf8')) }
async function cleanup(data) { await rm(data.scratch, { recursive: true, force: true }) }

test('publishes all product skills, exact digests, and an honest documentation-only catalog', async () => {
  const data = await fixture({ actual: true })
  try {
    const result = await writeDiscoveryArtifacts(data)
    assert.equal(result.skills, 5)
    const index = await readJson(data, discoveryPaths.skills)
    assert.equal(index.$schema, undefined)
    assert.deepEqual(index.skills.map((skill) => skill.name), ['action-setup', 'lattices', 'action', 'blink', 'voice'])
    for (const skill of index.skills) {
      const url = new URL(skill.url)
      assert.equal(url.origin, origin)
      const bytes = await readFile(join(data.distDir, url.pathname))
      assert.equal(skill.digest, hash(bytes), skill.name)
      assert.match(bytes.toString(), new RegExp(`^---\\nname: ${skill.name}\\n`))
      assert.equal(skill.type, 'skill-md')
      assert.ok(skill.description.length > 0 && skill.description.length <= 1024)
      for (const [, href] of bytes.toString().matchAll(/\]\(([^)]+)\)/g)) {
        assert.match(href, /^https:\/\//, `${skill.name} has nonportable link ${href}`)
        const linked = new URL(href)
        if (linked.origin === origin && /\.(?:md|txt|json)$/.test(linked.pathname)) {
          assert.ok((await readFile(join(data.distDir, linked.pathname))).length, `Missing skill reference: ${href}`)
        }
      }
    }
    assert.equal(await readFile(join(data.distDir, data.setupPath), 'utf8'), data.setup)
    assert.equal(index.skills[0].digest, hash(data.setup))

    const catalog = await readJson(data, discoveryPaths.catalog)
    assert.equal(catalog.specVersion, '1.0')
    assert.equal(catalog.host, undefined)
    assert.equal(catalog.signature, undefined)
    assert.equal(new Set(catalog.entries.map((entry) => entry.identifier)).size, catalog.entries.length)
    for (const entry of catalog.entries) {
      assert.equal(entry.identifier, entry.url)
      const url = new URL(entry.url)
      assert.equal(url.origin, origin)
      assert.ok((await readFile(join(data.distDir, url.pathname))).length)
      assert.doesNotMatch(entry.type, /mcp-server-card|a2a-agent-card/)
      assert.equal(entry.trustManifest, undefined)
    }
    for (const prefix of ['', ...data.catalog.products.map((product) => product.docsHome || `/${product.id}/docs`)]) {
      for (const name of ['llms.txt', 'llms-full.txt', 'AGENTS.md']) {
        assert.ok(catalog.entries.some((entry) => entry.url === `${origin}${prefix}/${name}`))
      }
    }
    for (const product of data.catalog.products.filter((product) => ['lattices', 'blink', 'speech'].includes(product.id))) {
      const root = product.docsHome || `/${product.id}/docs`
      const instructions = `${origin}${root}/AGENTS.md`
      const document = `${origin}${root}/agents/index.md`
      assert.ok(catalog.entries.some((entry) => entry.url === instructions))
      assert.ok(catalog.entries.some((entry) => entry.url === document))
      assert.ok(!catalog.entries.some((entry) => entry.url === `${origin}${root}/agents.md`))
      assert.notEqual(
        await readFile(join(data.distDir, new URL(instructions).pathname), 'utf8'),
        await readFile(join(data.distDir, new URL(document).pathname), 'utf8'),
        'Agent instructions must not overwrite the documentation page on a case-insensitive filesystem',
      )
    }

    const coverage = await readJson(data, discoveryPaths.coverage)
    assert.equal(coverage.kind, 'documentation-discovery')
    assert.deepEqual(coverage.products.map((product) => product.id), ['lattices', 'action', 'blink', 'speech'])
    for (const id of ['agent-skills-discovery', 'ai-catalog']) assert.equal(coverage.formats.find((format) => format.id === id).status, 'draft')
    for (const format of coverage.formats) {
      for (const url of format.urls) assert.ok((await readFile(join(data.distDir, new URL(url).pathname))).length)
    }
    assert.equal(coverage.skills.find((skill) => skill.name === 'action').source, 'repository-skill-with-portable-links')
    assert.equal(coverage.skills.find((skill) => skill.name === 'blink').source, 'repository-skill-with-portable-links')
    assert.match(coverage.skills.find((skill) => skill.name === 'lattices').reason, /sibling files/)
    assert.match(coverage.skills.find((skill) => skill.name === 'voice').reason, /outside current automatic context/)
    assert.deepEqual(coverage.skills.find((skill) => skill.name === 'voice').products, ['lattices', 'speech'])
    const voice = await readFile(join(data.distDir, '/.well-known/agent-skills/voice/SKILL.md'), 'utf8')
    assert.match(voice, /Lattices owns listening/)
    assert.match(voice, /Voice owns spoken output/)
    assert.match(voice, /lats voice status --json/)
    assert.doesNotMatch(voice, /voice-command-protocol|\/archive\//)
    assert.deepEqual((await readdir(join(data.distDir, '.well-known'))).sort(), ['agent-skills', 'ai-catalog.json'])
  } finally { await cleanup(data) }
})

test('catalog fixtures without repository skills receive usable onboarding guides and reruns preserve existing setup', async () => {
  const data = await fixture()
  try {
    await writeDiscoveryArtifacts(data)
    const first = await readFile(join(data.distDir, discoveryPaths.skills), 'utf8')
    await writeDiscoveryArtifacts(data)
    assert.equal(await readFile(join(data.distDir, discoveryPaths.skills), 'utf8'), first)
    assert.equal(await readFile(join(data.distDir, data.setupPath), 'utf8'), data.setup)
    const coverage = await readJson(data, discoveryPaths.coverage)
    assert.ok(coverage.skills.filter((skill) => skill.name !== 'action-setup').every((skill) => skill.source === 'catalog-onboarding'))
    for (const skill of coverage.skills.filter((entry) => entry.name !== 'action-setup')) {
      const body = await readFile(join(data.distDir, new URL(skill.url).pathname), 'utf8')
      assert.match(body, /## First check/)
      assert.match(body, /released packages|Released packages/)
    }
  } finally { await cleanup(data) }
})

test('preserved skill corruption or missing files fail instead of publishing misleading hashes', async () => {
  const data = await fixture()
  try {
    await data.write(data.setupPath, `${data.setup}Changed bytes\n`)
    await assert.rejects(writeDiscoveryArtifacts(data), /Existing skill digest mismatch/)
    await rm(join(data.distDir, data.setupPath))
    await assert.rejects(writeDiscoveryArtifacts(data), { code: 'ENOENT' })
  } finally { await cleanup(data) }
})

test('invalid repository skill frontmatter fails instead of silently dropping the skill', async () => {
  const data = await fixture()
  try {
    const path = join(data.repoRoot, 'skills/action/SKILL.md')
    await mkdir(dirname(path), { recursive: true })
    await writeFile(path, '# Invalid skill\n')
    await assert.rejects(writeDiscoveryArtifacts(data), /missing YAML frontmatter/)
  } finally { await cleanup(data) }
})

test('unknown local Markdown dependencies use current catalog onboarding rather than broken links', async () => {
  const data = await fixture()
  try {
    const path = join(data.repoRoot, 'skills/action/SKILL.md')
    await mkdir(dirname(path), { recursive: true })
    await writeFile(path, '---\nname: action\ndescription: Use Action.\n---\n\n[Unavailable guide](../../private/guide.md)\n')
    await writeDiscoveryArtifacts(data)
    const coverage = await readJson(data, discoveryPaths.coverage)
    assert.match(coverage.skills.find((skill) => skill.name === 'action').reason, /outside current automatic context/)
    const body = await readFile(join(data.distDir, '/.well-known/agent-skills/action/SKILL.md'), 'utf8')
    assert.doesNotMatch(body, /private\/guide/)
  } finally { await cleanup(data) }
})

test('Canvas discovery uses the public route while retaining the installed blink skill and commands', async () => {
  const data = await fixture()
  try {
    const product = data.catalog.products.find((product) => product.id === 'blink')
    Object.assign(product, { title: 'Canvas', home: '/canvas', docsHome: '/canvas/docs' })
    product.agent.guide = '/canvas/docs/agents'
    const page = data.catalog.pages.find((page) => page.product === 'blink')
    page.canonicalPath = '/canvas/docs/agents'
    page.aliases = ['/blink/docs/agents']
    for (const name of ['llms.txt', 'llms-full.txt', 'AGENTS.md', 'agent-docs.json']) await data.write(`/canvas/docs/${name}`, '# Canvas public artifact\n')
    await data.write(docMarkdownUrl(page.canonicalPath), '# Canvas agent guide\n')
    const skillPath = join(data.repoRoot, 'skills/blink/SKILL.md')
    await mkdir(dirname(skillPath), { recursive: true })
    await writeFile(skillPath, [
      '---', 'name: blink', 'description: Drive Blink spatial notes.',
      'compatibility: Requires Blink.app.', '---', '', '# Blink', '',
      'Blink uses `blink` and `~/Library/Application Support/Blink/`.',
      'Keep `BLINK_HOME` and `blink.lastWriter` unchanged.', '',
      '```sh', 'npm install -g @arach/blink', 'blink ls --json', '```', '',
      '[Agents](https://lattices.dev/blink/docs/agents)',
      'https://lattices.dev/blink', '',
    ].join('\n'))
    await writeDiscoveryArtifacts(data)
    const index = await readJson(data, discoveryPaths.skills)
    const skill = index.skills.find((skill) => skill.name === 'blink')
    assert.equal(skill.description, 'Drive Canvas spatial notes.')
    const text = await readFile(join(data.distDir, new URL(skill.url).pathname), 'utf8')
    assert.equal(skill.digest, hash(text))
    assert.match(text, /^# Canvas$/m)
    assert.match(text, /Canvas 2\.3\.0 ships `Canvas\.app` and the `canvas` CLI/)
    assert.match(text, /compatibility: Requires Blink\.app\./)
    assert.match(text, /`~\/Library\/Application Support\/Blink\/`/)
    assert.match(text, /```sh\nnpm install -g @arach\/blink\nblink ls --json\n```/)
    assert.match(text, /https:\/\/lattices\.dev\/canvas\/docs\/agents\/index\.md/)
    assert.match(text, /^https:\/\/lattices\.dev\/canvas$/m)
    assert.doesNotMatch(text, /npm install -g @arach\/canvas|\bcanvas ls\b/)
    const coverage = await readJson(data, discoveryPaths.coverage)
    const canvas = coverage.products.find((entry) => entry.id === 'blink')
    assert.equal(canvas.title, 'Canvas')
    assert.equal(canvas.docs, `${origin}/canvas/docs`)
    assert.equal(canvas.instructions, `${origin}/canvas/docs/AGENTS.md`)
    assert.ok(canvas.skills.includes(skill.url))
    const catalog = await readJson(data, discoveryPaths.catalog)
    assert.ok(catalog.entries.some((entry) => entry.url === canvas.instructions))
    assert.ok(catalog.entries.some((entry) => entry.url === `${origin}/canvas/docs/agents/index.md`))
    assert.ok(!catalog.entries.some((entry) => new URL(entry.url).pathname.startsWith('/blink/')))
  } finally { await cleanup(data) }
})
