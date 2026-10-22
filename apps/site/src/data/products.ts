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

/** Products-menu-only entries, shown after the product they belong to. */
export const productMenuExtras: Record<string, ProductLink> = {
  '/': {
    href: '/linux',
    title: 'Lattices for Linux',
    description: 'The same workspace on Omarchy and Hyprland',
    meta: 'Linux app',
  },
}
