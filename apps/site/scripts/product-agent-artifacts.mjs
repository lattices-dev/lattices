import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, posix, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseDocArtifact } from './agent-docs.mjs'
import { writeDiscoveryArtifacts } from './discovery-artifacts.mjs'
import { docMarkdownUrl } from '../src/lib/doc-markdown-url.mjs'
import siteConfig from '../src/data/action-start.json' with { type: 'json' }

const defaultSiteDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const currentKinds = new Set(['guide', 'reference'])
const siteOrigin = siteConfig.siteUrl

export async function readDocsCatalog({ siteDir = defaultSiteDir, catalog } = {}) {
  if (catalog) return catalog
  return JSON.parse(await readFile(join(siteDir, 'src/data/docs-catalog.json'), 'utf8'))
}

/** Keep raw sources available, but only put reviewed, current guides in automatic context. */
export async function writeProductAgentArtifacts(options = {}) {
  const siteDir = options.siteDir || defaultSiteDir
  const repoRoot = options.repoRoot || resolve(siteDir, '../..')
  const distDir = options.distDir || join(siteDir, 'dist')
  const catalog = await readDocsCatalog({ ...options, siteDir })
  const generatedAt = new Date().toISOString()
  const artifacts = []
  const artifactPaths = new Map()
  const write = async (url, contents) => {
    if (!url.startsWith('/') || url.split('/').includes('..')) throw new Error(`Invalid artifact path: ${url}`)
    const folded = url.toLowerCase()
    const previous = artifactPaths.get(folded)
    if (previous && previous !== url) throw new Error(`Case-insensitive artifact collision: ${previous} and ${url}`)
    artifactPaths.set(folded, url)
    const target = join(distDir, url)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, contents)
    artifacts.push(url)
  }
  const writeJson = (url, value) => write(url, `${JSON.stringify(value, null, 2)}\n`)
  const entries = await Promise.all(catalog.pages.map(async (page) => {
    const raw = await readFile(join(repoRoot, page.source), 'utf8')
    const parsed = parseDocArtifact(join(repoRoot, page.source), raw, { repoRoot })
    return {
      ...parsed,
      id: page.id,
      product: page.product,
      slug: page.slug,
      kind: page.kind === 'guide' ? 'doc' : page.kind,
      catalogKind: page.kind,
      current: currentKinds.has(page.kind),
      agent: page.agent && currentKinds.has(page.kind) && Boolean(page.canonicalPath),
      title: parsed.frontmatter.title || parsed.headings.find((heading) => heading.depth === 1)?.text || page.title || parsed.title,
      sourcePath: page.source,
      url: page.canonicalPath,
      rawUrl: rawPath(page, catalog),
      markdownUrl: page.canonicalPath ? docMarkdownUrl(page.canonicalPath) : null,
      pageAliases: page.aliases || [],
      rawAliases: [...new Set([...(page.rawAliases || []), rawPath(page)])].filter((path) => path !== rawPath(page, catalog)),
      rawMarkdown: raw,
      // These diagrams enhance the web page; adjacent process tables and prose
      // carry the same facts in plain-text bundles. Keep raw source unchanged.
      content: parsed.content.replace(/^<(?:MacRuntimeDiagram|LinuxRuntimeDiagram)\s*\/>\s*$/gm, '').trim(),
    }
  }))

  // Raw aliases remain Markdown, including historical files and prompt templates.
  const rawOwners = new Map()
  for (const entry of entries) {
    for (const url of new Set([entry.rawUrl, ...entry.rawAliases])) {
      if (rawOwners.has(url) && rawOwners.get(url) !== entry.sourcePath) {
        throw new Error(`Conflicting raw artifact ${url}: ${rawOwners.get(url)} and ${entry.sourcePath}`)
      }
      rawOwners.set(url, entry.sourcePath)
      await write(url, entry.rawMarkdown)
    }
  }

  // Clean page twins are for reading; /markdown/ retains exact source bytes.
  for (const entry of entries.filter((entry) => entry.url)) {
    const body = formatPageMarkdown(entry, catalog)
    for (const route of [entry.url, ...entry.pageAliases]) {
      for (const url of new Set([docMarkdownUrl(route), `${route}/index.md`])) {
        if (rawOwners.has(url)) throw new Error(`Page Markdown conflicts with raw artifact: ${url}`)
        await write(url, body)
      }
    }
  }

  const current = entries.filter((entry) => entry.agent)
  const products = catalog.products.map((product) => ({
    ...product,
    docs: productDocsRoot(product),
    artifacts: productPaths(productDocsRoot(product)),
  }))
  for (const product of products) {
    const docs = current.filter((entry) => entry.product === product.id)
    const manifest = createManifest(docs, { name: product.id, title: product.title, description: product.description }, generatedAt, product.artifacts)
    const index = portableLinks(formatProductIndex(product, docs))
    const bundle = formatBundle(product.title, docs, catalog)
    const instructions = portableLinks(formatProductAgents(product, docs))
    await write(product.artifacts.agents, instructions)
    const publicRoot = product.docs.replace(/\/docs$/, '')
    if (publicRoot !== '/blink') await write(`${publicRoot}/AGENTS.md`, instructions)
    // Existing public entry point must not retain a stale maintainer contract.
    if (product.id === 'blink') await write('/blink/agents.md', instructions)
    await writeJson(product.artifacts.fullManifest, manifest)
    await write(product.artifacts.llms, index)
    await write(product.artifacts.allMarkdown, bundle)
    // Product names can change without renaming installed commands or breaking
    // previously shared documentation and agent-resource URLs.
    const legacyPaths = productPaths(`/${product.id}/docs`)
    if (legacyPaths.llms !== product.artifacts.llms) {
      await write(legacyPaths.agents, instructions)
      await writeJson(legacyPaths.fullManifest, manifest)
      await write(legacyPaths.llms, index)
      await write(legacyPaths.allMarkdown, bundle)
    }
    // Old product entry points remain text and select the same current context.
    for (const root of new Set([publicRoot, `/${product.id}`])) {
      await write(`${root}/llms.txt`, index)
      await write(`${root}/llms-full.txt`, bundle)
    }
    if (product.id === 'action') {
      const legacy = await readOptionalJson(join(repoRoot, 'products/action/docs.json'))
      if (legacy) {
        // Existing consumers read Dewey's `sections` shape at this URL.
        await writeJson('/action/docs.json', {
          ...legacy, generatedBy: 'Lattices product documentation catalog', generatedAt,
          sections: docs.map((entry) => ({
            id: entry.slug, title: entry.title, content: rewriteLinks(entry.content, entry.sourcePath, catalog),
            url: entry.url, rawUrl: entry.rawUrl,
          })),
        })
      }
    }
  }

  const paths = {
    llms: '/llms.txt', agents: '/AGENTS.md', manifest: '/docs.json', fullManifest: '/agent-docs.json',
    agentManifest: '/agent/manifest.json', agentDocs: '/agent/docs.json',
    agentContextMarkdown: '/agent-context.md', agentContextJson: '/agent-context.json',
    agentContextNamespace: '/agent/context.md', allMarkdown: '/docs/all.md',
    fullContext: '/llms-full.txt', markdownBase: '/docs/markdown/', agentRawBase: '/agent/raw/docs/',
    promptsManifest: '/prompts.json', agentPromptsManifest: '/agent/prompts.json', promptsBundle: '/prompts/all.md',
    archive: '/agent/archive.json', discovery: '/agent/discovery.json', skills: '/.well-known/agent-skills/index.json', aiCatalog: '/.well-known/ai-catalog.json',
    bundles: { all: '/agent/bundles/all.md', core: '/agent/bundles/core.md', daemonApi: '/agent/bundles/daemon-api.md', voice: '/agent/bundles/voice.md', install: '/agent/bundles/install.md' },
  }
  const project = { name: 'lattices', title: 'Lattices products', description: `${products.map((product) => product.title).join(', ')} documentation, grouped by product.` }
  const manifest = { ...createManifest(current, project, generatedAt, paths), products }
  const summary = { ...manifest, docs: manifest.docs.map(({ markdown, content, ...entry }) => entry) }
  const index = portableLinks(formatFamilyIndex(products))
  const agents = portableLinks(formatFamilyAgents(products))
  const bundle = formatBundle('Lattices products', current, catalog)
  // The public site needs product-use guidance, not the repository's maintainer
  // contract. This intentionally replaces the legacy writer's root AGENTS copy.
  await write(paths.agents, agents)
  for (const path of ['/agent-docs.json', '/agent/docs.json']) await writeJson(path, manifest)
  for (const path of ['/docs.json', '/agent/manifest.json', '/docs/manifest.json', '/docs/index.json']) await writeJson(path, summary)
  await writeJson('/agent-context.json', { ...manifest, rootContext: { agents, agentsUrl: paths.agents, llms: index }, prompts: [] })
  await writeJson('/agent/archive.json', {
    version: 1, generatedAt,
    description: 'Explicit references outside the default agent context. Check kind and current before treating a document as shipped behavior.',
    docs: entries.filter((entry) => !entry.agent).map((entry) => manifestEntry(entry, false)),
  })
  await write('/llms.txt', index)
  for (const path of ['/llms-full.txt', '/docs/all.md', '/agent/bundles/all.md', '/agent-context.md', '/agent/context.md']) await write(path, bundle)
  const core = current.filter((entry) => entry.product === 'lattices')
  const selected = (slugs) => core.filter((entry) => slugs.includes(entry.slug))
  await write(paths.bundles.core, formatBundle('Lattices core', selected(['overview', 'quickstart', 'concepts', 'config', 'agents']), catalog))
  await write(paths.bundles.daemonApi, formatBundle('Lattices API', selected(['api', 'agents', 'tiling-reference', 'layers', 'ocr']), catalog))
  await write(paths.bundles.voice, formatBundle('Voice commands and Voice playback', [...selected(['voice']), ...current.filter((entry) => entry.product === 'speech')], catalog))
  await write(paths.bundles.install, formatBundle('Lattices installation', selected(['quickstart', 'install-linux']), catalog))

  await writeDiscoveryArtifacts({ repoRoot, distDir, catalog, write, products, currentEntries: current })
  // Required for hidden discovery paths when publishing without Jekyll.
  await write('/.nojekyll', '')

  return { products: products.length, currentDocs: current.length, archivedDocs: entries.length - current.length, artifacts }
}

function productDocsRoot(product) {
  return product?.docsHome || product?.docs || `${product?.home && product.home !== '/' ? product.home.replace(/\/$/, '') : `/${product?.id}`}/docs`
}

function rawPath(page, catalog) {
  const prefix = currentKinds.has(page.kind) ? '' : 'archive/'
  const root = catalog ? productDocsRoot(catalog.products.find((product) => product.id === page.product)) : `/${page.product}/docs`
  return `${root}/markdown/${prefix}${page.slug}.md`
}

function productPaths(docs) {
  return {
    llms: `${docs}/llms.txt`,
    agents: `${docs}/AGENTS.md`,
    fullManifest: `${docs}/agent-docs.json`,
    allMarkdown: `${docs}/llms-full.txt`,
    markdownBase: `${docs}/markdown/`,
  }
}

async function readOptionalJson(path) {
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}

function createManifest(docs, project, generatedAt, artifacts) {
  return {
    version: 1, project, generatedAt, artifacts,
    recommendedReadOrder: docs.map((entry) => entry.id),
    docs: docs.map((entry) => manifestEntry(entry, true)),
    prompts: [],
  }
}

function manifestEntry(entry, includeContent) {
  const result = {
    id: entry.id, slug: entry.slug, product: entry.product, kind: entry.kind, catalogKind: entry.catalogKind,
    current: entry.current, title: entry.title, description: entry.description, order: entry.order,
    sourcePath: entry.sourcePath, url: entry.url, rawUrl: entry.rawUrl, markdownUrl: entry.markdownUrl,
    headings: entry.headings, tokensEstimate: entry.tokensEstimate, frontmatter: entry.frontmatter,
  }
  if (includeContent) Object.assign(result, { markdown: entry.rawMarkdown, content: entry.content })
  return result
}

function formatProductIndex(product, docs) {
  return [
    `# ${product.title}`, '', `> ${product.description}`, '',
    `Documentation: ${siteOrigin}${product.docs}`, '',
    ...formatProductNaming(product),
    ...formatAgentStart(product, docs),
    '## Current documentation', '',
    ...docs.map((entry) => `- [${entry.title}](${entry.markdownUrl || entry.rawUrl})${entry.description ? `: ${entry.description}` : ''}`), '',
    '## Retrieval', '',
    `- [Public agent instructions](${product.artifacts.agents})`,
    `- [Full context](${product.artifacts.allMarkdown})`,
    `- [Structured documentation](${product.artifacts.fullManifest})`,
    '- [All products](/llms.txt)', '',
  ].join('\n')
}

// A bounded first step per product: what it owns, where its agent guide is,
// and one read-only check that proves the runtime answers.
function formatAgentStart(product, docs) {
  const agent = product.agent
  if (!agent) return []
  const guide = docs.find((entry) => entry.url === agent.guide)
  return [
    '**First check**', '',
    agent.boundary, '',
    ...(guide ? [`Agent guide: [${guide.title}](${guide.markdownUrl || guide.rawUrl}).`, ''] : []),
    `First check (read-only): \`${agent.firstCheck}\``,
    `Expect: ${agent.expect}`, '',
  ]
}

function formatFamilyIndex(products) {
  return [
    '# Lattices products', '',
    '> Choose the product that owns the task. Each product has its own documentation and runtime boundary.', '',
    '## Products', '',
    ...products.map((product) => `- [${product.title}](${product.artifacts.llms}): ${product.description} Human docs: ${siteOrigin}${product.docs}.${product.agent ? ` First check: \`${product.agent.firstCheck}\`.` : ''}`), '',
    '## Current context', '',
    '- [Public agent instructions](/AGENTS.md)',
    '- [Structured documentation](/docs.json)',
    '- [Documentation with Markdown](/agent-docs.json)',
    '- [Full current context](/llms-full.txt)', '',
    '## Discovery', '',
    '- [Discovery coverage and format status](/agent/discovery.json)',
    '- [Downloadable skills](/.well-known/agent-skills/index.json): draft skill discovery format.',
    '- [AI artifact catalog](/.well-known/ai-catalog.json): draft catalog of documentation and skills.', '',
    '## Optional', '',
    '- [Archive and other references](/agent/archive.json): proposals, history, prompts, and guides excluded from default context. These are not all current product instructions.',
    '- [Prompt registry](/prompts.json): retrieve a template only when the task needs it.', '',
  ].join('\n')
}

function formatFamilyAgents(products) {
  return [
    '# Lattices products: agent instructions', '',
    'Choose the product that owns the task, then retrieve its current documentation before using a command or API.', '',
    '## Product ownership', '',
    '| Product | Owns | Documentation | Agent instructions | Current index |',
    '|---------|------|---------------|--------------------|---------------|',
    ...products.map((product) => `| ${product.title} | ${product.description} | [Docs](${product.docs}) | [Instructions](${product.artifacts.agents}) | [Index](${product.artifacts.llms}) |`), '',
    '## Retrieval order', '',
    '1. Read the owning product\'s index linked above.',
    '2. Retrieve the relevant raw Markdown links from that index. Use the product\'s structured manifest when you need document metadata or the complete current bundle when the task spans several guides.',
    '3. Check the documented destination of each command. A shared CLI entry point does not mean that products share a process, endpoint, or lifecycle.', '',
    ...formatBuildAndArchiveGuidance(),
    '## Family references', '',
    '- [Product indexes](/llms.txt)',
    '- [Current documentation manifest](/agent-docs.json)',
    '- [Explicit archive and other references](/agent/archive.json)', '',
  ].join('\n')
}

function formatProductAgents(product, docs) {
  const first = docs.find((entry) => entry.slug === 'overview') || docs[0]
  return [
    `# ${product.title}: agent instructions`, '',
    product.description, '',
    `These instructions apply to ${product.title}. Use the [family ownership map](/AGENTS.md) when a task belongs to another product.`, '',
    ...formatProductNaming(product),
    '## Retrieve documentation first', '',
    `1. Read the [current ${product.title} index](${product.artifacts.llms}).`,
    `2. Retrieve the relevant raw Markdown links from that index.${first ? ` Start with the [overview](${first.rawUrl}) when the product is unfamiliar.` : ''}`,
    `3. Check the documented command destination and required build before acting. Follow cross-product links when an operation is performed by another product.`, '',
    ...formatBuildAndArchiveGuidance(),
    '## Product references', '',
    `- [Human documentation](${product.docs})`,
    `- [Structured documentation](${product.artifacts.fullManifest})`,
    `- [Complete current bundle](${product.artifacts.allMarkdown})`, '',
  ].join('\n')
}

function formatProductNaming(product) {
  return product.id === 'blink' && product.title === 'Canvas' ? [
    'Canvas 2.3.0 ships `Canvas.app` and the `canvas` CLI. `blink` and `Blink.app` remain compatibility names. The npm package remains `@arach/blink`, and existing notes stay in `~/Library/Application Support/Blink/`. A nonempty `CANVAS_HOME` takes precedence over a nonempty `BLINK_HOME`; no data move is required.', '',
  ] : []
}

function formatBuildAndArchiveGuidance() {
  return [
    '## Match the installed build', '',
    'Current documentation can describe released packages and unreleased source builds. Confirm which version and build you are using, and follow the page\'s release or source-build qualifications. An unreleased source change is not evidence that an installed release supports it.', '',
    'Use the documented CLI and authentication for that build. Do not assume a fixed port, socket path, missing authentication, or fallback transport. Check the relevant setup and API pages before connecting.', '',
    '## Current guides and archives', '',
    'The current product indexes and bundles select guides and references from the documentation catalog. Proposals, historical reports, and prompt templates are available through the explicit archive; they are not instructions for shipped behavior. Retrieve them only when the task calls for that reference.', '',
  ]
}

function formatBundle(title, docs, catalog) {
  return [
    `# ${title} documentation`, '',
    'Current guides and references selected by the product documentation catalog.', '',
    '## Index', '',
    '| Product | Title | Raw Markdown |', '|---------|-------|--------------|',
    ...docs.map((entry) => `| ${catalog.products.find((product) => product.id === entry.product)?.title || entry.product} | ${entry.title.replaceAll('|', '\\|')} | ${entry.rawUrl} |`), '',
    ...docs.flatMap((entry) => [
      '---', '', `<!-- product: ${entry.product}; source: ${entry.sourcePath} -->`, '',
      `Canonical page: ${entry.url}`, '',
      entry.headings.some((heading) => heading.depth === 1) ? rewriteLinks(entry.content, entry.sourcePath, catalog) : `# ${entry.title}\n\n${rewriteLinks(entry.content, entry.sourcePath, catalog)}`, '',
    ]),
  ].join('\n')
}

// Bundles move documents out of their source directory. Resolve prose links there,
// while raw files and code samples retain their original bytes.
function rewriteLinks(markdown, source, catalog) {
  const link = (href) => {
    if (href.startsWith('https://lattices.dev/')) {
      const url = new URL(href)
      return link(url.pathname + url.search + url.hash)
    }
    if (!href || /^(#|[a-z][a-z\d+.-]*:|\/\/)/i.test(href)) return href
    const [, path, suffix] = href.match(/^([^?#]*)(.*)$/)
    if (path.startsWith('/')) {
      const entry = catalog.pages.find((page) => page.canonicalPath === path || page.aliases.includes(path))
      return (entry?.canonicalPath || path) + suffix
    }
    const target = posix.normalize(posix.join(posix.dirname(source), path))
    const entry = catalog.pages.find((page) => page.source === target)
    if (entry) return (entry.canonicalPath || rawPath(entry, catalog)) + suffix
    return `https://github.com/lattices-dev/lattices/blob/main/${target}${suffix}`
  }
  let fence = null
  return markdown.split('\n').map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null
      return line
    }
    if (fence) return line
    return line
      .replace(/(!?\[[^\]]*\]\()([^\s)]+)([^)]*\))/g, (_, before, href, after) => `${before}${link(href)}${after}`)
      .replace(/^(\s*\[[^\]]+\]:\s*)(\S+)/, (_, before, href) => `${before}${link(href)}`)
      .replace(/\b(href|src)="([^"\s]+)"/g, (_, attr, href) => `${attr}="${link(href)}"`)
  }).join('\n')
}

// Portable links still resolve when an agent copies the document out of its URL.
function portableLinks(markdown) {
  let fence = null
  return markdown.split('\n').map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null
      return line
    }
    return fence ? line : line.replace(/(\]\()\/(?!\/)/g, `$1${siteOrigin}/`)
  }).join('\n')
}

function formatPageMarkdown(entry, catalog) {
  const title = entry.headings.some((heading) => heading.depth === 1) ? '' : `# ${entry.title}\n\n`
  return portableLinks(`${title}Canonical page: ${siteOrigin}${entry.url}\n\n${rewriteLinks(entry.content, entry.sourcePath, catalog)}\n`)
}
