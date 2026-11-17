import { lazy, Suspense, useEffect, useState } from 'react'
import { accessPaths } from '../lib/access-paths'
import { SiteFooter, SiteHeader } from './SiteChrome'
import { EmailAccess } from './EmailAccess'

// The emitted study chunk is moved out of the public build by package-access.
const Study = lazy(() => import('./ConceptExperimentPage'))
export default function StudyAccess() {
  const [unlocked, setUnlocked] = useState(false)
  useEffect(() => {
    const controller = new AbortController()
    fetch(accessPaths.session, { cache: 'no-store', signal: controller.signal })
      .then((response) => response.ok ? response.json() : null)
      .then((session) => { if (session?.unlocked) setUnlocked(true) })
      .catch(() => {})
    return () => controller.abort()
  }, [])
  if (unlocked) return <Suspense fallback={<p className="not-found-shell" role="status">Opening study…</p>}><Study /></Suspense>
  return <div className="docs-page"><SiteHeader /><main className="not-found-shell"><article className="docs-article"><header className="docs-article-header"><h1>Lattices studies</h1><p>Explore the ideas and interaction experiments behind Lattices.</p></header><EmailAccess onUnlock={() => setUnlocked(true)} /></article></main><SiteFooter /></div>
}
