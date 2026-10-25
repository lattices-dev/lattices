// Tiny fetcher for the build-time manifest emitted to /build-meta.json.
// Caches the response in module scope so subsequent calls in the same SPA
// session don't re-fetch.

export interface DocMeta {
  updatedAt: string | null
  editUrl: string
}

export interface PostMeta {
  updatedAt: string | null
  editUrl: string
}

export interface BuildMeta {
  generatedAt: string
  repo: { url: string; branch: string }
  docs: Record<string, DocMeta>
  posts: Record<string, PostMeta>
}

let cache: Promise<BuildMeta | null> | null = null

export function getBuildMeta(): Promise<BuildMeta | null> {
  if (cache) return cache
  cache = fetch('/build-meta.json', { cache: 'force-cache' })
    .then((response) => (response.ok ? (response.json() as Promise<BuildMeta>) : null))
    .catch(() => null)
  return cache
}

export function formatBuildDate(value: string | null | undefined): string | null {
  if (!value) return null
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return date.toLocaleDateString('en-US', {
    timeZone: 'UTC',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })
}
