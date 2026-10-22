import GithubSlugger from 'github-slugger'

export interface Heading {
  depth: number
  id: string
  text: string
}

const MDX_COMPONENTS = [
  'MacRuntimeDiagram',
  'LinuxRuntimeDiagram',
  'StatsRow',
  'LatencyJourney',
  'TurnPipeline',
  'ArchDiagram',
  'ContextExplorer',
  'TestResults',
] as const

const MDX_IMPORT = /^import\s+(?:[\w*{][^'"]*\s+from\s+)?['"][^'"]+['"];?\s*$/
const FENCE = /^\s*(```|~~~)/

/** Drops MDX `import` statements, leaving imports inside code samples intact. */
export function stripMdxImports(content: string): string {
  let fence: string | null = null
  return content
    .split('\n')
    .filter((line) => {
      const marker = line.match(FENCE)?.[1]
      if (marker) {
        if (fence === null) fence = marker
        else if (fence === marker) fence = null
        return true
      }
      return fence !== null || !MDX_IMPORT.test(line)
    })
    .join('\n')
}

export function prepareMarkdown(content: string): string {
  let prepared = stripMdxImports(content)
    .replace(/\sclient:load/g, '')

  for (const name of MDX_COMPONENTS) {
    prepared = prepared.replace(
      new RegExp(`<${name}\\s*/>`, 'g'),
      `<div data-mdx-component="${name}"></div>`,
    )
  }

  return prepared.trim()
}

export function extractHeadings(content: string): Heading[] {
  const slugs = new GithubSlugger()
  const headings: Heading[] = []
  let fence: string | null = null
  for (const line of content.split('\n')) {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1]
    if (marker) {
      if (!fence) fence = marker
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null
      continue
    }
    if (fence) continue
    const match = line.match(/^(#{1,6})\s+(.+?)(?:\s+#+)?$/)
    if (!match) continue
    const text = stripMarkdown(match[2])
    const id = slugs.slug(text)
    if (match[1].length === 2 || match[1].length === 3) {
      headings.push({ depth: match[1].length, id, text })
    }
  }
  return headings
}

export function stripMarkdown(value: string): string {
  return value
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_~]/g, '')
    .replace(/<[^>]*>/g, '')
    .trim()
}
