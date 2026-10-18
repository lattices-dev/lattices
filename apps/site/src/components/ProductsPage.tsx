import { productLinks } from '../data/products'
import { SiteFooter, SiteHeader } from './SiteChrome'

const directoryLinks = [
  {
    href: '/docs/overview',
    title: 'Documentation',
    description: 'Install, configure, and automate Lattices.',
  },
  {
    href: '/docs/api',
    title: 'Agent API',
    description: 'The local WebSocket surface for agents and scripts.',
  },
  {
    href: '/blog',
    title: 'Blog',
    description: 'Short notes on what we are building and learning.',
  },
]

export default function ProductsPage() {
  return (
    <div className="docs-page products-page">
      <SiteHeader />
      <main className="products-index" data-pagefind-body>
        <header className="products-index-head">
          <p className="products-kicker">Lattices family</p>
          <h1>Every surface for your workspace.</h1>
          <p>
            Start with the workspace shell, then add the focused companion apps and APIs when you need
            computer use, spatial notes, or speech playback.
          </p>
        </header>

        <section className="products-grid" aria-label="Products">
          {productLinks.map((product, index) => (
            <a className="product-card" href={product.href} key={product.href}>
              <span className="product-card-index">{String(index + 1).padStart(2, '0')}</span>
              <span className="product-card-copy">
                <span className="product-card-title">{product.title}</span>
                <span className="product-card-desc">{product.description}</span>
                <span className="product-card-meta">{product.meta}</span>
              </span>
              <span className="product-card-arrow" aria-hidden="true">→</span>
            </a>
          ))}
        </section>

        <section className="products-directory" aria-label="Related pages">
          <div>
            <p className="products-kicker">Directory</p>
            <h2>More ways in</h2>
          </div>
          <div className="products-directory-list">
            {directoryLinks.map((link) => (
              <a href={link.href} key={link.href}>
                <span>{link.title}</span>
                <small>{link.description}</small>
              </a>
            ))}
          </div>
        </section>
      </main>
      <SiteFooter current="/products" />
    </div>
  )
}
