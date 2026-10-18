import { useEffect, useState } from 'react'
import { defaultDoc, getDoc, navGroups, type DocPage } from '../lib/content'
import { formatBuildDate, getBuildMeta, type DocMeta } from '../lib/build-meta'
import { MarkdownRenderer } from './MarkdownRenderer'
import { SiteFooter, SiteHeader } from './SiteChrome'

interface DocsPageProps {
  slug?: string
}

export function DocsPage({ slug }: DocsPageProps) {
  const doc = slug ? getDoc(slug) : defaultDoc()
  const [meta, setMeta] = useState<DocMeta | null>(null)

  useEffect(() => {
    if (!doc) return
    let cancelled = false
    getBuildMeta().then((m) => {
      if (cancelled) return
      setMeta(m?.docs?.[doc.slug] ?? null)
    })
    return () => {
      cancelled = true
    }
  }, [doc])

  if (!doc) {
    return (
      <div className="docs-page">
        <SiteHeader />
        <main className="not-found-shell" data-pagefind-ignore>
          <div className="not-found-card">
            <p className="not-found-kicker">404</p>
            <h1 className="not-found-title">Page not found</h1>
            <p className="not-found-desc">
              The docs page may have been moved.{' '}
              <a href="/docs/overview">Back to the docs overview →</a>
            </p>
          </div>
        </main>
        <SiteFooter />
      </div>
    )
  }

  const updatedLabel = formatBuildDate(meta?.updatedAt)

  return (
    <div className="docs-page">
      <SiteHeader />
      <main className="docs-shell" data-pagefind-body>
        <aside className="docs-sidebar" data-pagefind-ignore>
          <Sidebar key={doc.slug} currentSlug={doc.slug} />
        </aside>
        <article className="docs-article">
          <header className="docs-article-header">
            <h1>{doc.title}</h1>
            {doc.description && <p>{doc.description}</p>}
            {(updatedLabel || meta?.editUrl) && (
              <div className="docs-meta">
                {updatedLabel && <span>Updated {updatedLabel}</span>}
                {meta?.editUrl && (
                  <a
                    href={meta.editUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Edit on GitHub →
                  </a>
                )}
              </div>
            )}
          </header>
          <MarkdownRenderer content={doc.content} />
          <DocPager currentSlug={doc.slug} />
        </article>
        <aside className="docs-toc" data-pagefind-ignore>
          <TableOfContents doc={doc} />
        </aside>
      </main>
      <SiteFooter current={`/docs/${doc.slug}`} />
    </div>
  )
}

function Sidebar({ currentSlug }: { currentSlug: string }) {
  const [mobileOpen, setMobileOpen] = useState(false)
  const currentItem = navGroups.flatMap((group) => group.items).find((item) => item.id === currentSlug)

  return (
    <nav className="sidebar-nav" aria-label="Documentation">
      <div className="desktop-sidebar-nav">
        <NavGroups currentSlug={currentSlug} />
      </div>
      <div className={mobileOpen ? 'mobile-docs-nav open' : 'mobile-docs-nav'}>
        <button
          type="button"
          className="mobile-docs-trigger"
          aria-expanded={mobileOpen}
          aria-controls="mobile-docs-panel"
          onClick={() => setMobileOpen((open) => !open)}
        >
          <span>
            <span className="mobile-docs-label">Docs menu</span>
            <span className="mobile-docs-current">{currentItem?.title || 'Documentation'}</span>
          </span>
          <span className="mobile-docs-chevron" aria-hidden="true">{mobileOpen ? '−' : '+'}</span>
        </button>
        <div id="mobile-docs-panel" className="mobile-docs-panel" hidden={!mobileOpen}>
          <NavGroups currentSlug={currentSlug} compact />
        </div>
      </div>
    </nav>
  )
}

function NavGroups({ currentSlug, compact = false }: { currentSlug: string; compact?: boolean }) {
  return (
    <>
      {navGroups.map((group) => (
        <details key={group.id} open={!compact || group.items.some((item) => item.id === currentSlug)}>
          <summary>
            <span>{group.title}</span>
            <span>▾</span>
          </summary>
          <ul>
            {group.items.map((item) => (
              <li key={item.id}>
                <a
                  className={currentSlug === item.id ? 'active' : undefined}
                  href={item.href}
                  aria-current={currentSlug === item.id ? 'page' : undefined}
                >
                  {item.title}
                </a>
              </li>
            ))}
          </ul>
        </details>
      ))}
    </>
  )
}

function DocPager({ currentSlug }: { currentSlug: string }) {
  const items = navGroups.flatMap((group) => group.items)
  const index = items.findIndex((item) => item.id === currentSlug)
  if (index < 0) return null
  const prev = items[index - 1]
  const next = items[index + 1]
  if (!prev && !next) return null

  return (
    <nav className="docs-pager" aria-label="Previous and next page" data-pagefind-ignore>
      {prev ? (
        <a className="docs-pager-link" href={prev.href} rel="prev">
          <small>Previous</small>
          <span>{prev.title}</span>
        </a>
      ) : <span />}
      {next && (
        <a className="docs-pager-link next" href={next.href} rel="next">
          <small>Next</small>
          <span>{next.title}</span>
        </a>
      )}
    </nav>
  )
}

/** Tracks the heading nearest the top of the viewport for the on-this-page rail. */
function useActiveHeading(ids: string[]): string | null {
  const [active, setActive] = useState<string | null>(ids[0] ?? null)
  const key = ids.join('|')

  useEffect(() => {
    const list = key ? key.split('|') : []
    if (list.length === 0) return
    let frame = 0
    const update = () => {
      frame = 0
      const offset = 120
      let current = list[0]
      for (const id of list) {
        const el = document.getElementById(id)
        if (!el) continue
        if (el.getBoundingClientRect().top - offset <= 0) current = id
        else break
      }
      const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4
      setActive(atBottom ? list[list.length - 1] : current)
    }
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(update)
    }
    update()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      if (frame) cancelAnimationFrame(frame)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
    }
  }, [key])

  return active
}

function TableOfContents({ doc }: { doc: DocPage }) {
  const headings = doc.headings.filter((heading) => heading.depth >= 2 && heading.depth <= 3)
  const active = useActiveHeading(headings.map((heading) => heading.id))

  if (headings.length === 0) return null

  return (
    <nav className="toc-nav" aria-label="On this page">
      <p>On this page</p>
      <ul>
        {headings.map((heading) => (
          <li key={heading.id} className={heading.depth === 3 ? 'nested' : undefined}>
            <a
              href={`#${heading.id}`}
              className={active === heading.id ? 'active' : undefined}
              aria-current={active === heading.id ? 'location' : undefined}
            >
              {heading.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}
