import { type DocEntry, type ProductId } from './docs-catalog'
import publicDocs from '../.generated/docs.public.json'
import { splitFrontmatter } from './frontmatter'
import { extractHeadings, prepareMarkdown, type Heading } from './markdown'

export interface DocPage extends DocEntry {
  title: string
  description?: string
  order: number
  content: string
  headings: Heading[]
  gated: boolean
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

const blogModules = import.meta.glob<string>('../../content/blog/*.{md,mdx}', {
  query: '?raw',
  import: 'default',
  eager: true,
})

export const docs = publicDocs as DocPage[]

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

export function getDoc(slug: string, product: ProductId = 'lattices'): DocPage | undefined {
  return docs.find((doc) => doc.slug === slug && doc.product === product)
}

export function getBlogPost(slug: string): BlogPost | undefined {
  return blogPosts.find((post) => post.slug === slug)
}

export function defaultDoc(product: ProductId = 'lattices'): DocPage {
  return getDoc('overview', product)!
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

function booleanValue(value: unknown): boolean {
  return typeof value === 'boolean' ? value : false
}

function arrayValue(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}
