import { useState } from 'react'
import { docsHome, docsProduct, docsProducts, productNav, type ProductId } from '../lib/docs-catalog'

export function ProductDocsLinks({ product }: { product: ProductId }) {
  return (
    <div className="docs-product-picker">
      <span>Product documentation</span>
      <ul aria-label="Choose product documentation">
        {docsProducts.map((item) => (
          <li key={item.id}>
            <a href={docsHome(item.id)} aria-current={item.id === product ? 'true' : undefined}>
              {item.title}
            </a>
          </li>
        ))}
      </ul>
    </div>
  )
}

export function DocsSidebar({ currentSlug, product }: { currentSlug: string; product: ProductId }) {
  const [mobileOpen, setMobileOpen] = useState(false)
  const currentItem = productNav(product).flatMap((group) => group.items).find((item) => item.id === currentSlug)

  return (
    <nav className="sidebar-nav" aria-label={`${docsProduct(product).title} documentation`}>
      <ProductDocsLinks product={product} />
      <div className="desktop-sidebar-nav">
        <NavGroups product={product} currentSlug={currentSlug} />
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
            <span className="mobile-docs-label">{docsProduct(product).title} docs</span>
            <span className="mobile-docs-current">{currentItem?.title || 'Documentation'}</span>
          </span>
          <span className="mobile-docs-chevron" aria-hidden="true">{mobileOpen ? '−' : '+'}</span>
        </button>
        <div id="mobile-docs-panel" className="mobile-docs-panel" hidden={!mobileOpen}>
          <NavGroups product={product} currentSlug={currentSlug} compact />
        </div>
      </div>
    </nav>
  )
}

function NavGroups({ currentSlug, product, compact = false }: { currentSlug: string; product: ProductId; compact?: boolean }) {
  return (
    <>
      {productNav(product).map((group) => (
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

export function DocPager({ currentSlug, product }: { currentSlug: string; product: ProductId }) {
  const items = productNav(product).flatMap((group) => group.items)
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

