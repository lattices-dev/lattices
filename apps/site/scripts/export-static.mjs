import actionDownload from '../src/action-download.json' with { type: 'json' }
import { copyFile, mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import { marked } from 'marked'
import { createElement } from 'react'
import { renderToString } from 'react-dom/server'
import { createJavaScriptRegexEngine } from 'shiki/engine/javascript'
import { createHighlighterCore } from 'shiki/core'
import bash from 'shiki/langs/sh.mjs'
import javascript from 'shiki/langs/js.mjs'
import json from 'shiki/langs/json.mjs'
import markdown from 'shiki/langs/md.mjs'
import mermaid from 'shiki/langs/mermaid.mjs'
import swift from 'shiki/langs/swift.mjs'
import typescript from 'shiki/langs/ts.mjs'
import { writeAgentArtifacts } from './agent-docs.mjs'
import { copyActionReferences } from './action-docs.mjs'
import { renderMdxComponent } from './render-mdx.mjs'
import { getLastUpdatedBatch, repoInfo } from './git-meta.mjs'
import { stripMdxImports } from '../src/lib/markdown.ts'
import LandingPage from '../src/components/LandingPage.tsx'
import ConceptExperimentPage from '../src/components/ConceptExperimentPage.tsx'
import ActionPage from '../src/components/ActionPage.tsx'
import BlinkPage from '../src/components/BlinkPage.tsx'
import SpeechPage from '../src/components/SpeechPage.tsx'
import LearnPage from '../src/components/LearnPage.tsx'
import { learningRoutes } from '../src/lib/learning.ts'
import ProductsPage from '../src/components/ProductsPage.tsx'
import FamilyPage from '../src/components/FamilyPage.tsx'
import BrandPage from '../src/components/BrandPage.tsx'
import { SiteFooter } from '../src/components/SiteChrome.tsx'
import { routeBrand, routeOgImage } from '../src/lib/brand.ts'
import { clampMeta, navBlurb, rewriteDocMarkdown } from '../src/seo/describe.ts'
import { articleJsonLd, routeJsonLd } from '../src/seo/jsonld.ts'
import { absoluteUrl, routeMeta, SITE_ORIGIN as SITE_URL } from '../src/seo/routes.ts'

const siteDir = resolve(import.meta.dirname, '..')
const repoRoot = resolve(siteDir, '..', '..')
const distDir = join(siteDir, 'dist')
const actionAssetSourceDir = join(repoRoot, 'products', 'action', 'docs', 'assets')
const actionMediaPath = '/action/media/'
const sitemapUrls = []

function recordSitemap(path, { priority = '0.7', lastmod } = {}) {
  sitemapUrls.push({ loc: absoluteUrl(path), priority, lastmod })
}
const ACTION_RELEASES_API_URL = actionDownload.releasesUrl
const ACTION_LEGACY_DOWNLOAD_URL = actionDownload.fallbackUrl
const BLINK_RELEASES_API_URL = 'https://api.github.com/repos/lattices-dev/lattices/releases?per_page=100'
const BLINK_LEGACY_DOWNLOAD_URL = 'https://github.com/lattices-dev/lattices/releases/download/blink-v2.1.0/Blink.dmg'
const template = await readFile(join(distDir, 'index.html'), 'utf8')
const shikiTheme = JSON.parse(await readFile(join(siteDir, 'src', 'data', 'lattices-shiki-theme.json'), 'utf8'))
const highlighter = await createHighlighterCore({
  themes: [shikiTheme],
  langs: [
    ...bash,
    ...json,
    ...javascript,
    ...typescript,
    ...swift,
    ...markdown,
    ...mermaid,
  ],
  engine: createJavaScriptRegexEngine(),
})

marked.use({
  mangle: false,
  headerIds: true,
  renderer: createRenderer(),
})

const docs = await readEntries(join(repoRoot, 'docs'), ['.md'])
const posts = (await readEntries(join(siteDir, 'content', 'blog'), ['.md', '.mdx']))
  .filter((post) => !post.data.draft)
  .sort((left, right) => new Date(right.data.date).getTime() - new Date(left.data.date).getTime())

const docUpdated = await getLastUpdatedBatch(
  repoRoot,
  docs.map((doc) => ({ slug: doc.slug, path: join('docs', `${doc.slug}.md`) })),
)
const postUpdated = await getLastUpdatedBatch(
  repoRoot,
  posts.map((post) => ({
    slug: post.slug,
    path: join('apps', 'site', 'content', 'blog', `${post.slug}.mdx`),
  })),
)

await writeStaticRoute('/', renderToString(createElement(LandingPage)))
await writeStaticRoute('/experiment', renderToString(createElement(ConceptExperimentPage)))
await writeStaticRoute('/concept', renderToString(createElement(ConceptExperimentPage)))
await writeStaticRoute('/action', renderActionPage())
await copyActionDocs()
await patchActionAgentsHead()
await writeActionDownloadRedirect()
await writeStaticRoute('/blink', renderToString(createElement(BlinkPage)))
await writeStaticRoute('/speech', renderToString(createElement(SpeechPage)))
await writeStaticRoute('/products', renderToString(createElement(ProductsPage)))
await writeStaticRoute('/family', renderToString(createElement(FamilyPage)))
await writeStaticRoute('/brand', renderToString(createElement(BrandPage)))
await copyBlinkDocs()
await writeBlinkDownloadRedirect()

const overview = docs.find((doc) => doc.slug === 'overview') || docs[0]
const overviewPage = docPage(overview)
await writeRoute('/docs', `${overviewPage.title} — Lattices Docs`, overviewPage.description, overviewPage.html, {
  canonicalPath: `/docs/${overview.slug}`,
  sitemap: false,
  ogImage: routeOgImage('/docs'),
})

for (const doc of docs) {
  const page = doc.slug === overview.slug ? overviewPage : docPage(doc)
  await writeRoute(`/docs/${doc.slug}`, `${page.title} — Lattices Docs`, page.description, page.html, {
    priority: '0.7',
    lastmod: docUpdated[doc.slug] || doc.data.date || undefined,
    ogImage: routeOgImage(`/docs/${doc.slug}`),
  })
}

await writeStaticRoute('/blog', renderBlogIndex(posts))
await writeStaticRoute('/docs/blog', renderBlogIndex(posts))

for (const post of posts) {
  const html = renderPost(post)
  const description = clampMeta(post.data.description || post.data.title || '')
  const jsonLd = articleJsonLd({
    title: post.data.title || titleFromSlug(post.slug),
    description,
    path: `/blog/${post.slug}`,
    date: post.data.date,
    author: post.data.author,
  })
  await writeRoute(`/blog/${post.slug}`, `${post.data.title} — Lattices`, description, html, {
    priority: '0.6',
    lastmod: postUpdated[post.slug] || post.data.date || undefined,
    ogType: 'article',
    jsonLd,
  })
  await writeRoute(`/docs/blog/${post.slug}`, `${post.data.title} — Lattices`, description, html, {
    canonicalPath: `/blog/${post.slug}`,
    sitemap: false,
    ogType: 'article',
    jsonLd,
  })
}

await copyDocsAssets()
for (const route of learningRoutes) {
  await writeRoute(route.path, `${route.title} — Lattices`, route.description, renderToString(createElement(LearnPage, { path: route.path })))
}
await writeAgentArtifacts({ siteDir, repoRoot, distDir })

// Emit a tiny manifest the React SPA can read on hydration for last-updated
// timestamps without shelling out to git at runtime.
await writeFile(
  join(distDir, 'build-meta.json'),
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      repo: { url: repoInfo.repoUrl, branch: repoInfo.branch },
      docs: Object.fromEntries(
        docs.map((doc) => [
          doc.slug,
          {
            updatedAt: docUpdated[doc.slug] || null,
            editUrl: repoInfo.editDocUrl(doc.slug),
          },
        ]),
      ),
      posts: Object.fromEntries(
        posts.map((post) => [
          post.slug,
          {
            updatedAt: postUpdated[post.slug] || null,
            editUrl: repoInfo.editBlogUrl(post.slug),
          },
        ]),
      ),
    },
    null,
    2,
  ),
)

await writeSitemap()
await writeRobots()
await writeRssFeed()
await writeNotFound()

async function writeSitemap() {
  // Copied agent docs keep the URL their own canonical and the site footer already use.
  recordSitemap('/action/agents/', { priority: '0.7' })
  recordSitemap('/blink/agents.md', { priority: '0.7' })
  const urls = sitemapUrls

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls
  .map(
    (u) =>
      `  <url><loc>${u.loc}</loc>${u.lastmod ? `<lastmod>${u.lastmod}</lastmod>` : ''}<priority>${u.priority}</priority></url>`,
  )
  .join('\n')}
</urlset>
`
  await writeFile(join(distDir, 'sitemap.xml'), xml)
}

async function writeRobots() {
  const body = `User-agent: *
Allow: /

Sitemap: ${SITE_URL}/sitemap.xml
`
  await writeFile(join(distDir, 'robots.txt'), body)
}

async function writeRssFeed() {
  const items = posts
    .map((post) => {
      const link = `${SITE_URL}/blog/${post.slug}`
      const pubDate = new Date(post.data.date).toUTCString()
      return `    <item>
      <title>${escapeXml(post.data.title || titleFromSlug(post.slug))}</title>
      <link>${link}</link>
      <guid>${link}</guid>
      <pubDate>${pubDate}</pubDate>
      ${post.data.author ? `<dc:creator>${escapeXml(post.data.author)}</dc:creator>` : ''}
      <description>${escapeXml(post.data.description || '')}</description>
    </item>`
    })
    .join('\n')

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>lattices — blog</title>
    <link>${SITE_URL}/blog</link>
    <description>Ideas and engineering notes from the Lattices team.</description>
    <language>en-us</language>
${items}
  </channel>
</rss>
`
  await writeFile(join(distDir, 'rss.xml'), xml)
}

function escapeXml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

async function readEntries(directory, extensions) {
  const entries = await readdir(directory, { withFileTypes: true })
  const files = entries
    .filter((entry) => entry.isFile() && extensions.some((extension) => entry.name.endsWith(extension)))
    .map((entry) => entry.name)

  return Promise.all(files.map(async (file) => {
    const raw = await readFile(join(directory, file), 'utf8')
    const parsed = splitFrontmatter(raw)
    return {
      slug: file.replace(/\.(md|mdx)$/, ''),
      ...parsed,
    }
  }))
}

async function writeStaticRoute(route, appHtml) {
  const meta = routeMeta(route)
  if (!meta) throw new Error(`Missing SEO metadata for ${route}`)
  await writeRoute(route, meta.title, meta.description, appHtml, {
    canonicalPath: meta.canonicalPath,
    noindex: meta.noindex,
    sitemap: meta.sitemap,
    priority: meta.priority,
    jsonLd: routeJsonLd(meta, meta.ogImage || routeOgImage(meta.canonicalPath || route)),
    ogImage: meta.ogImage,
  })
}

async function writeRoute(route, title, description, appHtml, options = {}) {
  const canonicalPath = options.canonicalPath || route
  const brand = routeBrand(canonicalPath)
  const ogImage = options.ogImage || routeOgImage(canonicalPath)
  const ogImageUrl = `${SITE_URL}${ogImage}`
  const canonical = absoluteUrl(canonicalPath)
  const jsonLdTag = options.jsonLd ? `<script type="application/ld+json">${options.jsonLd}</script>` : ''
  const robotsTag = options.noindex ? '<meta name="robots" content="noindex" />' : ''
  const rssTag = route === '/' || route === '/blog'
    ? '<link rel="alternate" type="application/rss+xml" title="lattices blog" href="/rss.xml" />'
    : ''
  const html = template
    .replace(/<title>.*?<\/title>/, `<title>${escapeHtml(title)}</title>`)
    .replace(
      /<link rel="icon" type="image\/svg\+xml" href=".*?" \/>/,
      `<link rel="icon" type="image/svg+xml" href="${brand.icon}" />`,
    )
    .replace(
      /<link rel="apple-touch-icon" href=".*?" \/>/,
      `<link rel="apple-touch-icon" href="${brand.touchIcon}" />`,
    )
    .replace(
      /<meta property="og:image" content=".*?" \/>/,
      `<meta property="og:image" content="${ogImageUrl}" />`,
    )
    .replace(
      /<meta property="twitter:image" content=".*?" \/>/,
      `<meta property="twitter:image" content="${ogImageUrl}" />`,
    )
    .replace(
      /<meta name="description" content=".*?" \/>/,
      `<meta name="description" content="${escapeHtml(description)}" />`,
    )
    .replace(
      /<link rel="canonical" href=".*?" \/>/,
      `<link rel="canonical" href="${canonical}" />`,
    )
    .replace(
      /<meta property="og:type" content=".*?" \/>/,
      `<meta property="og:type" content="${options.ogType || 'website'}" />`,
    )
    .replace(
      /<meta property="og:title" content=".*?" \/>/,
      `<meta property="og:title" content="${escapeHtml(title)}" />`,
    )
    .replace(
      /<meta property="og:description" content=".*?" \/>/,
      `<meta property="og:description" content="${escapeHtml(description)}" />`,
    )
    .replace(
      /<meta property="og:url" content=".*?" \/>/,
      `<meta property="og:url" content="${canonical}" />`,
    )
    .replace(
      /<meta property="twitter:title" content=".*?" \/>/,
      `<meta property="twitter:title" content="${escapeHtml(title)}" />`,
    )
    .replace(
      /<meta property="twitter:description" content=".*?" \/>/,
      `<meta property="twitter:description" content="${escapeHtml(description)}" />`,
    )
    .replace(
      /<link rel="alternate" type="application\/rss\+xml".*?\/>/,
      rssTag,
    )
    .replace('</head>', `    ${robotsTag}\n    ${jsonLdTag}\n  </head>`)
    .replace('<div id="root"></div>', `<div id="root">${appHtml}</div>`)

  if (options.sitemap !== false && !options.noindex && canonicalPath === route) {
    recordSitemap(route, { priority: options.priority, lastmod: options.lastmod })
  }

  const filePath = route === '/' ? join(distDir, 'index.html') : join(distDir, route.slice(1), 'index.html')
  await mkdir(dirname(filePath), { recursive: true })
  await writeFile(filePath, html)
}

async function writeActionDownloadRedirect() {
  const route = '/action/download'
  const filePath = join(distDir, route.slice(1), 'index.html')
  const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="robots" content="noindex" />
    <meta name="description" content="Download Action for macOS. This page finds the latest Action release and starts the download." />
    <link rel="canonical" href="${SITE_URL}${route}" />
    <link rel="icon" type="image/svg+xml" href="${routeBrand(route).icon}" />
    <title>Download Action for macOS — Lattices</title>
  </head>
  <body>
    <h1>Download Action for macOS</h1>
    <p id="download-status">Finding the latest Action release…</p>
    <p><a id="download-link" href="${escapeHtml(ACTION_LEGACY_DOWNLOAD_URL)}">Download the current Action release manually</a>.</p>
    <script>
      const releasesUrl = ${JSON.stringify(ACTION_RELEASES_API_URL)}
      const legacyUrl = ${JSON.stringify(ACTION_LEGACY_DOWNLOAD_URL)}
      const status = document.getElementById('download-status')
      const link = document.getElementById('download-link')

      async function startDownload() {
        try {
          const response = await fetch(releasesUrl, {
            headers: { Accept: 'application/vnd.github+json' },
          })
          if (!response.ok) throw new Error(\`GitHub returned \${response.status}\`)

          const releases = await response.json()
          const release = releases.find((candidate) =>
            !candidate.draft &&
            !candidate.prerelease &&
            typeof candidate.tag_name === 'string' &&
            candidate.tag_name.startsWith('action-v')
          )
          const asset = release?.assets?.find((candidate) => candidate.name === 'Action.dmg')

          if (asset?.browser_download_url) {
            link.href = asset.browser_download_url
            link.textContent = 'Download Action manually'
            window.location.replace(asset.browser_download_url)
            return
          }
        } catch (error) {
          console.warn('Could not resolve the latest monorepo Action release', error)
        }

        status.textContent = 'Starting the current Action download…'
        window.location.replace(legacyUrl)
      }

      void startDownload()
    </script>
  </body>
</html>
`
  await mkdir(dirname(filePath), { recursive: true })
  await writeFile(filePath, html)
}

async function patchActionAgentsHead() {
  const filePath = join(distDir, 'action', 'agents', 'index.html')
  let html = await readFile(filePath, 'utf8')
  const title = html.match(/<title>([^<]*)<\/title>/)?.[1] || 'Action for agents'
  const description = html.match(/<meta name="description" content="([^"]*)"/)?.[1] || ''
  const image = html.match(/<meta property="og:image" content="([^"]*)"/)?.[1] || `${SITE_URL}/og-action.png`
  if (!html.includes('name="twitter:title"') && !html.includes("name='twitter:title'")) {
    const tags = [
      `<meta name="twitter:title" content="${escapeHtml(title)}">`,
      `<meta name="twitter:description" content="${escapeHtml(description)}">`,
      `<meta name="twitter:image" content="${image}">`,
    ].join('\n  ')
    html = html.replace('</head>', `  ${tags}\n</head>`)
  }
  await writeFile(filePath, html)
}

async function writeNotFound() {
  const title = 'Page not found — Lattices'
  const description = "We couldn't find that page. Here are some good places to start."
  const body = `
    <main class="not-found-shell" data-pagefind-ignore>
      <div class="not-found-card">
        <p class="not-found-kicker">404</p>
        <h1 class="not-found-title">We couldn't find that page</h1>
        <p class="not-found-desc">The link may be outdated, or we may have moved the page. Try one of these instead:</p>
        <ul class="not-found-suggestions">
          <li><a href="/docs/overview">Documentation overview</a> — what lattices is and how to install it</li>
          <li><a href="/docs/quickstart">Quickstart</a> — running workspaces in 2 minutes</li>
          <li><a href="/docs/api">Agent API</a> — WebSocket reference for agents and scripts</li>
          <li><a href="/blog">Blog</a> — release notes and engineering write-ups</li>
          <li><a href="https://github.com/lattices-dev/lattices" target="_blank" rel="noopener noreferrer">GitHub</a> — open an issue if the link should work</li>
        </ul>
      </div>
    </main>
    ${renderFooter()}
  `
  const html = template
    .replace(/<title>.*?<\/title>/, `<title>${escapeHtml(title)}</title>`)
    .replace(
      /<meta name="description" content=".*?" \/>/,
      `<meta name="description" content="${escapeHtml(description)}" />`,
    )
    .replace(/<link rel="canonical" href=".*?" \/>/, '')
    .replace(/<meta property="og:url" content=".*?" \/>/, '')
    .replace(/<meta property="og:title" content=".*?" \/>/, `<meta property="og:title" content="${escapeHtml(title)}" />`)
    .replace(/<meta property="og:description" content=".*?" \/>/, `<meta property="og:description" content="${escapeHtml(description)}" />`)
    .replace(/<meta property="twitter:title" content=".*?" \/>/, `<meta property="twitter:title" content="${escapeHtml(title)}" />`)
    .replace(/<meta property="twitter:description" content=".*?" \/>/, `<meta property="twitter:description" content="${escapeHtml(description)}" />`)
    .replace('</head>', '    <meta name="robots" content="noindex" />\n  </head>')
    .replace('<div id="root"></div>', `<div id="root">${body}</div>`)

  await writeFile(join(distDir, '404.html'), html)
}

/** The sitewide footer, so crawlers find its links on the hand-written pages too. */
function renderFooter(current) {
  return renderToString(createElement(SiteFooter, { current }))
}

function docPage(doc) {
  const explicitTitle = typeof doc.data.title === 'string' ? doc.data.title : ''
  const { content, components } = prepareMarkdown(doc.content)
  const rewritten = rewriteDocMarkdown(content, explicitTitle || undefined)
  const title = explicitTitle || rewritten.firstH1 || titleFromSlug(doc.slug)
  const description = clampMeta(
    (typeof doc.data.description === 'string' && doc.data.description) || navBlurb(doc.slug) || rewritten.summary || 'Lattices documentation',
  )
  const rendered = demoteHtmlH1(substituteMdxComponents(marked.parse(rewritten.markdown), components))
  const updated = docUpdated[doc.slug]
  const html = `
    <main class="docs-shell" data-pagefind-body>
      <article class="docs-article">
        <header class="docs-article-header">
          <h1>${escapeHtml(title)}</h1>
          ${description ? `<p>${escapeHtml(description)}</p>` : ''}
          <div class="docs-meta">
            ${updated ? `<span>Updated ${formatDate(updated)}</span>` : ''}
            <a href="${repoInfo.editDocUrl(doc.slug)}" target="_blank" rel="noopener noreferrer">Edit on GitHub →</a>
          </div>
        </header>
        <div class="markdown-body">${rendered}</div>
      </article>
    </main>
    ${renderFooter(`/docs/${doc.slug}`)}
  `
  return { title, description, html }
}

function demoteHtmlH1(html) {
  return html.replace(/<h1(\s|>)/g, '<h2$1').replace(/<\/h1>/g, '</h2>')
}

function renderTagList(tags) {
  if (!Array.isArray(tags) || tags.length === 0) return ''
  return `<span class="post-tags">${tags.map((tag) => `<span class="post-tag">${escapeHtml(tag)}</span>`).join('')}</span>`
}

function renderBlogIndex(items) {
  return `
    <main class="blog-container" data-pagefind-body>
      <header class="blog-index-head">
        <p class="products-kicker">Lattices blog</p>
        <h1>Notes on workspaces, agents, and the Mac.</h1>
        <p>Short posts about what we are building across Lattices, Action, Blink, and Speech.</p>
      </header>
      <div class="blog-list">
        ${items.map((post) => `
          <a class="blog-post" href="/blog/${post.slug}">
            <span class="blog-post-date">${formatDate(post.data.date)}</span>
            <span class="blog-post-copy">
              <span class="blog-post-title">${escapeHtml(post.data.title || titleFromSlug(post.slug))}</span>
              <span class="blog-post-desc">${escapeHtml(post.data.description || '')}</span>
              ${renderTagList(post.data.tags)}
            </span>
            <span class="blog-post-arrow" aria-hidden="true">→</span>
          </a>
        `).join('')}
      </div>
    </main>
    ${renderFooter('/blog')}
  `
}

function renderPost(post) {
  const { content, components } = prepareMarkdown(post.content)
  const rendered = demoteHtmlH1(substituteMdxComponents(marked.parse(content), components))
  const updated = postUpdated[post.slug]
  const index = posts.findIndex((p) => p.slug === post.slug)
  const newer = index > 0 ? posts[index - 1] : null // posts are sorted newest first
  const older = index < posts.length - 1 ? posts[index + 1] : null
  return `
    <article class="post-container" data-pagefind-body>
      <a href="/blog" class="post-back">← all posts</a>
      <header class="post-header">
        <p class="products-kicker">Lattices blog</p>
        <h1 class="post-title">${escapeHtml(post.data.title || titleFromSlug(post.slug))}</h1>
        ${post.data.description ? `<p class="post-dek">${escapeHtml(post.data.description)}</p>` : ''}
        <div class="post-meta">
          ${post.data.author ? `${escapeHtml(post.data.author)} · ` : ''}
          ${formatDate(post.data.date)}
          ${updated && updated !== post.data.date ? ` · updated ${formatDate(updated)}` : ''}
          <a href="${repoInfo.editBlogUrl(post.slug)}" target="_blank" rel="noopener noreferrer" class="post-edit-link">Edit on GitHub →</a>
          ${renderTagList(post.data.tags)}
        </div>
      </header>
      <div class="prose">${rendered}</div>
      <nav class="post-nav-pager" aria-label="More posts">
        ${newer ? `<a class="post-pager post-pager-prev" href="/blog/${newer.slug}"><span class="post-pager-label">Newer</span><strong>${escapeHtml(newer.data.title || titleFromSlug(newer.slug))}</strong></a>` : '<span></span>'}
        ${older ? `<a class="post-pager post-pager-next" href="/blog/${older.slug}"><span class="post-pager-label">Older</span><strong>${escapeHtml(older.data.title || titleFromSlug(older.slug))}</strong></a>` : '<span></span>'}
      </nav>
    </article>
    ${renderFooter()}
  `
}

function substituteMdxComponents(html, components) {
  if (components.length === 0) return html
  return html.replace(/<!--LATTICES-MDX-(\d+)-->/g, (_, index) => {
    const name = components[Number(index)]
    return name ? renderMdxComponent(name) : ''
  })
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

function prepareMarkdown(content) {
  let prepared = stripMdxImports(content)
    .replace(/\sclient:load/g, '')

  // Replace each MDX component tag with a unique HTML comment marker that
  // marked will pass through untouched (plain-text markers like
  // __FOO_0__ get interpreted as markdown emphasis and break). After
  // marked.parse(), the static export substitutes those markers with the
  // rendered static HTML.
  const components = []
  prepared = prepared.replace(/<(StatsRow|LatencyJourney|TurnPipeline|ArchDiagram|ContextExplorer|TestResults)\s*\/>/g, (_, name) => {
    const index = components.length
    components.push(name)
    return `<!--LATTICES-MDX-${index}-->`
  })

  return { content: prepared.trim(), components }
}

async function copyDocsAssets() {
  const assets = ['architecture.svg', 'app-latest.png', 'app-screenshot.png']

  for (const asset of assets) {
    try {
      await mkdir(join(distDir, 'docs'), { recursive: true })
      await copyFile(join(siteDir, 'public', asset), join(distDir, 'docs', asset))
    } catch {
      // Optional compatibility copy for historical /docs/* asset URLs.
    }
  }
}

async function copyActionDocs() {
  const targetDir = join(distDir, 'action')
  await copyActionReferences({ repoRoot, distDir })

  const landingMedia = [
    'action-record-the-work-poster.jpg',
    'action-record-the-work.mp4',
    'action-record-the-work.vtt',
    join('brand', 'landing-hero.webp'),
    join('brand', 'landing-mira.webp'),
    join('brand', 'landing-trace-field.webp'),
  ]

  for (const relativePath of landingMedia) {
    const destination = join(targetDir, 'media', relativePath)
    await mkdir(dirname(destination), { recursive: true })
    await copyFile(join(actionAssetSourceDir, relativePath), destination)
  }
}

function renderActionPage() {
  const sourcePrefix = `${actionAssetSourceDir}/`
  return renderToString(createElement(ActionPage)).replaceAll(sourcePrefix, actionMediaPath)
}

async function copyBlinkDocs() {
  const targetDir = join(distDir, 'blink')
  await mkdir(targetDir, { recursive: true })
  await copyFile(join(repoRoot, 'products', 'blink', 'landing', 'public', 'llms.txt'), join(targetDir, 'llms.txt'))
  await copyFile(join(repoRoot, 'products', 'blink', 'landing', 'public', 'agents.md'), join(targetDir, 'agents.md'))
}

async function writeBlinkDownloadRedirect() {
  const route = '/blink/download'
  const filePath = join(distDir, route.slice(1), 'index.html')
  const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="robots" content="noindex" />
    <meta name="description" content="Download Blink for macOS. This page finds the latest Blink release and starts the download." />
    <link rel="canonical" href="${SITE_URL}${route}" />
    <link rel="icon" type="image/svg+xml" href="${routeBrand(route).icon}" />
    <title>Download Blink for macOS — Lattices</title>
  </head>
  <body>
    <h1>Download Blink for macOS</h1>
    <p id="download-status">Finding the latest Blink release…</p>
    <p><a id="download-link" href="${escapeHtml(BLINK_LEGACY_DOWNLOAD_URL)}">Download the current Blink release manually</a>.</p>
    <script>
      const releasesUrl = ${JSON.stringify(BLINK_RELEASES_API_URL)}
      const legacyUrl = ${JSON.stringify(BLINK_LEGACY_DOWNLOAD_URL)}
      const status = document.getElementById('download-status')
      const link = document.getElementById('download-link')

      async function startDownload() {
        try {
          const response = await fetch(releasesUrl, {
            headers: { Accept: 'application/vnd.github+json' },
          })
          if (!response.ok) throw new Error(\`GitHub returned \${response.status}\`)

          const releases = await response.json()
          const release = releases.find((candidate) =>
            !candidate.draft &&
            !candidate.prerelease &&
            typeof candidate.tag_name === 'string' &&
            candidate.tag_name.startsWith('blink-v')
          )
          const asset = release?.assets?.find((candidate) => candidate.name === 'Blink.dmg')

          if (asset?.browser_download_url) {
            link.href = asset.browser_download_url
            link.textContent = 'Download Blink manually'
            window.location.replace(asset.browser_download_url)
            return
          }
        } catch (error) {
          console.warn('Could not resolve the latest monorepo Blink release', error)
        }

        status.textContent = 'Starting the current Blink download…'
        window.location.replace(legacyUrl)
      }

      void startDownload()
    </script>
  </body>
</html>
`
  await mkdir(dirname(filePath), { recursive: true })
  await writeFile(filePath, html)
}

function titleFromSlug(slug) {
  return basename(slug)
    .split('-')
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function formatDate(value) {
  return new Date(value).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function createRenderer() {
  const renderer = new marked.Renderer()

  renderer.code = (token) => {
    const language = normalizeLanguage(token.lang)
    const highlighted = highlightStaticCode(token.text, language)

    return [
      '<div class="code-block">',
      '<button type="button" class="code-copy-button" data-pagefind-ignore>Copy</button>',
      `<div class="shiki-code">${highlighted}</div>`,
      '</div>',
    ].join('')
  }

  return renderer
}

function highlightStaticCode(code, language) {
  try {
    return highlighter.codeToHtml(code, { lang: language, theme: 'lattices-ink' })
  } catch {
    return highlighter.codeToHtml(code, { lang: 'text', theme: 'lattices-ink' })
  }
}

function normalizeLanguage(language) {
  const lang = language?.toLowerCase().trim()

  if (!lang) return 'text'
  if (lang === 'sh' || lang === 'shell' || lang === 'zsh') return 'bash'
  if (lang === 'js' || lang === 'jsx') return 'javascript'
  if (lang === 'ts' || lang === 'tsx') return 'typescript'

  return ['bash', 'json', 'javascript', 'typescript', 'swift', 'markdown', 'mermaid', 'text'].includes(lang)
    ? lang
    : 'text'
}
