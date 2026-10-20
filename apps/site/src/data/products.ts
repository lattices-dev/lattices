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
    description: 'The programmable workspace for macOS and Linux',
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
    href: '/speech',
    title: 'Speech',
    description: 'A standalone player for queued text',
    meta: 'Menu bar app',
  },
]
