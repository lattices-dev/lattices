import { docsProduct } from '../lib/docs-catalog'

export interface ProductLink {
  href: string
  title: string
  description: string
  meta: string
}

export const productLinks: ProductLink[] = [
  {
    href: '/',
    title: 'Lattices',
    description: "Find any project's windows. Put them in place, for you or your agent.",
    meta: 'Core app + API',
  },
  {
    href: '/action',
    title: 'Action',
    description: 'Record, review, and drive computer use',
    meta: 'macOS app',
  },
  {
    href: docsProduct('blink').home,
    title: docsProduct('blink').title,
    description: 'Spatial notes that live on your desktop',
    meta: 'macOS app',
  },
  {
    href: '/voice',
    title: 'Voice',
    description: 'A standalone player for queued text',
    meta: 'Menu bar app',
  },
]
