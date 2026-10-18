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
      { label: 'What it can do', href: '/family' },
      { label: 'All products', href: '/products' },
    ],
  },
  {
    title: 'Docs',
    links: [
      { label: 'Overview', href: '/docs/overview' },
      { label: 'Quickstart', href: '/docs/quickstart' },
      { label: 'Concepts', href: '/docs/concepts' },
      { label: 'Configuration', href: '/docs/config' },
      { label: 'Layers & tab groups', href: '/docs/layers' },
      { label: 'Mouse gestures', href: '/docs/mouse-gestures' },
      { label: 'Screen OCR & search', href: '/docs/ocr' },
      { label: 'Menu bar app', href: '/docs/app' },
    ],
  },
  {
    title: 'For agents',
    links: [
      { label: 'Agent guide', href: '/docs/agents' },
      { label: 'Agent API', href: '/docs/api' },
      { label: 'Embedded SDK', href: '/docs/embedded-sdk' },
      { label: 'Action for agents', href: '/action/agents/' },
      { label: 'Blink for agents', href: '/blink/agents.md' },
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
