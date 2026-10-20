import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { join, posix, resolve, sep } from 'node:path'
import actionGuide from '../src/data/action-start.json' with { type: 'json' }
import { docMarkdownUrl } from '../src/lib/doc-markdown-url.mjs'

export const discoveryPaths = Object.freeze({
  skills: '/.well-known/agent-skills/index.json',
  catalog: '/.well-known/ai-catalog.json',
  coverage: '/agent/discovery.json',
})

const specifications = Object.freeze({
  llms: 'https://llmstxt.org/',
  agents: 'https://agents.md/',
  markdown: 'https://www.rfc-editor.org/rfc/rfc7763.html',
  skills: 'https://agentskills.io/specification',
  skillDiscovery: 'https://github.com/agentskills/agentskills/pull/254',
  aiCatalog: 'https://ai-catalog.io/spec/',
  a2a: 'https://a2a-protocol.org/latest/specification/',
  mcp: 'https://github.com/modelcontextprotocol/ext-server-card/blob/main/docs/discovery.md',
  oauth: 'https://modelcontextprotocol.io/specification/latest/basic/authorization',
})

const skillDefinitions = [
  { product: 'lattices', name: 'lattices', source: 'skills/lattices/SKILL.md' },
  { product: 'action', name: 'action', source: 'skills/action/SKILL.md' },
  { product: 'blink', name: 'blink', source: 'skills/blink/SKILL.md' },
  { product: 'speech', name: 'voice', source: 'skills/voice/SKILL.md' },
]

/** Publish documentation and skill discovery, without advertising an execution service. */
export async function writeDiscoveryArtifacts({ repoRoot, distDir, catalog, write, products = catalog.products, currentEntries, origin = actionGuide.siteUrl }) {
  const siteOrigin = new URL(origin).origin
  const absolute = (path) => new URL(path, `${siteOrigin}/`).href
  const docs = (currentEntries || catalog.pages.filter(isCurrentPage)).map((entry) => ({
    ...entry,
    source: entry.sourcePath || entry.source,
    url: entry.url || entry.canonicalPath,
  }))
  const productInfo = products.map((product) => {
    const root = product.docsHome || product.docs || `${product.home && product.home !== '/' ? product.home.replace(/\/$/, '') : `/${product.id}`}/docs`
    return {
      ...product,
      docs: root,
      artifacts: product.artifacts || {
        llms: `${root}/llms.txt`,
        allMarkdown: `${root}/llms-full.txt`,
        agents: `${root}/AGENTS.md`,
        fullManifest: `${root}/agent-docs.json`,
      },
    }
  })
  const previous = await readOptional(join(distDir, discoveryPaths.skills))
  const previousIndex = previous === null ? { skills: [] } : JSON.parse(previous)
  if (!Array.isArray(previousIndex.skills)) throw new Error('Existing skill discovery index has no skills array')

  // The Action onboarding writer runs first. Keep its skill and other independent
  // entries; only replace entries owned by this generator on subsequent runs.
  const ownedNames = new Set(skillDefinitions.filter((definition) => productInfo.some((product) => product.id === definition.product)).map((definition) => definition.name))
  const skills = []
  const skillSources = []
  for (const entry of previousIndex.skills.filter((entry) => !ownedNames.has(entry.name))) {
    if (entry.type !== 'skill-md') throw new Error(`Cannot verify existing skill type: ${entry.type}`)
    const url = absolute(entry.url)
    const bytes = await readFile(localArtifactPath(distDir, url, siteOrigin))
    const metadata = skillMetadata(bytes.toString('utf8'))
    if (metadata.name !== entry.name || metadata.description !== entry.description) throw new Error(`Existing skill metadata mismatch: ${entry.name}`)
    if (entry.digest !== digest(bytes)) throw new Error(`Existing skill digest mismatch: ${entry.name}`)
    if (skills.some((skill) => skill.name === entry.name)) throw new Error(`Duplicate existing skill: ${entry.name}`)
    skills.push({ ...entry, url })
    skillSources.push({ name: entry.name, url, products: entry.name === 'action-setup' ? ['action'] : [], source: 'existing-published-skill' })
  }

  for (const definition of skillDefinitions) {
    const product = productInfo.find((entry) => entry.id === definition.product)
    if (!product) continue
    const source = await readOptional(join(repoRoot, definition.source))
    const prepared = source === null
      ? { reason: 'Repository skill is unavailable in this documentation source.' }
      : portableSkill(source, definition, catalog, absolute)
    const text = presentProductSkill(prepared.text || onboardingSkill(definition, product, productInfo, docs, absolute), product)
    const metadata = skillMetadata(text)
    const path = `/.well-known/agent-skills/${definition.name}/SKILL.md`
    await write(path, text)
    const url = absolute(path)
    skills.push({ ...metadata, type: 'skill-md', url, digest: digest(text) })
    skillSources.push({
      name: definition.name,
      url,
      products: definition.name === 'voice' ? ['lattices', 'speech'] : [definition.product],
      source: prepared.text ? 'repository-skill-with-portable-links' : 'catalog-onboarding',
      ...(prepared.reason ? { reason: prepared.reason } : {}),
    })
  }
  // The proposal's schema host is not required by its format. Do not advertise an
  // unverified remote JSON Schema URL or copy stale schema metadata from a writer.
  await write(discoveryPaths.skills, json({ skills }))

  const family = { llms: '/llms.txt', allMarkdown: '/llms-full.txt', agents: '/AGENTS.md', fullManifest: '/agent-docs.json' }
  const collections = [family, ...productInfo.map((product) => product.artifacts)]
  const urlsFor = (key) => collections.map((paths) => absolute(paths[key]))
  const markdownUrls = [...new Set(docs.filter((doc) => doc.url).map((doc) => absolute(docMarkdownUrl(doc.url))))]
  const entries = []
  const add = (url, type) => {
    if (!entries.some((entry) => entry.url === url)) entries.push({ identifier: url, type, url })
  }
  for (const url of [...urlsFor('llms'), ...urlsFor('allMarkdown')]) add(url, 'text/plain')
  for (const url of [...urlsFor('agents'), ...markdownUrls]) add(url, 'text/markdown')
  for (const url of urlsFor('fullManifest')) add(url, 'application/json')
  for (const skill of skills) add(skill.url, 'application/agent-skills+md')
  add(absolute(discoveryPaths.skills), 'application/json')
  add(absolute(discoveryPaths.coverage), 'application/json')
  await write(discoveryPaths.catalog, json({ specVersion: '1.0', entries }))

  const coverage = {
    version: 1,
    kind: 'documentation-discovery',
    description: 'Public product documentation and downloadable agent instructions. These resources do not expose a hosted agent, MCP server, or local runtime.',
    products: productInfo.map((product) => ({
      id: product.id, title: product.title, docs: absolute(product.docs),
      index: absolute(product.artifacts.llms), instructions: absolute(product.artifacts.agents),
      fullContext: absolute(product.artifacts.allMarkdown), manifest: absolute(product.artifacts.fullManifest),
      skills: skillSources.filter((skill) => skill.products.includes(product.id)).map((skill) => skill.url),
    })),
    formats: [
      { id: 'llms-txt', status: 'proposal', specification: specifications.llms, urls: urlsFor('llms') },
      { id: 'llms-full-txt', status: 'community-convention', description: 'Complete current context; not a separate requirement of the llms.txt proposal.', urls: urlsFor('allMarkdown') },
      { id: 'agents-md', status: 'community-convention', specification: specifications.agents, description: 'Curated product-use guidance, not local repository maintenance instructions.', urls: urlsFor('agents') },
      { id: 'markdown', status: 'registered-media-type', specification: specifications.markdown, urls: markdownUrls },
      { id: 'documentation-manifest', status: 'site-specific', urls: urlsFor('fullManifest') },
      { id: 'agent-skills', status: 'published-specification', specification: specifications.skills, urls: skills.map((skill) => skill.url) },
      { id: 'agent-skills-discovery', status: 'draft', formatVersion: '0.2.0', specification: specifications.skillDiscovery, urls: [absolute(discoveryPaths.skills)] },
      { id: 'ai-catalog', status: 'draft', formatVersion: '1.0', specification: specifications.aiCatalog, urls: [absolute(discoveryPaths.catalog)] },
    ],
    skills: skillSources,
    omissions: [
      { format: 'A2A Agent Card', specification: specifications.a2a, reason: 'This site does not host an A2A service. No agent-card.json or legacy agent.json is advertised at the well-known root.' },
      { format: 'MCP Server Card', specification: specifications.mcp, reason: 'Documented local MCP configuration is not a hosted HTTP MCP service. No remote server card is advertised.' },
      { format: 'OAuth discovery metadata', specification: specifications.oauth, reason: 'This documentation site is not an authorization server or protected MCP resource.' },
      { format: 'OpenAPI and API catalog', reason: 'No public HTTP execution API is being described. Local runtime contracts remain in their product references.' },
      { format: 'AI training or crawling permission signals', reason: 'Discovery artifacts do not set training permissions or change crawl policy.' },
    ],
    limits: [
      'Draft discovery formats may change; their presence does not establish support in every agent.',
      'Downloaded skills describe workflows. Installing a skill does not install, authenticate, or start its product runtime.',
      'Preserve the distinction between released packages and unreleased source builds; read the product guide before connecting.',
      'HTML semantics, robots.txt, sitemap, response headers, and HTTP content negotiation are owned by the site renderer and host configuration.',
    ],
  }
  await write(discoveryPaths.coverage, json(coverage))
  return { skills: skills.length, catalogEntries: entries.length, paths: discoveryPaths }
}

function isCurrentPage(page) {
  return page.agent && ['guide', 'reference'].includes(page.kind) && page.canonicalPath
}

function portableSkill(source, definition, catalog, absolute) {
  const metadata = skillMetadata(source)
  if (metadata.name !== definition.name) throw new Error(`Skill name does not match directory: ${definition.source}`)
  const bySource = new Map(catalog.pages.map((page) => [page.source, page]))
  const byPath = new Map(catalog.pages.flatMap((page) => [page.canonicalPath, ...(page.aliases || []), ...(page.rawAliases || [])].filter(Boolean).map((path) => [path, page])))
  let reason
  let fence
  const publicDoc = (sourcePath) => {
    const page = bySource.get(sourcePath)
    if (!page || !isCurrentPage(page)) {
      reason = `Repository skill references a document outside current automatic context: ${sourcePath}`
      return null
    }
    return absolute(docMarkdownUrl(page.canonicalPath))
  }
  const rewriteUrl = (href) => {
    if (href.startsWith('#')) return absolute(`/.well-known/agent-skills/${definition.name}/SKILL.md${href}`)
    if (!/^https?:\/\//.test(href) && !href.startsWith('/')) {
      const [path, fragment] = href.split('#')
      const target = publicDoc(posix.normalize(posix.join(posix.dirname(definition.source), path)))
      return target ? `${target}${fragment ? `#${fragment}` : ''}` : href
    }
    const parsed = new URL(href, absolute('/'))
    const sourcePath = parsed.hostname === 'github.com' ? parsed.pathname.split('/blob/main/')[1] : null
    if (sourcePath && bySource.has(sourcePath)) return publicDoc(sourcePath) || href
    const sameSite = parsed.origin === new URL(absolute('/')).origin
    const page = sameSite ? byPath.get(parsed.pathname) : null
    const renamed = sameSite && catalog.products.find((product) => product.home && product.home !== '/' && parsed.pathname.replace(/\/$/, '') === `/${product.id}`)
    if (renamed) return `${absolute(renamed.home)}${parsed.search}${parsed.hash}`
    return page ? `${publicDoc(page.source) || href}${parsed.hash}` : parsed.href
  }
  const text = source.split('\n').map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)
    if (marker) {
      if (!fence) fence = marker[1][0]
      else if (marker[1][0] === fence) fence = null
      return line
    }
    if (fence) return line
    if (/\b(?:scripts|references|assets)\/[\w./-]+/.test(line)) reason = 'Repository skill needs sibling files that a single-file discovery entry does not install.'
    return line
      .replace(/`((?:docs|products)\/[\w./-]+\.md)`/g, (match, path) => {
        const url = publicDoc(path)
        return url ? `[${bySource.get(path).title}](${url})` : match
      })
      .replace(/\]\(([^\s)]+)\)/g, (match, href) => `](${rewriteUrl(href)})`)
      .replace(/(?<!["'(])https?:\/\/[^\s<>`]+/g, (url) => rewriteUrl(url))
  }).join('\n')
  return reason ? { reason } : { text }
}

// Public presentation may change before the installed package does. Keep the
// stable skill id, command samples, app names, and stored-note fields intact.
function presentProductSkill(source, product) {
  if (product.id !== 'blink' || product.title !== 'Canvas') return source
  let fence
  const text = source.split('\n').map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null
      return line
    }
    if (fence) return line
    return line.split(/(`+[^`]*`+)/g).map((part) => part.startsWith('`') ? part : part.replace(/\bBlink\b(?![./])/g, 'Canvas')).join('')
  }).join('\n')
  const note = 'Canvas is the product name. The current release and this skill still use `blink`, `@arach/blink`, `Blink.app`, `BLINK_HOME`, and `~/Library/Application Support/Blink/`. The rename does not provide a `canvas` command or migrate existing notes.'
  return text.replace(/(^# Canvas\s*$)/m, `$1\n\n${note}`)
}

function onboardingSkill(definition, product, products, docs, absolute) {
  const description = definition.name === 'voice'
    ? 'Use Lattices voice input and Speech spoken output with the matching local runtimes. Read ownership and capability checks before listening, simulating commands, or controlling playback.'
    : `Use ${product.title} for ${product.description.replace(/\.$/, '').replace(/^./, (letter) => letter.toLowerCase())}. Read current product instructions and check the installed runtime before acting.`
  const related = definition.name === 'voice' ? products.filter((entry) => ['lattices', 'speech'].includes(entry.id)) : [product]
  const guide = docs.find((entry) => entry.url === product.agent?.guide)
  return [
    '---', `name: ${definition.name}`, `description: ${JSON.stringify(description)}`, '---', '',
    `# ${definition.name === 'voice' ? 'Lattices voice input and Speech output' : product.title}`, '',
    product.agent?.boundary || product.description, '',
    ...(definition.name === 'voice' ? [
      'Lattices owns listening, spoken commands, and the voice input runtime. Speech owns spoken output, voices, the queue, and playback in a separate app. Shared `lats voice` commands do not combine their lifecycles.', '',
      'Start with the Speech status check below. Read Lattices voice input documentation before listening or simulating a command. Stopping speech output is different from stopping listening.', '',
    ] : []),
    '## Start here', '',
    ...related.flatMap((entry) => [
      `- [${entry.title} documentation index](${absolute(entry.artifacts.llms)})`,
      `- [${entry.title} public agent instructions](${absolute(entry.artifacts.agents)})`,
    ]),
    ...(guide ? [`- [${guide.title}](${absolute(docMarkdownUrl(guide.url))})`] : []),
    ...(definition.name === 'voice' ? docs.filter((entry) => entry.product === 'lattices' && entry.slug === 'voice').map((entry) => `- [Lattices voice input](${absolute(docMarkdownUrl(entry.url))})`) : []), '',
    ...(product.agent?.firstCheck ? [
      '## First check', '', 'Run this read-only check before making a change:', '',
      '```sh', product.agent.firstCheck, '```', '', product.agent.expect, '',
    ] : []),
    '## Runtime and task boundaries', '',
    'Read the current guide for the installed release. Released packages and unreleased source builds may require different matching clients and apps. Use the documented CLI and authentication; do not bypass a failed private connection with an open network port.', '',
    'Inspect current state and capabilities before acting. Use identifiers returned by the runtime. Check the resulting state before reporting success, and preserve resources owned by other tasks.', '',
    'This onboarding skill only points to public documentation. It does not install or start a runtime, grant permissions, or provide a hosted execution endpoint.', '',
  ].join('\n')
}

function skillMetadata(text) {
  const header = text.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)?.[1]
  if (!header) throw new Error('Skill is missing YAML frontmatter')
  const scalar = (key) => {
    const value = header.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'))?.[1].trim()
    if (!value) return ''
    if (value.startsWith('"')) return JSON.parse(value)
    if (value.startsWith("'")) return value.slice(1, -1).replaceAll("''", "'")
    return value
  }
  const name = scalar('name')
  const description = scalar('description')
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name) || name.length > 64) throw new Error(`Invalid skill name: ${name}`)
  if (!description || description.length > 1024 || ['|', '>'].includes(description[0])) throw new Error(`Invalid single-line skill description: ${name}`)
  return { name, description }
}

function localArtifactPath(distDir, url, origin) {
  const parsed = new URL(url)
  if (parsed.origin !== origin) throw new Error(`Cannot verify nonlocal skill artifact: ${url}`)
  const root = resolve(distDir)
  const path = resolve(root, `.${decodeURIComponent(parsed.pathname)}`)
  if (!path.startsWith(`${root}${sep}`)) throw new Error(`Skill artifact escapes output directory: ${url}`)
  return path
}

async function readOptional(path) {
  try {
    return await readFile(path, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

function digest(contents) { return `sha256:${createHash('sha256').update(contents).digest('hex')}` }
function json(value) { return `${JSON.stringify(value, null, 2)}\n` }
