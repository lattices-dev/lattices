import { absoluteUrl, SITE_ORIGIN, type RouteMeta, type SoftwareFacts } from './routes'

const organizationId = `${SITE_ORIGIN}/#organization`

function organization() {
  return {
    '@type': 'Organization',
    '@id': organizationId,
    name: 'Lattices',
    url: `${SITE_ORIGIN}/`,
    logo: `${SITE_ORIGIN}/brand/lattices/lattices-icon-512.png`,
    sameAs: ['https://github.com/lattices-dev/lattices'],
  }
}

function softwareNode(facts: SoftwareFacts, route: Pick<RouteMeta, 'path' | 'description' | 'ogImage'>, ogImage: string) {
  return {
    '@type': 'SoftwareApplication',
    name: facts.name,
    applicationCategory: facts.applicationCategory,
    operatingSystem: facts.operatingSystem,
    url: absoluteUrl(route.path),
    description: route.description,
    downloadUrl: facts.downloadUrl,
    image: absoluteUrl(ogImage),
    ...(facts.softwareVersion ? { softwareVersion: facts.softwareVersion } : {}),
    ...(facts.free ? { isAccessibleForFree: true } : {}),
    publisher: { '@id': organizationId },
  }
}

export function routeJsonLd(route: RouteMeta, ogImage: string): string | null {
  if (route.jsonLd === 'none' || route.canonicalPath) return null

  if (route.jsonLd === 'home' && route.software) {
    return serialize({
      '@context': 'https://schema.org',
      '@graph': [
        organization(),
        {
          '@type': 'WebSite',
          '@id': `${SITE_ORIGIN}/#website`,
          name: 'Lattices',
          url: `${SITE_ORIGIN}/`,
          publisher: { '@id': organizationId },
        },
        softwareNode(route.software, route, ogImage),
      ],
    })
  }

  if (route.jsonLd === 'software' && route.software) {
    return serialize({
      '@context': 'https://schema.org',
      '@graph': [organization(), softwareNode(route.software, route, ogImage)],
    })
  }

  return null
}

export interface ArticleFacts {
  title: string
  description: string
  path: string
  date?: string
  author?: string
}

export function articleJsonLd(article: ArticleFacts): string | null {
  if (!article.title || !article.date) return null
  return serialize({
    '@context': 'https://schema.org',
    '@type': 'BlogPosting',
    headline: article.title,
    description: article.description,
    datePublished: article.date,
    url: absoluteUrl(article.path),
    mainEntityOfPage: absoluteUrl(article.path),
    ...(article.author
      ? { author: { '@type': 'Person', name: article.author } }
      : {}),
    publisher: organization(),
  })
}

function serialize(data: unknown): string {
  return JSON.stringify(data).replace(/</g, '\\u003c')
}
