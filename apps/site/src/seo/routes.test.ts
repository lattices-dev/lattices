import { describe, expect, test } from 'bun:test'
import { routeBrand, routeOgImage } from '../lib/brand'
import { routeJsonLd } from './jsonld'
import { routeMeta, staticRoutes } from './routes'

describe('Canvas public route compatibility', () => {
  test('indexes Canvas and retains Blink as an alias of the same product', () => {
    const canonical = routeMeta('/canvas')!
    const legacy = routeMeta('/blink')!
    expect(canonical.title).toBe('Canvas — spatial notes from Lattices')
    expect(canonical.canonicalPath).toBeUndefined()
    expect(canonical.software?.downloadUrl).toBe('https://lattices.dev/canvas/download')
    expect(legacy.canonicalPath).toBe('/canvas')
    expect(legacy.sitemap).toBe(false)
    expect(staticRoutes.filter((route) => route.software?.name === 'Canvas' && !route.canonicalPath).map((route) => route.path)).toEqual(['/canvas'])
    const metadata = routeJsonLd(canonical, routeOgImage(canonical.path))!
    expect(routeJsonLd(legacy, routeOgImage(legacy.path))).toBe(metadata)
    const product = JSON.parse(metadata)['@graph'].find((node: { '@type': string }) => node['@type'] === 'SoftwareApplication')
    expect(product.name).toBe('Canvas')
    expect(product.url).toBe('https://lattices.dev/canvas')
  })

  test('uses the existing product artwork for Canvas and old Blink routes', () => {
    for (const path of ['/canvas', '/canvas/docs/api', '/blink', '/blink/docs/api']) {
      expect(routeBrand(path)).toEqual({
        slug: 'blink', icon: '/brand/blink/blink-favicon.svg',
        touchIcon: '/brand/blink/blink-touch-icon.png', ogImage: '/og-blink.png',
      })
    }
    expect(routeBrand('/unrelated').slug).toBe('lattices')
  })
})
