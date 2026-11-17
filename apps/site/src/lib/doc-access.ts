/** Public introductions are build-time excerpts, never a client-side blur. */
export function publicDocContent(content: string, entry: { slug: string; kind?: string }) {
  if (['overview', 'install', 'install-linux', 'installation'].includes(entry.slug)) {
    return { content, gated: false }
  }
  // Keep a useful first-run path public; deeper setup remains behind the cutoff.
  const sectionLimit = entry.slug === 'quickstart' ? 4 : 0
  let fence = ''
  let sections = 0
  const lines = content.split('\n')
  let cutoff = lines.length
  for (let index = 0; index < lines.length; index++) {
    const marker = lines[index].match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = ''
      continue
    }
    if (!fence && /^##\s/.test(lines[index]) && sections++ >= sectionLimit) {
      cutoff = index
      break
    }
  }
  // Documents without sections still need a bounded introduction.
  let excerpt = lines.slice(0, cutoff).join('\n').trim()
  if (sectionLimit === 0 && excerpt.length > 1600) {
    excerpt = excerpt.split(/\n\s*\n/).find((paragraph) => paragraph.trim() && !paragraph.startsWith('#')) || ''
  }
  return { content: excerpt, gated: excerpt !== content.trim() }
}
