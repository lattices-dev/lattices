import { useEffect, useState } from 'react'
import { BlogIndex, BlogPostPage } from './components/Blog'
import ActionPage from './components/ActionPage'
import BlinkPage from './components/BlinkPage'
import SpeechPage from './components/SpeechPage'
import LinuxPage from './components/LinuxPage'
import ProductsPage from './components/ProductsPage'
import { DocsPage } from './components/Docs'
import LandingPage from './components/LandingPage'
import ConceptExperimentPage from './components/ConceptExperimentPage'
import LearnPage from './components/LearnPage'
import { getLearningRoute, LEARNING_SITE_URL } from './lib/learning'
import BrandPage from './components/BrandPage'
import { SiteFooter, SiteHeader } from './components/SiteChrome'
import { getBlogPost, getDoc } from './lib/content'
import { getBuildMeta } from './lib/build-meta'
import { docsProduct, resolveDoc, isCurrentDoc, type ProductId } from './lib/docs-catalog'
import { routeBrand, routeOgImage } from './lib/brand'
import { routeMeta } from './seo/routes'
import { articleJsonLd, routeJsonLd } from './seo/jsonld'
import { docHeadLinks, docJsonLd } from './seo/docs'

export default function SiteApp() {
  const [path, setPath] = useState(() => normalizePath(window.location.pathname))
  const route = resolveRoute(path)

  useEffect(() => {
    // React replaces the static body on startup; restore a shared section link
    // after its headings have mounted.
    if (window.location.hash) scrollAfterNavigation(window.location.hash)
  }, [])

  useEffect(() => {
    document.title = route.title
    const entry = resolveDoc(path)
    let robots = document.querySelector<HTMLMetaElement>('meta[name="robots"]')
    if (entry && !isCurrentDoc(entry)) {
      if (!robots) { robots = document.createElement('meta'); robots.name = 'robots'; document.head.append(robots) }
      robots.content = 'noindex'
    } else if (!routeMeta(path)?.noindex) robots?.remove()
    setMeta('description', route.description)
    // Keep metadata correct when entering or leaving a lesson through client navigation.
    const canonicalPath = routeMeta(path)?.canonicalPath ?? resolveDoc(path)?.canonicalPath ?? path.replace(/^\/docs\/blog/, '/blog')
    document.querySelector('link[rel="canonical"]')?.setAttribute('href', `${LEARNING_SITE_URL}${canonicalPath}`)
    for (const prefix of ['og', 'twitter']) {
      document.querySelector(`meta[property="${prefix}:title"]`)?.setAttribute('content', route.title)
      document.querySelector(`meta[property="${prefix}:description"]`)?.setAttribute('content', route.description)
      document.querySelector(`meta[property="${prefix}:image"]`)?.setAttribute('content', `${LEARNING_SITE_URL}${routeMeta(path)?.ogImage || routeOgImage(canonicalPath)}`)
    }
    document.querySelector('meta[property="og:url"]')?.setAttribute('content', `${LEARNING_SITE_URL}${canonicalPath}`)
  }, [path, route.description, route.title])

  useEffect(() => {
    let cancelled = false
    // Replace static route metadata on navigation, including navigation out of
    // docs. Body-owned schemas (Action and Learn) follow their React components.
    document.head.querySelectorAll('[data-route-metadata]').forEach((node) => node.remove())
    const script = document.createElement('script')
    script.type = 'application/ld+json'
    script.dataset.routeMetadata = ''
    const setJsonLd = (value: string | null) => {
      if (!value || cancelled) return
      script.textContent = value
      if (!script.isConnected) document.head.append(script)
    }
    const entry = resolveDoc(path)
    if (entry) {
      const doc = getDoc(entry.slug, entry.product)!
      const metadata = { title: doc.title, description: doc.description }
      setJsonLd(docJsonLd(entry, metadata))
      for (const attributes of docHeadLinks(doc)) {
        const link = document.createElement('link')
        Object.assign(link, attributes)
        link.dataset.routeMetadata = ''
        document.head.append(link)
      }
      getBuildMeta().then((meta) => {
        setJsonLd(docJsonLd(entry, { ...metadata, updatedAt: meta?.docs[entry.id]?.updatedAt }))
      })
    } else {
      const meta = routeMeta(path)
      if (meta) setJsonLd(routeJsonLd(meta, meta.ogImage || routeOgImage(meta.canonicalPath || path)))
      else if (/^\/(?:docs\/)?blog\//.test(path)) {
        const post = getBlogPost(path.replace(/^\/(docs\/)?blog\//, ''))
        if (post) setJsonLd(articleJsonLd({ ...post, path: `/blog/${post.slug}` }))
      }
    }
    return () => {
      cancelled = true
      document.head.querySelectorAll('[data-route-metadata]').forEach((node) => node.remove())
    }
  }, [path])

  useEffect(() => {
    const brand = routeBrand(path)
    setLink('icon', brand.icon)
    setLink('apple-touch-icon', brand.touchIcon)
  }, [path])

  useEffect(() => {
    const syncPath = () => setPath(normalizePath(window.location.pathname))
    window.addEventListener('popstate', syncPath)
    return () => window.removeEventListener('popstate', syncPath)
  }, [])

  useEffect(() => {
    const handleClick = (event: MouseEvent) => {
      if (shouldIgnoreClick(event)) return

      const target = event.target instanceof Element ? event.target : null
      const anchor = target?.closest<HTMLAnchorElement>('a[href]')
      if (!anchor || shouldIgnoreAnchor(anchor)) return

      const url = new URL(anchor.href, window.location.href)
      if (url.origin !== window.location.origin) return

      const nextPath = normalizePath(url.pathname)
      if (url.pathname === window.location.pathname && url.hash) return
      if (resolveRoute(nextPath).kind === 'not-found') return

      event.preventDefault()
      window.history.pushState({}, '', `${url.pathname}${url.search}${url.hash}`)
      setPath(nextPath)
      scrollAfterNavigation(url.hash)
    }

    document.addEventListener('click', handleClick)
    return () => document.removeEventListener('click', handleClick)
  }, [])

  if (route.kind === 'home') return <LandingPage />
  if (route.kind === 'learning') return <LearnPage path={path} />
  if (route.kind === 'experiment') return <ConceptExperimentPage />
  if (route.kind === 'action') return <ActionPage />
  if (route.kind === 'blink') return <BlinkPage />
  if (route.kind === 'speech') return <SpeechPage />
  if (route.kind === 'linux') return <LinuxPage />
  if (route.kind === 'products') return <ProductsPage />
  if (route.kind === 'brand') return <BrandPage />
  if (route.kind === 'docs') return <DocsPage product={route.product} slug={route.slug} />
  if (route.kind === 'blog-index') return <BlogIndex />
  if (route.kind === 'blog-post') return <BlogPostPage slug={route.slug} />

  return (
    <div className="docs-page">
      <SiteHeader />
      <main className="not-found-shell" data-pagefind-ignore>
        <div className="not-found-card">
          <p className="not-found-kicker">404</p>
          <h1 className="not-found-title">We couldn't find that page</h1>
          <p className="not-found-desc">
            The link may be outdated, or we may have moved the page. Try one of these instead:
          </p>
          <ul className="not-found-suggestions">
            <li>
              <a href="/lattices/docs/overview">Documentation overview</a> — what lattices is and how to install it
            </li>
            <li>
              <a href="/lattices/docs/quickstart">Quickstart</a> — running workspaces in 2 minutes
            </li>
            <li>
              <a href="/products">Products</a> — Lattices, Action, Canvas, and Speech
            </li>
            <li>
              <a href="/lattices/docs/api">Agent API</a> — WebSocket reference for agents and scripts
            </li>
            <li>
              <a href="/blog">Blog</a> — release notes and engineering write-ups
            </li>
            <li>
              <a href="https://github.com/lattices-dev/lattices" target="_blank" rel="noopener noreferrer">
                GitHub
              </a>{' '}
              — open an issue if the link should work
            </li>
          </ul>
        </div>
      </main>
      <SiteFooter />
    </div>
  )
}

type Route =
  | { kind: 'learning'; title: string; description: string }
  | { kind: 'home'; title: string; description: string }
  | { kind: 'experiment'; title: string; description: string }
  | { kind: 'action'; title: string; description: string }
  | { kind: 'blink'; title: string; description: string }
  | { kind: 'speech'; title: string; description: string }
  | { kind: 'linux'; title: string; description: string }
  | { kind: 'products'; title: string; description: string }
  | { kind: 'brand'; title: string; description: string }
  | { kind: 'docs'; product: ProductId; slug?: string; title: string; description: string }
  | { kind: 'blog-index'; title: string; description: string }
  | { kind: 'blog-post'; slug: string; title: string; description: string }
  | { kind: 'not-found'; title: string; description: string }

function copyFor(path: string): { title: string; description: string } {
  const meta = routeMeta(path)
  if (!meta) throw new Error(`Missing SEO metadata for ${path}`)
  return { title: meta.title, description: meta.description }
}

function resolveRoute(path: string): Route {
  const learning = getLearningRoute(path)
  if (learning) return { kind: 'learning', title: `${learning.title} — Lattices`, description: learning.description }
  if (path === '/experiment' || path === '/concept') {
    return { kind: 'experiment', ...copyFor('/experiment') }
  }

  if (path === '/') return { kind: 'home', ...copyFor('/') }
  if (path === '/action') return { kind: 'action', ...copyFor('/action') }
  if (path === '/speech') return { kind: 'speech', ...copyFor('/speech') }
  if (path === '/linux') return { kind: 'linux', ...copyFor('/linux') }
  if (path === '/products') return { kind: 'products', ...copyFor('/products') }
  if (path === '/family') return { kind: 'products', ...copyFor('/products') }
  if (path === '/brand') return { kind: 'brand', ...copyFor('/brand') }
  if (path === docsProduct('blink').home || path === '/blink') return { kind: 'blink', ...copyFor(docsProduct('blink').home) }

  if (path === '/blog' || path === '/docs/blog') {
    return { kind: 'blog-index', ...copyFor('/blog') }
  }

  if (path.startsWith('/blog/') || path.startsWith('/docs/blog/')) {
    const slug = path.replace(/^\/(docs\/)?blog\//, '')
    const post = getBlogPost(slug)
    return post
      ? {
          kind: 'blog-post',
          slug,
          title: `${post.title} — Lattices`,
          description: post.description,
        }
      : { kind: 'not-found', title: 'Post not found — Lattices', description: 'Post not found' }
  }

  const entry = resolveDoc(path)
  if (entry) {
    const doc = getDoc(entry.slug, entry.product)
    if (doc) return {
      kind: 'docs', product: entry.product, slug: entry.slug,
      title: `${doc.title} — ${docsProduct(entry.product).title} Docs`,
      description: doc.description || `${docsProduct(entry.product).title} documentation`,
    }
  }

  return {
    kind: 'not-found',
    title: 'Page not found — Lattices',
    description: 'Page not found',
  }
}

function shouldIgnoreClick(event: MouseEvent): boolean {
  return (
    event.defaultPrevented ||
    event.button !== 0 ||
    event.metaKey ||
    event.altKey ||
    event.ctrlKey ||
    event.shiftKey
  )
}

function shouldIgnoreAnchor(anchor: HTMLAnchorElement): boolean {
  return (
    Boolean(anchor.target && anchor.target !== '_self') ||
    anchor.hasAttribute('download') ||
    anchor.dataset.router === 'reload'
  )
}

function scrollAfterNavigation(hash: string): void {
  requestAnimationFrame(() => {
    if (!hash) {
      window.scrollTo({ top: 0, left: 0 })
      return
    }

    try {
      document.getElementById(decodeURIComponent(hash.slice(1)))?.scrollIntoView()
    } catch {
      document.getElementById(hash.slice(1))?.scrollIntoView()
    }
  })
}

function normalizePath(pathname: string): string {
  if (pathname.length > 1 && pathname.endsWith('/')) {
    return pathname.slice(0, -1)
  }

  return pathname
}

function setMeta(name: string, content: string): void {
  const meta = document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)
  if (meta) {
    meta.content = content
  }
}

function setLink(rel: string, href: string): void {
  const link = document.querySelector<HTMLLinkElement>(`link[rel="${rel}"]`)
  if (link) {
    link.href = href
  }
}
