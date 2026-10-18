import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { basename, dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const defaultSiteDir = resolve(scriptDir, '..')
const defaultRepoRoot = resolve(defaultSiteDir, '..', '..')
const defaultDocsDir = join(defaultRepoRoot, 'docs')
const defaultDistDir = join(defaultSiteDir, 'dist')

const kindRank = {
  doc: 0,
  reference: 1,
  proposal: 2,
  prompt: 3,
}

const primaryDocReadOrder = [
  'overview',
  'quickstart',
  'install-linux',
  'concepts',
  'config',
  'app',
  'embedded-sdk',
  'layers',
  'api',
  'agent/cua-implementation',
  'agent/dewey-agent-architecture',
  'agents',
  'voice',
  'ocr',
]
export async function readMarkdownDocs(options = {}) {
  const resolved = resolveOptions(options)
  const files = await walkMarkdownFiles(resolved.docsDir)
  const docs = await Promise.all(files.map((filePath) => readMarkdownDoc(filePath, resolved)))
  return docs.sort(compareDocs)
}

export async function collectMarkdownArtifacts(repoRootOrOptions = {}) {
  const options = typeof repoRootOrOptions === 'string'
    ? { repoRoot: repoRootOrOptions }
    : repoRootOrOptions
  return readMarkdownDocs(options)
}

export async function readPromptDocs(options = {}) {
  const docs = await readMarkdownDocs(options)
  return docs.filter((doc) => doc.kind === 'prompt')
}

export async function getMarkdownDoc(slug, options = {}) {
  const normalized = normalizeSlug(slug)
  const docs = await readMarkdownDocs(options)
  return docs.find((doc) => doc.slug === normalized || doc.sourcePath === normalized) || null
}

export async function getPrompt(promptId, options = {}) {
  const normalized = normalizeSlug(promptId).replace(/^prompts\//, '')
  const prompts = await readPromptDocs(options)
  return prompts.find((prompt) => prompt.promptId === normalized || prompt.slug === `prompts/${normalized}`) || null
}

export async function readAgentContextFiles(options = {}) {
  const { repoRoot } = resolveOptions(options)

  return {
    agents: await readOptional(join(repoRoot, 'AGENTS.md')),
    llms: await readOptional(join(repoRoot, 'llms.txt')),
    packageJson: await readOptionalJson(join(repoRoot, 'package.json')),
  }
}

export async function buildAgentManifest(options = {}) {
  const resolved = resolveOptions(options)
  const docs = options.docs || await readMarkdownDocs(resolved)
  const context = options.context || await readAgentContextFiles(resolved)
  return createManifest(docs, context, {
    includeContent: Boolean(options.includeContent),
  })
}

export async function buildPromptManifest(options = {}) {
  const docs = options.docs || await readMarkdownDocs(options)
  const prompts = docs.filter((doc) => doc.kind === 'prompt')

  return {
    version: 1,
    project: 'lattices',
    generatedAt: new Date().toISOString(),
    prompts: prompts.map((prompt) => toPromptEntry(prompt, {
      includeContent: options.includeContent !== false,
    })),
  }
}

export async function buildPromptRegistry(options = {}) {
  return buildPromptManifest(options)
}

export async function buildAgentContext(options = {}) {
  const resolved = resolveOptions(options)
  const docs = options.docs || await readMarkdownDocs(resolved)
  const context = options.context || await readAgentContextFiles(resolved)
  return formatAgentContextMarkdown(docs, context)
}

export async function writeAgentArtifacts(options = {}) {
  const resolved = resolveOptions(options)
  const docs = await readMarkdownDocs(resolved)
  const prompts = docs.filter((doc) => doc.kind === 'prompt')
  const context = await readAgentContextFiles(resolved)
  const manifest = createManifest(docs, context, { includeContent: false })
  const fullManifest = createManifest(docs, context, { includeContent: true })
  const promptManifest = {
    version: 1,
    project: 'lattices',
    generatedAt: manifest.generatedAt,
    prompts: prompts.map((prompt) => toPromptEntry(prompt, { includeContent: true })),
  }
  const agentContextMarkdown = formatAgentContextMarkdown(docs, context)
  const agentContextJson = {
    version: 1,
    project: manifest.project,
    generatedAt: manifest.generatedAt,
    artifacts: manifest.artifacts,
    rootContext: {
      agents: context.agents || '',
      llms: context.llms || '',
    },
    docs: fullManifest.docs,
    prompts: promptManifest.prompts,
  }

  const artifacts = []
  const writeArtifact = async (artifactPath, value) => {
    const filePath = join(resolved.distDir, artifactPath)
    await mkdir(dirname(filePath), { recursive: true })
    await writeFile(filePath, ensureTrailingNewline(value))
    artifacts.push(`/${normalizePath(artifactPath)}`)
  }
  const writeJsonArtifact = async (artifactPath, value) => {
    await writeArtifact(artifactPath, `${JSON.stringify(value, null, 2)}\n`)
  }

  await writeJsonArtifact('docs.json', manifest)
  await writeJsonArtifact('agent-docs.json', fullManifest)
  await writeJsonArtifact('agent-context.json', agentContextJson)
  await writeJsonArtifact('agent/manifest.json', manifest)
  await writeJsonArtifact('agent/docs.json', fullManifest)
  await writeJsonArtifact('agent/prompts.json', promptManifest)
  await writeJsonArtifact('docs/manifest.json', manifest)
  await writeJsonArtifact('docs/index.json', manifest)
  await writeJsonArtifact('docs/prompts.json', promptManifest)
  await writeJsonArtifact('prompts.json', promptManifest)

  await writeArtifact('agent-context.md', agentContextMarkdown)
  await writeArtifact('agent/context.md', agentContextMarkdown)
  await writeArtifact('agent/bundles/all.md', formatDocsBundle(docs))
  await writeArtifact('agent/bundles/core.md', buildContextBundle(docs, ['overview', 'quickstart', 'concepts', 'config', 'agents']))
  await writeArtifact('agent/bundles/daemon-api.md', buildContextBundle(docs, ['api', 'agent/cua-implementation', 'agents', 'tiling-reference', 'layers', 'ocr']))
  await writeArtifact('agent/bundles/voice.md', buildContextBundle(docs, [
    'voice',
    'voice-command-protocol',
    'voice-error-model',
    'prompts/hands-off-system',
    'prompts/hands-off-turn',
    'prompts/voice-advisor',
    'prompts/voice-fallback',
  ]))
  await writeArtifact('agent/bundles/install.md', buildContextBundle(docs, ['reference/install-agent']))
  await writeArtifact('docs/all.md', formatDocsBundle(docs))
  await writeArtifact('prompts/all.md', formatPromptsBundle(prompts))
  await writeArtifact('docs/prompts/all.md', formatPromptsBundle(prompts))

  if (context.agents) await writeArtifact('AGENTS.md', context.agents)
  if (context.llms) await writeArtifact('llms.txt', formatLlmsTxt(manifest, context.llms))

  for (const doc of docs) {
    await writeArtifact(`docs/markdown/${doc.slug}.md`, doc.rawMarkdown)
    await writeArtifact(`agent/raw/docs/${doc.slug}.md`, doc.rawMarkdown)
  }

  for (const prompt of prompts) {
    await writeArtifact(`prompts/${prompt.promptId}.md`, prompt.rawMarkdown)
    await writeArtifact(`docs/prompts/${prompt.promptId}.md`, prompt.rawMarkdown)
  }

  return {
    docs: docs.length,
    prompts: prompts.length,
    artifacts,
  }
}

export function formatDocsBundle(docs) {
  const lines = [
    '# Lattices Documentation Bundle',
    '',
    'Generated from the repository markdown docs for agent consumption.',
    '',
    '## Index',
    '',
    '| Kind | Title | Source | Raw markdown |',
    '|------|-------|--------|--------------|',
    ...docs.map((doc) => `| ${doc.kind} | ${escapeTable(doc.title)} | \`${doc.sourcePath}\` | ${doc.rawUrl} |`),
    '',
  ]

  for (const doc of docs) {
    lines.push('---', '', `<!-- source: ${doc.sourcePath} -->`, '')
    lines.push(normalizeMarkdownTitle(doc), '')
  }

  return lines.join('\n')
}

export function formatPromptsBundle(prompts) {
  const lines = [
    '# Lattices Prompt Bundle',
    '',
    'System prompts, turn templates, and fallback prompts used by Lattices agent surfaces.',
    '',
    '| Prompt | Source | Raw markdown |',
    '|--------|--------|--------------|',
    ...prompts.map((prompt) => `| ${escapeTable(prompt.title)} | \`${prompt.sourcePath}\` | ${prompt.promptUrl} |`),
    '',
  ]

  for (const prompt of prompts) {
    lines.push('---', '', `<!-- source: ${prompt.sourcePath} -->`, '')
    lines.push(normalizeMarkdownTitle(prompt), '')
  }

  return lines.join('\n')
}

export function buildContextBundle(docs, slugs) {
  const bySlug = new Map(docs.map((doc) => [doc.slug, doc]))
  const selectedDocs = slugs
    .map((slug) => bySlug.get(slug))
    .filter(Boolean)

  const lines = [
    '# Lattices Agent Bundle',
    '',
    '| Title | Source | Raw markdown |',
    '|-------|--------|--------------|',
    ...selectedDocs.map((doc) => `| ${escapeTable(doc.title)} | \`${doc.sourcePath}\` | ${doc.rawUrl} |`),
    '',
  ]

  for (const doc of selectedDocs) {
    lines.push('---', '', `<!-- source: ${doc.sourcePath} -->`, '')
    lines.push(normalizeMarkdownTitle(doc), '')
  }

  return lines.join('\n')
}

function resolveOptions(options = {}) {
  const siteDir = options.siteDir ? resolve(options.siteDir) : defaultSiteDir
  const repoRoot = options.repoRoot ? resolve(options.repoRoot) : defaultRepoRoot

  return {
    siteDir,
    repoRoot,
    docsDir: options.docsDir ? resolve(options.docsDir) : join(repoRoot, 'docs'),
    distDir: options.distDir ? resolve(options.distDir) : join(siteDir, 'dist'),
  }
}

async function readMarkdownDoc(filePath, options) {
  const raw = (await readFile(filePath, 'utf8')).replace(/\r\n/g, '\n').trim()
  return parseDocArtifact(filePath, raw, options)
}

export function parseDocArtifact(filePath, raw, options = {}) {
  const resolved = resolveOptions(options)
  const absoluteFilePath = resolve(filePath)
  const normalizedRaw = raw.replace(/\r\n/g, '\n').trim()
  const { data, content } = splitFrontmatter(normalizedRaw)
  const slug = stripMarkdownExtension(normalizePath(relative(resolved.docsDir, absoluteFilePath)))
  const sourcePath = normalizePath(relative(resolved.repoRoot, absoluteFilePath))
  const headings = extractHeadings(content)
  const title = data.title || headings.find((heading) => heading.depth === 1)?.text || titleFromSlug(slug)
  const description = data.description || extractDescription(content)
  const kind = kindFromSlug(slug)
  const promptId = kind === 'prompt' ? slug.replace(/^prompts\//, '') : undefined

  return {
    id: slug,
    slug,
    kind,
    promptId,
    title,
    description,
    order: typeof data.order === 'number' ? data.order : null,
    sourcePath,
    url: urlForDoc(slug, kind),
    rawUrl: `/docs/markdown/${slug}.md`,
    promptUrl: promptId ? `/prompts/${promptId}.md` : null,
    frontmatter: data,
    headings,
    tokensEstimate: estimateTokens(content),
    rawMarkdown: normalizedRaw,
    content,
  }
}

async function walkMarkdownFiles(directory) {
  let entries = []

  try {
    entries = await readdir(directory, { withFileTypes: true })
  } catch {
    return []
  }

  const nested = await Promise.all(entries.map(async (entry) => {
    const entryPath = join(directory, entry.name)
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.')) return []
      return walkMarkdownFiles(entryPath)
    }
    if (entry.isFile() && ['.md', '.mdx'].includes(extname(entry.name))) {
      return [entryPath]
    }
    return []
  }))

  return nested.flat().sort()
}

function createManifest(docs, context, options) {
  const prompts = docs.filter((doc) => doc.kind === 'prompt')
  const packageJson = context.packageJson || {}

  return {
    version: 1,
    project: {
      name: packageJson.name || 'lattices',
      version: packageJson.version || null,
      description: packageJson.description || 'macOS developer workspace manager',
      repository: packageJson.repository?.url || null,
    },
    generatedAt: new Date().toISOString(),
    artifacts: {
      llms: '/llms.txt',
      agents: '/AGENTS.md',
      manifest: '/docs.json',
      fullManifest: '/agent-docs.json',
      agentManifest: '/agent/manifest.json',
      agentDocs: '/agent/docs.json',
      agentContextMarkdown: '/agent-context.md',
      agentContextJson: '/agent-context.json',
      agentContextNamespace: '/agent/context.md',
      allMarkdown: '/docs/all.md',
      markdownBase: '/docs/markdown/',
      agentRawBase: '/agent/raw/docs/',
      promptsManifest: '/prompts.json',
      agentPromptsManifest: '/agent/prompts.json',
      promptsBundle: '/prompts/all.md',
      bundles: {
        all: '/agent/bundles/all.md',
        core: '/agent/bundles/core.md',
        daemonApi: '/agent/bundles/daemon-api.md',
        voice: '/agent/bundles/voice.md',
        install: '/agent/bundles/install.md',
      },
    },
    recommendedReadOrder: primaryDocReadOrder.filter((slug) => docs.some((doc) => doc.slug === slug)),
    docs: docs.map((doc) => toManifestEntry(doc, options)),
    prompts: prompts.map((prompt) => toPromptEntry(prompt, options)),
  }
}

function toManifestEntry(doc, options = {}) {
  const entry = {
    id: doc.id,
    slug: doc.slug,
    kind: doc.kind,
    title: doc.title,
    description: doc.description,
    order: doc.order,
    sourcePath: doc.sourcePath,
    url: doc.url,
    rawUrl: doc.rawUrl,
    headings: doc.headings,
    tokensEstimate: doc.tokensEstimate,
    frontmatter: doc.frontmatter,
  }

  if (doc.promptId) {
    entry.promptId = doc.promptId
    entry.promptUrl = doc.promptUrl
  }

  if (options.includeContent) {
    entry.markdown = doc.rawMarkdown
    entry.content = doc.content
  }

  return entry
}

function toPromptEntry(prompt, options = {}) {
  const entry = {
    id: prompt.promptId,
    slug: prompt.slug,
    title: prompt.title,
    description: prompt.description,
    sourcePath: prompt.sourcePath,
    promptUrl: prompt.promptUrl,
    rawUrl: prompt.rawUrl,
    headings: prompt.headings,
    tokensEstimate: prompt.tokensEstimate,
    frontmatter: prompt.frontmatter,
  }

  if (options.includeContent) {
    entry.markdown = prompt.rawMarkdown
    entry.content = prompt.content
  }

  return entry
}

function formatAgentContextMarkdown(docs, context) {
  const manifest = createManifest(docs, context, { includeContent: false })
  const prompts = docs.filter((doc) => doc.kind === 'prompt')
  const packageJson = context.packageJson || {}
  const lines = [
    '# Lattices Agent Context',
    '',
    packageJson.description || 'macOS developer workspace manager.',
    '',
    '## Fast Retrieval',
    '',
    '| Need | Artifact |',
    '|------|----------|',
    '| LLM summary | `/llms.txt` |',
    '| Agent operating rules | `/AGENTS.md` |',
    '| Structured manifest | `/docs.json` |',
    '| Full manifest with markdown | `/agent-docs.json` |',
    '| Raw markdown bundle | `/docs/all.md` |',
    '| Prompt manifest | `/prompts.json` |',
    '| Prompt bundle | `/prompts/all.md` |',
    '',
    '## Recommended Read Order',
    '',
    ...manifest.recommendedReadOrder.map((slug) => `- ${slug}: /docs/markdown/${slug}.md`),
    '',
  ]

  if (context.agents) {
    lines.push('## Repository Agent Rules', '', context.agents.trim(), '')
  }

  lines.push('## Documentation Index', '')
  lines.push('| Kind | Title | Source | Raw markdown |')
  lines.push('|------|-------|--------|--------------|')
  for (const doc of docs) {
    lines.push(`| ${doc.kind} | ${escapeTable(doc.title)} | \`${doc.sourcePath}\` | ${doc.rawUrl} |`)
  }
  lines.push('')

  if (prompts.length) {
    lines.push('## Prompt Index', '')
    lines.push('| Prompt | Source | Raw markdown |')
    lines.push('|--------|--------|--------------|')
    for (const prompt of prompts) {
      lines.push(`| ${escapeTable(prompt.title)} | \`${prompt.sourcePath}\` | ${prompt.promptUrl} |`)
    }
    lines.push('')
  }

  lines.push('## Markdown Docs', '')
  for (const doc of docs) {
    if (doc.kind === 'prompt') continue
    lines.push('---', '', `<!-- source: ${doc.sourcePath} -->`, '')
    lines.push(normalizeMarkdownTitle(doc), '')
  }

  if (prompts.length) {
    lines.push('## Prompts', '')
    for (const prompt of prompts) {
      lines.push('---', '', `<!-- source: ${prompt.sourcePath} -->`, '')
      lines.push(normalizeMarkdownTitle(prompt), '')
    }
  }

  return lines.join('\n')
}

function formatLlmsTxt(manifest, existingLlms) {
  if (/^## Agent Retrieval Artifacts$/m.test(existingLlms)) {
    return existingLlms.trim()
  }

  const lines = [
    existingLlms.trim(),
    '',
    '## Agent Retrieval Artifacts',
    '',
    '- Structured manifest: /docs.json',
    '- Full manifest with markdown: /agent-docs.json',
    '- Agent context bundle: /agent-context.md',
    '- Agent context JSON: /agent-context.json',
    '- Raw markdown bundle: /docs/all.md',
    '- Raw markdown base: /docs/markdown/',
    '- Prompt manifest: /prompts.json',
    '- Prompt bundle: /prompts/all.md',
    '',
    '## Raw Markdown Shortcuts',
    '',
    ...manifest.recommendedReadOrder.map((slug) => `- ${slug}: /docs/markdown/${slug}.md`),
  ]

  return lines.join('\n')
}

function splitFrontmatter(raw) {
  const normalized = raw.replace(/\r\n/g, '\n')
  if (!normalized.startsWith('---\n')) return { data: {}, content: normalized.trim() }

  const end = normalized.indexOf('\n---', 4)
  if (end === -1) return { data: {}, content: normalized.trim() }

  return {
    data: parseFrontmatter(normalized.slice(4, end)),
    content: normalized.slice(end + 4).trim(),
  }
}

function parseFrontmatter(block) {
  const data = {}
  for (const line of block.split('\n')) {
    const match = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/)
    if (!match) continue
    data[match[1]] = parseValue(match[2])
  }
  return data
}

function parseValue(raw) {
  const value = raw.trim()
  if (value === 'true') return true
  if (value === 'false') return false
  if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value)
  if (value.startsWith('[') && value.endsWith(']')) {
    return value.slice(1, -1).split(',').map((part) => stripQuotes(part.trim())).filter(Boolean)
  }
  return stripQuotes(value)
}

function stripQuotes(value) {
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1)
  }
  return value
}

function extractHeadings(content) {
  const headings = []
  const pattern = /^(#{1,6})\s+(.+)$/gm
  let match = pattern.exec(content)

  while (match) {
    headings.push({
      depth: match[1].length,
      text: cleanInlineMarkdown(match[2]),
      anchor: slugify(cleanInlineMarkdown(match[2])),
    })
    match = pattern.exec(content)
  }

  return headings
}

function extractDescription(content) {
  const blockquote = content.match(/^>\s+(.+)$/m)
  if (blockquote) return cleanInlineMarkdown(blockquote[1])

  const paragraph = content
    .split(/\n{2,}/)
    .map((part) => part.trim())
    .find((part) => part && !part.startsWith('#') && !part.startsWith('```') && !part.startsWith('|'))

  if (!paragraph) return ''
  return cleanInlineMarkdown(paragraph).slice(0, 220)
}

function normalizeMarkdownTitle(doc) {
  const hasH1 = /^#\s+/m.test(doc.content)
  if (hasH1) return doc.content.trim()
  return `# ${doc.title}\n\n${doc.content.trim()}`
}

function compareDocs(left, right) {
  const rank = (kindRank[left.kind] ?? 99) - (kindRank[right.kind] ?? 99)
  if (rank !== 0) return rank

  const order = (left.order ?? 9999) - (right.order ?? 9999)
  if (order !== 0) return order

  return left.slug.localeCompare(right.slug)
}

function kindFromSlug(slug) {
  if (slug.startsWith('prompts/')) return 'prompt'
  if (slug.startsWith('proposals/')) return 'proposal'
  if (slug.startsWith('reference/')) return 'reference'
  return 'doc'
}

function urlForDoc(slug, kind) {
  if (kind === 'doc' && !slug.includes('/')) return `/docs/${slug}`
  return `/docs/markdown/${slug}.md`
}

function estimateTokens(content) {
  return Math.ceil(content.split(/\s+/).filter(Boolean).length * 1.33)
}

function titleFromSlug(slug) {
  return basename(slug)
    .split('-')
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function stripMarkdownExtension(path) {
  return path.replace(/\.(md|mdx)$/, '')
}

function normalizeSlug(slug) {
  return stripMarkdownExtension(String(slug).replace(/^\/+/, '').replace(/^docs\//, ''))
}

function normalizePath(path) {
  return path.replace(/\\/g, '/')
}

function cleanInlineMarkdown(value) {
  return value
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_~#]/g, '')
    .trim()
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function escapeTable(value) {
  return String(value).replace(/\|/g, '\\|')
}

function ensureTrailingNewline(value) {
  const text = String(value)
  return text.endsWith('\n') ? text : `${text}\n`
}

async function readOptional(filePath) {
  try {
    return await readFile(filePath, 'utf8')
  } catch {
    return ''
  }
}

async function readOptionalJson(filePath) {
  const raw = await readOptional(filePath)
  if (!raw) return null

  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}

function isDirectRun() {
  if (!process.argv[1]) return false
  return import.meta.url === pathToFileURL(process.argv[1]).href
}

if (isDirectRun()) {
  writeAgentArtifacts({ siteDir: defaultSiteDir, repoRoot: defaultRepoRoot, docsDir: defaultDocsDir, distDir: defaultDistDir })
    .then((result) => {
      if (!process.argv.includes('--quiet')) {
        console.log(`Wrote ${result.artifacts.length} agent docs artifacts for ${result.docs} docs and ${result.prompts} prompts.`)
      }
    })
    .catch((error) => {
      console.error(error)
      process.exitCode = 1
    })
}
