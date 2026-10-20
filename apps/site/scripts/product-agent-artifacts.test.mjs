import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { formatDocsBundle, parseDocArtifact, writeAgentArtifacts } from './agent-docs.mjs'
import { writeProductAgentArtifacts } from './product-agent-artifacts.mjs'

async function fixture() {
  const repoRoot = await mkdtemp(join(tmpdir(), 'product-agent-docs-'))
  const siteDir = join(repoRoot, 'apps/site')
  const distDir = join(siteDir, 'dist')
  const products = ['lattices', 'action', 'blink', 'speech'].map((id) => ({ id, title: id, description: `${id} product`, home: `/${id}` }))
  products[3].agent = { guide: '/speech/docs/overview', firstCheck: 'lats voice status --json', expect: 'A helper section.', boundary: 'Speech owns spoken output.' }
  const page = (product, slug, source, overrides = {}) => ({
    id: `${product}:${slug}`, product, slug, source, title: `${product} ${slug}`, kind: 'guide',
    canonicalPath: `/${product}/docs/${slug}`, aliases: [], navGroup: 'Start', agent: true, rawAliases: [], ...overrides,
  })
  const pages = [
    page('lattices', 'overview', 'docs/overview.md', { aliases: ['/docs/overview'], rawAliases: ['/docs/markdown/overview.md', '/agent/raw/docs/overview.md'] }),
    page('lattices', 'api', 'docs/api.md'),
    page('action', 'overview', 'products/action/docs/overview.md', { rawAliases: ['/action/overview.md'] }),
    page('blink', 'overview', 'products/blink/docs/overview.md'),
    page('speech', 'overview', 'products/voice/docs/overview.md'),
    // Even a mistaken agent:true flag must never put proposals or prompts in automatic context.
    page('lattices', 'future', 'docs/future.md', { kind: 'proposal', canonicalPath: '/lattices/docs/archive/future', rawAliases: ['/docs/markdown/future.md'] }),
    page('lattices', 'prompts/voice', 'docs/prompts/voice.md', { kind: 'prompt', canonicalPath: null, rawAliases: ['/docs/markdown/prompts/voice.md'] }),
    page('lattices', 'vox', 'docs/vox.md', { kind: 'history', canonicalPath: null, rawAliases: ['/docs/markdown/vox.md'] }),
    page('lattices', 'release', 'docs/release.md', { agent: false, kind: 'reference' }),
  ]
  const catalog = { products, pages }
  const sources = {
    'docs/overview.md': '\r\n# Current workspace\r\n\r\n[API](api.md#calls) and [old link](/docs/overview).\r\n\r\n```md\r\n[API](api.md)\r\n```\r\n',
    'docs/api.md': '# Workspace API\n\n<MacRuntimeDiagram />\n\n| Port | Owner |\n|------|-------|\n| 9399 | Lattices |\n\n<LinuxRuntimeDiagram />\n\nLinux uses a Bun host.\n',
    'products/action/docs/overview.md': '# Current computer use\n',
    'products/blink/docs/overview.md': '# Current notes\n',
    'products/voice/docs/overview.md': '# Current speech\n',
    'docs/future.md': '# PROPOSAL_SENTINEL\n',
    'docs/prompts/voice.md': '# PROMPT_SENTINEL\n',
    'docs/vox.md': '# STALE_VOX_SENTINEL\n',
    'docs/release.md': '# MAINTAINER_SENTINEL\n',
  }
  for (const [source, body] of Object.entries(sources)) {
    await mkdir(dirname(join(repoRoot, source)), { recursive: true })
    await writeFile(join(repoRoot, source), body)
  }
  await mkdir(join(siteDir, 'src/data'), { recursive: true })
  await writeFile(join(siteDir, 'src/data/docs-catalog.json'), JSON.stringify(catalog))
  await writeFile(join(repoRoot, 'AGENTS.md'), '# Repository instructions\n\nMAINTAINER_SENTINEL: use /Users/maintainer/dev with ws://127.0.0.1:9399 and no authentication.\n')
  await writeFile(join(repoRoot, 'llms.txt'), '# OLD_INDEX_SENTINEL\n')
  await writeFile(join(repoRoot, 'products/action/docs.json'), JSON.stringify({
    project: 'action', version: '0.3.1', generatedBy: 'Old generator', generatedAt: 'old',
    sections: [{ id: 'vision', title: 'PROPOSAL_SENTINEL', content: 'STALE_VOX_SENTINEL' }],
  }))
  return { repoRoot, siteDir, distDir, catalog, sources }
}

test('publishes product context and keeps raw legacy references byte-exact', async () => {
  const data = await fixture()
  try {
    const result = await writeAgentArtifacts(data)
    assert.equal(result.products, 4)
    assert.equal(result.currentDocs, 5)
    const read = (url) => readFile(join(data.distDir, url), 'utf8')
    const manifest = JSON.parse(await read('/agent-docs.json'))
    assert.equal(manifest.version, 1)
    assert.ok(manifest.project.name)
    assert.deepEqual(manifest.docs.map((doc) => doc.id), ['lattices:overview', 'lattices:api', 'action:overview', 'blink:overview', 'speech:overview'])
    assert.deepEqual(manifest.prompts, [])
    for (const url of ['/llms-full.txt', '/agent-context.md', '/agent/context.md', '/agent/bundles/all.md', '/docs/all.md', '/agent-context.json', '/agent-docs.json']) {
      assert.doesNotMatch(await read(url), /PROPOSAL_SENTINEL|PROMPT_SENTINEL|STALE_VOX_SENTINEL|MAINTAINER_SENTINEL|OLD_INDEX_SENTINEL/)
    }
    for (const page of data.catalog.pages) {
      for (const alias of page.rawAliases) assert.equal(await read(alias), data.sources[page.source], alias)
    }
    assert.equal(await read('/lattices/docs/markdown/overview.md'), data.sources['docs/overview.md'])
    assert.equal(await read('/lattices/docs/markdown/archive/future.md'), data.sources['docs/future.md'])
    assert.match(await read('/prompts/voice.md'), /PROMPT_SENTINEL/)
    assert.match(await read('/prompts.json'), /PROMPT_SENTINEL/)
    const archive = JSON.parse(await read('/agent/archive.json'))
    assert.deepEqual(archive.docs.map((doc) => doc.id), ['lattices:future', 'lattices:prompts/voice', 'lattices:vox', 'lattices:release'])
    assert.equal(archive.docs[0].current, false)
    const bundle = await read('/lattices/docs/llms-full.txt')
    assert.match(bundle, /\[API\]\(\/lattices\/docs\/api#calls\)/)
    assert.match(bundle, /\[old link\]\(\/lattices\/docs\/overview\)/)
    assert.match(bundle, /```md\n\[API\]\(api.md\)\n```/)
    assert.doesNotMatch(bundle, /MacRuntimeDiagram|LinuxRuntimeDiagram/)
    assert.match(bundle, /\| 9399 \| Lattices \|/)
    assert.match(bundle, /Linux uses a Bun host/)
    assert.match(await read('/lattices/docs/markdown/api.md'), /MacRuntimeDiagram/)
    for (const product of data.catalog.products) {
      const productManifest = JSON.parse(await read(`/${product.id}/docs/agent-docs.json`))
      assert.ok(productManifest.docs.every((doc) => doc.product === product.id))
      assert.match(await read('/llms.txt'), new RegExp(`/${product.id}/docs/llms.txt`))
      assert.equal(await read(`/${product.id}/llms.txt`), await read(`/${product.id}/docs/llms.txt`))
      assert.equal(await read(`/${product.id}/llms-full.txt`), await read(`/${product.id}/docs/llms-full.txt`))
      for (const doc of productManifest.docs) assert.equal(await read(doc.rawUrl), data.sources[doc.sourcePath])
    }
    // A product's first check leads its index; products without one omit the section.
    const speechIndex = await read('/speech/docs/llms.txt')
    assert.match(speechIndex, /\*\*First check\*\*\n\nSpeech owns spoken output\.\n\nAgent guide: \[Current speech\]\(https:\/\/lattices\.dev\/speech\/docs\/overview\.md\)\.\n\nFirst check \(read-only\): `lats voice status --json`/)
    assert.ok(speechIndex.indexOf('**First check**') < speechIndex.indexOf('## Current documentation'))
    assert.doesNotMatch(await read('/blink/docs/llms.txt'), /\*\*First check\*\*/)
    assert.match(await read('/llms.txt'), /Human docs: https:\/\/lattices\.dev\/speech\/docs\. First check: `lats voice status --json`\./)
    const summary = JSON.parse(await read('/docs.json'))
    assert.ok(summary.docs.every((doc) => !('markdown' in doc) && !('content' in doc)))
    const legacyAction = JSON.parse(await read('/action/docs.json'))
    assert.equal(legacyAction.project, 'action')
    assert.equal(legacyAction.version, '0.3.1')
    assert.deepEqual(legacyAction.sections.map((section) => section.id), ['overview'])
    assert.equal(legacyAction.sections[0].title, 'Current computer use')
    assert.doesNotMatch(await read('/action/docs.json'), /PROPOSAL_SENTINEL|STALE_VOX_SENTINEL/)
  } finally {
    await rm(data.repoRoot, { recursive: true, force: true })
  }
})

test('rejects conflicting raw aliases instead of silently replacing a product source', async () => {
  const data = await fixture()
  try {
    data.catalog.pages[2].rawAliases.push('/docs/markdown/overview.md')
    await assert.rejects(writeProductAgentArtifacts(data), /Conflicting raw artifact/)
  } finally {
    await rm(data.repoRoot, { recursive: true, force: true })
  }
})

test('exports public agent instructions scoped to product ownership instead of maintainer rules', async () => {
  const data = await fixture()
  try {
    const maintainerSource = await readFile(join(data.repoRoot, 'AGENTS.md'), 'utf8')
    await writeAgentArtifacts(data)
    const read = (url) => readFile(join(data.distDir, url), 'utf8')
    const family = await read('/AGENTS.md')
    assert.notEqual(family, maintainerSource)
    assert.equal(await readFile(join(data.repoRoot, 'AGENTS.md'), 'utf8'), maintainerSource)
    const manifest = JSON.parse(await read('/agent-docs.json'))
    assert.equal(manifest.artifacts.agents, '/AGENTS.md')
    const context = JSON.parse(await read('/agent-context.json'))
    assert.equal(context.rootContext.agents, family)
    assert.equal(context.rootContext.agentsUrl, manifest.artifacts.agents)
    assert.ok((await read('/llms.txt')).includes('[Public agent instructions](https://lattices.dev/AGENTS.md)'))

    for (const product of data.catalog.products) {
      const manifestProduct = manifest.products.find((entry) => entry.id === product.id)
      const agentsPath = `/${product.id}/docs/AGENTS.md`
      const instructions = await read(agentsPath)
      const productManifest = JSON.parse(await read(`/${product.id}/docs/agent-docs.json`))
      assert.equal(manifestProduct.artifacts.agents, agentsPath)
      assert.equal(productManifest.artifacts.agents, agentsPath)
      assert.ok(family.includes(`[Instructions](https://lattices.dev${agentsPath})`))
      assert.ok(family.includes(`[Index](https://lattices.dev/${product.id}/docs/llms.txt)`))
      assert.ok((await read(`/${product.id}/docs/llms.txt`)).includes(`[Public agent instructions](https://lattices.dev${agentsPath})`))
      assert.ok(instructions.includes(product.description))
      assert.ok(instructions.includes(`/${product.id}/docs/markdown/overview.md`))
      assert.ok(instructions.indexOf(`/${product.id}/docs/llms.txt`) < instructions.indexOf(`/${product.id}/docs/markdown/overview.md`))
      assert.match(instructions, /family ownership map.*\/AGENTS\.md/)
      for (const other of data.catalog.products.filter((entry) => entry.id !== product.id)) {
        assert.ok(!instructions.includes(`/${other.id}/docs/`), `instructions for ${product.id} cross-scoped to ${other.id}`)
      }
      for (const guide of [family, instructions]) {
        assert.doesNotMatch(guide, /\]\(\//, 'public instruction links must remain usable outside the site')
        assert.doesNotMatch(guide, /MAINTAINER_SENTINEL|Repository instructions|\/Users\/|127\.0\.0\.1|9399|4319|9397/)
        assert.match(guide, /released packages and unreleased source builds/)
        assert.match(guide, /documented CLI and authentication/)
        assert.match(guide, /Proposals, historical reports, and prompt templates/)
        assert.match(guide, /not instructions for shipped behavior/)
        for (const [, url] of guide.matchAll(/\]\(https:\/\/lattices\.dev(\/[^)]+\.(?:md|json|txt))\)/g)) {
          assert.ok((await read(url)).length > 0, `missing instruction reference ${url}`)
        }
      }
    }
  } finally {
    await rm(data.repoRoot, { recursive: true, force: true })
  }
})

test('fails when a catalog source is missing instead of publishing an incomplete product', async () => {
  const data = await fixture()
  try {
    await rm(join(data.repoRoot, 'products/voice/docs/overview.md'))
    await assert.rejects(writeProductAgentArtifacts(data), { code: 'ENOENT' })
  } finally {
    await rm(data.repoRoot, { recursive: true, force: true })
  }
})


test('publishes readable Markdown twins, portable indexes and safe legacy instructions', async () => {
  const data = await fixture()
  try {
    await writeAgentArtifacts(data)
    const read = (url) => readFile(join(data.distDir, url), 'utf8')
    for (const page of data.catalog.pages.filter((entry) => entry.canonicalPath)) {
      const body = await read(`${page.canonicalPath}.md`)
      assert.equal(await read(`${page.canonicalPath}/index.md`), body)
      assert.match(body, new RegExp(`Canonical page: https://lattices.dev${page.canonicalPath}`))
      assert.doesNotMatch(body, /MacRuntimeDiagram|LinuxRuntimeDiagram/)
      for (const alias of page.aliases) assert.equal(await read(`${alias}.md`), body)
    }
    assert.match(await read('/lattices/docs/overview.md'), /\[API\]\(https:\/\/lattices\.dev\/lattices\/docs\/api#calls\)/)
    const indexes = ['/llms.txt', ...data.catalog.products.map((p) => `/${p.id}/docs/llms.txt`)]
    for (const url of indexes) {
      const index = await read(url)
      assert.ok(index.startsWith('# '))
      assert.doesNotMatch(index, /\]\(\//, 'index links must be portable')
      let inFiles = false
      for (const line of index.split('\n').filter(Boolean)) {
        if (line.startsWith('## ')) { inFiles = true; continue }
        if (inFiles) assert.match(line, /^- \[.+\]\(https:\/\//, 'llms file sections must contain linked lists')
      }
    }
    for (const product of data.catalog.products.filter((entry) => entry.id !== 'blink')) {
      assert.equal(await read(`/${product.id}/AGENTS.md`), await read(`/${product.id}/docs/AGENTS.md`))
    }
    assert.equal(await read('/blink/agents.md'), await read('/blink/docs/AGENTS.md'))
    assert.equal(await read('/.nojekyll'), '')
  } finally { await rm(data.repoRoot, { recursive: true, force: true }) }
})

test('uses real headings for document titles and preserves fenced shell comments in raw exports', async () => {
  const data = await fixture()
  try {
    const source = [
      '---', 'title: Frontmatter title', '---', '', '## Usage', '',
      '````sh', '# Shell comment', '```', '# A shorter fence does not close the block',
      '```` trailing text', '# A fence with trailing text does not close the block',
      '~~~~', '# A different fence does not close the block', '````', '',
      '   ~~~sh', '# Tilde shell comment', '   ~~~~', '', '### After fences', '',
    ].join('\r\n')
    const fallbackSource = '~~~sh\n# Not the document title\necho ready\n~~~\n\n## Real section\n'
    await writeFile(join(data.repoRoot, 'docs/overview.md'), source)
    await writeFile(join(data.repoRoot, 'docs/api.md'), fallbackSource)
    const parsed = parseDocArtifact(join(data.repoRoot, 'docs/overview.md'), source, data)
    assert.deepEqual(parsed.headings.map(({ depth, text }) => ({ depth, text })), [
      { depth: 2, text: 'Usage' }, { depth: 3, text: 'After fences' },
    ])
    assert.match(formatDocsBundle([parsed]), /# Frontmatter title\n\n## Usage/)

    await writeAgentArtifacts(data)
    const read = (url) => readFile(join(data.distDir, url), 'utf8')
    const manifest = JSON.parse(await read('/agent-docs.json'))
    const overview = manifest.docs.find((entry) => entry.id === 'lattices:overview')
    const api = manifest.docs.find((entry) => entry.id === 'lattices:api')
    assert.equal(overview.title, 'Frontmatter title')
    assert.deepEqual(overview.headings, parsed.headings)
    assert.equal(api.title, 'lattices api', 'a catalog title wins when no authored H1 or frontmatter title exists')
    assert.deepEqual(api.headings.map((heading) => heading.text), ['Real section'])
    assert.match(await read('/lattices/docs/overview.md'), /^# Frontmatter title\n\nCanonical page:/)
    assert.match(await read('/lattices/docs/api.md'), /^# lattices api\n\nCanonical page:/)
    const bundle = await read('/lattices/docs/llms-full.txt')
    assert.match(bundle, /# Frontmatter title\n\n## Usage/)
    assert.match(bundle, /# lattices api\n\n~~~sh\n# Not the document title/)
    assert.match(bundle, /# A fence with trailing text does not close the block/)
    assert.equal(await read('/lattices/docs/markdown/overview.md'), source)
    assert.equal(await read('/docs/markdown/overview.md'), source)
    assert.equal(await read('/lattices/docs/markdown/api.md'), fallbackSource)
    assert.equal(await readFile(join(data.repoRoot, 'docs/overview.md'), 'utf8'), source)
  } finally { await rm(data.repoRoot, { recursive: true, force: true }) }
})

test('keeps agents documentation distinct from public AGENTS instructions on case-insensitive hosts', async () => {
  const data = await fixture()
  try {
    for (const product of data.catalog.products) {
      const source = `products/${product.id}/docs/agents.md`
      await mkdir(dirname(join(data.repoRoot, source)), { recursive: true })
      await writeFile(join(data.repoRoot, source), `# ${product.id} authored agent guide\n`)
      data.catalog.pages.push({
        ...data.catalog.pages[0], id: `${product.id}:agents`, product: product.id, slug: 'agents',
        source, canonicalPath: `/${product.id}/docs/agents`, aliases: [],
        rawAliases: product.id === 'blink' ? ['/blink/agents.md'] : [],
      })
    }
    const result = await writeProductAgentArtifacts(data)
    const read = (url) => readFile(join(data.distDir, url), 'utf8')
    for (const product of data.catalog.products) {
      const pageUrl = `/${product.id}/docs/agents/index.md`
      assert.ok(result.artifacts.includes(pageUrl))
      assert.ok(!result.artifacts.includes(`/${product.id}/docs/agents.md`))
      assert.match(await read(pageUrl), new RegExp(`# ${product.id} authored agent guide`))
      assert.match(await read(`/${product.id}/docs/AGENTS.md`), new RegExp(`# ${product.id}: agent instructions`))
      const manifest = JSON.parse(await read(`/${product.id}/docs/agent-docs.json`))
      assert.equal(manifest.docs.find((entry) => entry.slug === 'agents').markdownUrl, pageUrl)
      assert.ok((await read(`/${product.id}/docs/llms.txt`)).includes(`https://lattices.dev${pageUrl}`))
    }
    assert.ok(!result.artifacts.includes('/blink/AGENTS.md'))
    assert.equal(await read('/blink/agents.md'), await read('/blink/docs/AGENTS.md'))
    const uniquePaths = [...new Set(result.artifacts)]
    assert.equal(new Set(uniquePaths.map((url) => url.toLowerCase())).size, uniquePaths.length)
  } finally { await rm(data.repoRoot, { recursive: true, force: true }) }
})

test('rejects case-only artifact aliases before overwriting an existing file', async () => {
  const data = await fixture()
  try {
    data.catalog.pages[0].rawAliases.push('/Case.md', '/case.md')
    await assert.rejects(writeProductAgentArtifacts(data), /Case-insensitive artifact collision: \/Case\.md and \/case\.md/)
    assert.equal(await readFile(join(data.distDir, 'Case.md'), 'utf8'), data.sources['docs/overview.md'])
  } finally { await rm(data.repoRoot, { recursive: true, force: true }) }
})

test('Canvas resources follow the public docs root and preserve all Blink retrieval aliases', async () => {
  const data = await fixture()
  try {
    const product = data.catalog.products.find((product) => product.id === 'blink')
    Object.assign(product, {
      title: 'Canvas', home: '/canvas', docsHome: '/canvas/docs',
      agent: { guide: '/canvas/docs/agents', firstCheck: 'blink ls --json', expect: 'The current notes.', boundary: 'Canvas owns spatial notes.' },
    })
    const overview = data.catalog.pages.find((page) => page.product === 'blink')
    overview.aliases.push(overview.canonicalPath)
    overview.canonicalPath = '/canvas/docs/overview'
    const source = 'products/blink/docs/agents.md'
    await writeFile(join(data.repoRoot, source), '# Canvas agent guide\n\nUse `blink ls --json`.\n')
    data.catalog.pages.push({
      ...overview, id: 'blink:agents', slug: 'agents', source,
      canonicalPath: '/canvas/docs/agents', aliases: ['/blink/docs/agents'],
      rawAliases: ['/blink/agents.md'],
    })
    const archivedSource = 'products/blink/docs/retired.md'
    await writeFile(join(data.repoRoot, archivedSource), '# Historical note\n')
    data.catalog.pages.push({
      ...overview, id: 'blink:retired', slug: 'retired', source: archivedSource,
      kind: 'history', agent: false, canonicalPath: null, aliases: [],
    })
    const result = await writeProductAgentArtifacts(data)
    const read = (path) => readFile(join(data.distDir, path), 'utf8')
    for (const file of ['llms.txt', 'llms-full.txt', 'AGENTS.md', 'agent-docs.json']) {
      assert.equal(await read(`/canvas/docs/${file}`), await read(`/blink/docs/${file}`))
    }
    for (const file of ['llms.txt', 'llms-full.txt']) {
      assert.equal(await read(`/canvas/${file}`), await read(`/canvas/docs/${file}`))
      assert.equal(await read(`/blink/${file}`), await read(`/canvas/docs/${file}`))
    }
    const instructions = await read('/canvas/docs/AGENTS.md')
    assert.equal(await read('/canvas/AGENTS.md'), instructions)
    assert.equal(await read('/blink/agents.md'), instructions)
    assert.match(instructions, /^# Canvas: agent instructions/m)
    assert.match(instructions, /current release still uses `blink`, `@arach\/blink`, `Blink\.app`, `BLINK_HOME`/)
    assert.doesNotMatch(instructions, /`canvas ls|Canvas\.app|CANVAS_HOME/)
    assert.ok(!result.artifacts.includes('/canvas/agents.md'))
    assert.ok(!result.artifacts.includes('/blink/AGENTS.md'))
    for (const suffix of ['overview.md', 'agents/index.md']) {
      assert.equal(await read(`/canvas/docs/${suffix}`), await read(`/blink/docs/${suffix}`))
    }
    assert.notEqual(await read('/canvas/docs/agents/index.md'), instructions)
    for (const suffix of ['overview.md', 'agents.md', 'archive/retired.md']) {
      assert.equal(await read(`/canvas/docs/markdown/${suffix}`), await read(`/blink/docs/markdown/${suffix}`))
    }
    const manifest = JSON.parse(await read('/agent-docs.json'))
    assert.match(manifest.project.description, /Canvas/)
    const canvas = manifest.products.find((entry) => entry.id === 'blink')
    assert.equal(canvas.title, 'Canvas')
    assert.equal(canvas.docs, '/canvas/docs')
    assert.equal(canvas.artifacts.llms, '/canvas/docs/llms.txt')
    assert.equal(manifest.docs.find((entry) => entry.id === 'blink:overview').rawUrl, '/canvas/docs/markdown/overview.md')
    const family = await read('/llms.txt')
    assert.match(family, /\[Canvas\]\(https:\/\/lattices\.dev\/canvas\/docs\/llms\.txt\)/)
    assert.doesNotMatch(family, /https:\/\/lattices\.dev\/blink\//)
    assert.match(await read('/canvas/docs/llms.txt'), /First check \(read-only\): `blink ls --json`/)
    const uniquePaths = [...new Set(result.artifacts)]
    assert.equal(new Set(uniquePaths.map((path) => path.toLowerCase())).size, uniquePaths.length)
  } finally { await rm(data.repoRoot, { recursive: true, force: true }) }
})
