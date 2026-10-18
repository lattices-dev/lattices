import navJson from '../data/nav.json'
import { navBlurb, rewriteDocMarkdown } from '../seo/describe'
import { splitFrontmatter } from './frontmatter'
import { extractHeadings, prepareMarkdown, type Heading } from './markdown'

export interface NavItem {
  id: string
  title: string
  description?: string
  href: string
}

export interface NavGroup {
  id: string
  title: string
  items: NavItem[]
}

export interface DocPage {
  slug: string
  title: string
  description?: string
  order: number
  content: string
  headings: Heading[]
}

export interface BlogPost {
  slug: string
  title: string
  description: string
  date: string
  tags: string[]
  author?: string
  draft: boolean
  content: string
  headings: Heading[]
}

const docModules = import.meta.glob<string>('../../../../docs/*.md', {
  query: '?raw',
  import: 'default',
  eager: true,
})

const blogModules = import.meta.glob<string>('../../content/blog/*.{md,mdx}', {
  query: '?raw',
  import: 'default',
  eager: true,
})

export const navGroups: NavGroup[] = navJson.groups.map((group) => ({
  id: group.id,
  title: group.title,
  items: group.items.map((item) => ({
    ...item,
    href: `/docs/${item.id}`,
  })),
}))

export const docs: DocPage[] = Object.entries(docModules)
  .map(([path, raw]) => {
    const slug = slugFromPath(path)
    const { data, content } = splitFrontmatter(raw)
    const prepared = prepareMarkdown(content)
    const explicitTitle = stringValue(data.title)
    const rewritten = rewriteDocMarkdown(prepared, explicitTitle)
    const title = explicitTitle || rewritten.firstH1 || titleFromSlug(slug)

    return {
      slug,
      title,
      description: stringValue(data.description) || navBlurb(slug) || rewritten.summary || undefined,
      order: numberValue(data.order) ?? 999,
      content: rewritten.markdown,
      headings: extractHeadings(rewritten.markdown),
    }
  })
  .sort((left, right) => left.order - right.order || left.title.localeCompare(right.title))

export const blogPosts: BlogPost[] = Object.entries(blogModules)
  .map(([path, raw]) => {
    const slug = slugFromPath(path)
    const { data, content } = splitFrontmatter(raw)
    const prepared = prepareMarkdown(content)

    return {
      slug,
      title: stringValue(data.title) || titleFromSlug(slug),
      description: stringValue(data.description) || '',
      date: stringValue(data.date) || '',
      tags: arrayValue(data.tags),
      author: stringValue(data.author),
      draft: booleanValue(data.draft),
      content: prepared,
      headings: extractHeadings(prepared),
    }
  })
  .filter((post) => !post.draft)
  .sort((left, right) => new Date(right.date).getTime() - new Date(left.date).getTime())

export function getDoc(slug: string): DocPage | undefined {
  return docs.find((doc) => doc.slug === slug)
}

export function getBlogPost(slug: string): BlogPost | undefined {
  return blogPosts.find((post) => post.slug === slug)
}

export function defaultDoc(): DocPage {
  return getDoc('overview') || docs[0]
}

function slugFromPath(path: string): string {
  return path.split('/').pop()?.replace(/\.(md|mdx)$/, '') || ''
}

function titleFromSlug(slug: string): string {
  return slug
    .split('-')
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined
}

function booleanValue(value: unknown): boolean {
  return typeof value === 'boolean' ? value : false
}

function arrayValue(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}
