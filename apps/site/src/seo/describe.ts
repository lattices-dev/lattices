import navJson from '../data/nav.json'

/** Collapse a description to a single line that fits a search snippet. */
export function clampMeta(text: string, max = 155): string {
  const clean = text.replace(/\s+/g, ' ').trim()
  if (clean.length <= max) return clean
  const cut = clean.slice(0, max)
  const space = cut.lastIndexOf(' ')
  const trimmed = (space > 80 ? cut.slice(0, space) : cut).replace(/[.,;:]+$/, '')
  return `${trimmed}…`
}

export function navBlurb(slug: string): string | undefined {
  for (const group of navJson.groups) {
    for (const item of group.items) {
      if (item.id === slug && item.description) return item.description
    }
  }
  return undefined
}

export interface RewrittenDoc {
  /** First markdown h1, when the page did not already name itself. */
  firstH1?: string
  /** Body with the page title removed and any other h1 demoted to h2. */
  markdown: string
  /** First prose paragraph, clamped for a meta description. */
  summary: string
}

/**
 * The docs shell already renders one h1. Drop a matching markdown h1, and
 * demote any other h1 so the exported page has a single heading at that level.
 */
export function rewriteDocMarkdown(markdown: string, pageTitle?: string): RewrittenDoc {
  const lines = markdown.replace(/\r\n/g, '\n').split('\n')
  const out: string[] = []
  let inFence = false
  let seenH1 = false
  let firstH1: string | undefined

  for (const line of lines) {
    if (line.startsWith('```')) {
      inFence = !inFence
      out.push(line)
      continue
    }
    if (inFence) {
      out.push(line)
      continue
    }

    const heading = line.match(/^#\s+(.+?)\s*$/)
    if (!heading) {
      out.push(line)
      continue
    }

    const text = heading[1].replace(/\s+#+$/, '').trim()
    if (!seenH1) {
      seenH1 = true
      firstH1 = text
      if (!pageTitle || sameTitle(text, pageTitle)) continue
    }
    out.push(`## ${text}`)
  }

  const body = out.join('\n').replace(/\n{3,}/g, '\n\n').trim()
  return {
    firstH1,
    markdown: body,
    summary: clampMeta(firstProse(body)),
  }
}

function sameTitle(left: string, right: string): boolean {
  return normalize(left) === normalize(right)
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
}

function firstProse(markdown: string): string {
  const lines = markdown.split('\n')
  const paragraphs: string[] = []
  let buf: string[] = []
  let inFence = false

  const flush = () => {
    if (buf.length === 0) return
    paragraphs.push(cleanProse(buf.join(' ')))
    buf = []
  }

  for (const line of lines) {
    if (line.startsWith('```')) {
      inFence = !inFence
      flush()
      continue
    }
    if (inFence) continue
    if (!line.trim()) {
      flush()
      continue
    }
    if (/^#{1,6}\s/.test(line) || line.startsWith('|') || line.startsWith('<')) {
      flush()
      continue
    }
    buf.push(line.trim())
  }
  flush()

  const chosen = paragraphs.find((paragraph) => paragraph.length >= 40) || paragraphs[0] || ''
  return chosen.replace(/:\s*$/, '')
}

function cleanProse(value: string): string {
  return value
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_`]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}
