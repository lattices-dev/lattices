/**
 * Which product a route belongs to, and the tab icon and social card that go
 * with it. The icons come from each product's kit in public/brand/, written by
 * `bun run brand`; the cards from `bun run og`.
 */
export type BrandSlug = 'lattices' | 'action' | 'blink' | 'speech'

export interface RouteBrand {
  slug: BrandSlug
  icon: string
  touchIcon: string
  ogImage: string
}

const productSections: readonly string[] = ['action', 'blink', 'speech']

const ogImageOverrides: Readonly<Record<string, string>> = {
  '/docs/api': '/og-api.png',
  '/docs/config': '/og-cli.png',
}

export function routeBrand(path: string): RouteBrand {
  const section = path.split('/')[1] ?? ''
  const slug = (productSections.includes(section) ? section : 'lattices') as BrandSlug

  if (slug === 'lattices') {
    return {
      slug,
      icon: '/favicon.svg',
      touchIcon: '/brand/lattices/lattices-touch-icon.png',
      ogImage: section === 'docs' ? '/og-docs.png' : '/og.png',
    }
  }

  return {
    slug,
    icon: `/brand/${slug}/${slug}-favicon.svg`,
    touchIcon: `/brand/${slug}/${slug}-touch-icon.png`,
    ogImage: `/og-${slug}.png`,
  }
}

/** Social card for a path. Product routes use their own card; a few docs have a dedicated one. */
export function routeOgImage(path: string): string {
  return ogImageOverrides[path] ?? routeBrand(path).ogImage
}
