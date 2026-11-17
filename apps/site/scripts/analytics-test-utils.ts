import { runInNewContext } from 'node:vm'

export function analyticsBootstrap(html: string) {
  return html.match(/<script id="site-analytics">([\s\S]*?)<\/script>/)?.[1]
}

/** Execute only our bootstrap; record script requests without loading trackers. */
export function inspectAnalytics(html: string, origin: string, privacy = {}) {
  const source = analyticsBootstrap(html)
  if (!source) throw new Error('Shared analytics bootstrap is missing')
  const scripts: Array<{ src: string; async: boolean; dataset: Record<string, string> }> = []
  const window: {
    location: { origin: string }
    dataLayer?: IArguments[]
    gtag?: (...args: unknown[]) => void
  } = { location: { origin } }
  runInNewContext(source, {
    window,
    navigator: privacy,
    document: {
      createElement: () => ({ dataset: {} }),
      head: { appendChild: (script: typeof scripts[number]) => scripts.push(script) },
    },
  })
  return { window, scripts }
}

export function hasUnconditionalAnalytics(html: string) {
  return /<script\b[^>]*\bsrc=["'][^"']*(?:googletagmanager|google-analytics)/.test(html)
}
