import { useEffect, useState } from 'react'
import { blogPosts, getBlogPost, type BlogPost } from '../lib/content'
import { formatBuildDate, getBuildMeta, type PostMeta } from '../lib/build-meta'
import { MarkdownRenderer } from './MarkdownRenderer'
import { SiteFooter, SiteHeader } from './SiteChrome'

export function BlogIndex() {
  return (
    <div className="docs-page blog-page">
      <SiteHeader />
      <main className="blog-container" data-pagefind-body>
        <header className="blog-index-head">
          <p className="products-kicker">Lattices blog</p>
          <h1>Notes on workspaces, agents, and the Mac.</h1>
          <p>
            Short posts about what we are building across Lattices, Action, Blink,
            and Speech.
          </p>
        </header>

        <div className="blog-list">
          {blogPosts.map((post) => (
            <a className="blog-post" href={`/blog/${post.slug}`} key={post.slug}>
              <span className="blog-post-date">{formatDate(post.date)}</span>
              <span className="blog-post-copy">
                <span className="blog-post-title">{post.title}</span>
                <span className="blog-post-desc">{post.description}</span>
                <TagList tags={post.tags} />
              </span>
              <span className="blog-post-arrow" aria-hidden="true">→</span>
            </a>
          ))}
        </div>
      </main>
      <SiteFooter current="/blog" />
    </div>
  )
}

export function BlogPostPage({ slug }: { slug: string }) {
  const post = getBlogPost(slug)
  const [meta, setMeta] = useState<PostMeta | null>(null)

  useEffect(() => {
    if (!post) return
    let cancelled = false
    getBuildMeta().then((m) => {
      if (cancelled) return
      setMeta(m?.posts?.[post.slug] ?? null)
    })
    return () => {
      cancelled = true
    }
  }, [post])

  if (!post) {
    return (
      <div className="docs-page blog-page">
        <SiteHeader />
        <main className="not-found-shell" data-pagefind-ignore>
          <div className="not-found-card">
            <p className="not-found-kicker">404</p>
            <h1 className="not-found-title">Post not found</h1>
            <p className="not-found-desc">
              The post may have been moved or unpublished.{' '}
              <a href="/blog">Browse the blog →</a>
            </p>
          </div>
        </main>
        <SiteFooter />
      </div>
    )
  }

  const index = blogPosts.findIndex((p) => p.slug === post.slug)
  const newer = index > 0 ? blogPosts[index - 1] : null // blogPosts sorted newest first
  const older = index >= 0 && index < blogPosts.length - 1 ? blogPosts[index + 1] : null
  const updatedLabel = formatBuildDate(meta?.updatedAt)
  const showUpdated = updatedLabel && updatedLabel !== formatDate(post.date)

  return (
    <div className="docs-page blog-page">
      <SiteHeader />
      <article className="post-container" data-pagefind-body>
        <a href="/blog" className="post-back">← all posts</a>
        <header className="post-header">
          <p className="products-kicker">Lattices blog</p>
          <h1 className="post-title">{post.title}</h1>
          {post.description && <p className="post-dek">{post.description}</p>}
          <div className="post-meta">
            {post.author && <span>{post.author} · </span>}
            {formatDate(post.date)}
            {showUpdated && <span> · updated {updatedLabel}</span>}
            {meta?.editUrl && (
              <a
                href={meta.editUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="post-edit-link"
              >
                Edit on GitHub →
              </a>
            )}
            <TagList tags={post.tags} />
          </div>
        </header>
        <MarkdownRenderer content={post.content} className="prose" />
        <nav className="post-nav-pager" aria-label="More posts">
          {newer ? (
            <a className="post-pager post-pager-prev" href={`/blog/${newer.slug}`}>
              <span className="post-pager-label">Newer</span>
              <strong>{newer.title}</strong>
            </a>
          ) : (
            <span />
          )}
          {older ? (
            <a className="post-pager post-pager-next" href={`/blog/${older.slug}`}>
              <span className="post-pager-label">Older</span>
              <strong>{older.title}</strong>
            </a>
          ) : (
            <span />
          )}
        </nav>
      </article>
      <SiteFooter />
    </div>
  )
}

function TagList({ tags }: { tags: BlogPost['tags'] }) {
  if (tags.length === 0) return null

  return (
    <span className="post-tags">
      {tags.map((tag) => (
        <span className="post-tag" key={tag}>{tag}</span>
      ))}
    </span>
  )
}

function formatDate(value: string): string {
  return new Date(value).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })
}
