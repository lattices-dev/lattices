import { docsProducts, docsHome, docsProduct } from '../lib/docs-catalog'
import { productLinks } from './products'

export interface FooterLink {
  label: string
  href: string
  /** Leaves lattices.dev, so it opens in a new tab. */
  external?: boolean
}

export interface FooterColumn {
  title: string
  links: FooterLink[]
}

const repo = 'https://github.com/lattices-dev/lattices'

/** The sitewide footer's link columns, after the brand column. */
export const footerColumns: FooterColumn[] = [
  {
    title: 'Products',
    links: [
      ...productLinks.map(({ title, href }) => ({ label: title, href })),
      { label: 'All products', href: '/products' },
    ],
  },
  {
    title: 'Documentation',
    links: docsProducts.map((product) => ({ label: product.title, href: docsHome(product.id) })),
  },
  {
    title: 'For agents',
    links: [
      { label: 'Agent guide', href: '/lattices/docs/agents' },
      { label: 'Agent API', href: '/lattices/docs/api' },
      { label: 'Embedded SDK', href: '/lattices/docs/embedded-sdk' },
      { label: 'Action for agents', href: '/action/docs/agent-setup' },
      { label: `${docsProduct('blink').title} for agents`, href: docsProduct('blink').agent.guide },
      { label: 'Voice for agents', href: '/voice/docs/agents' },
      { label: 'llms.txt', href: '/llms.txt' },
      { label: 'AGENTS.md', href: '/AGENTS.md' },
    ],
  },
  {
    title: 'Resources',
    links: [
      { label: 'Learn', href: '/learn' },
      { label: 'Blog', href: '/blog' },
      { label: 'RSS feed', href: '/rss.xml' },
      { label: 'Brand', href: '/brand' },
      { label: 'Releases', href: `${repo}/releases`, external: true },
      { label: 'Source', href: repo, external: true },
      { label: 'Report an issue', href: `${repo}/issues/new`, external: true },
      { label: 'CLI on npm', href: 'https://www.npmjs.com/package/@lattices/lattices', external: true },
    ],
  },
]

export const licenseUrl = `${repo}/blob/main/LICENSE`
