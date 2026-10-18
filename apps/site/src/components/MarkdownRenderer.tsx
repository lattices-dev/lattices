import { isValidElement, useEffect, useState, type ReactNode } from 'react'
import ReactMarkdown, { type Components } from 'react-markdown'
import rehypeRaw from 'rehype-raw'
import rehypeSlug from 'rehype-slug'
import remarkGfm from 'remark-gfm'
import { highlightCode } from '../lib/highlight'
import ArchDiagram from './blog/ArchDiagram'
import ContextExplorer from './blog/ContextExplorer'
import LatencyJourney from './blog/LatencyJourney'
import StatsRow from './blog/StatsRow'
import TestResults from './blog/TestResults'
import TurnPipeline from './blog/TurnPipeline'

const embeddedComponents = {
  ArchDiagram,
  ContextExplorer,
  LatencyJourney,
  StatsRow,
  TestResults,
  TurnPipeline,
}

const components: Components = {
  h1({ node, children, ...props }) {
    void node
    return <h2 {...props}>{children}</h2>
  },
  a({ href, children, ...props }) {
    const external = href?.startsWith('http')
    return (
      <a
        href={href}
        target={external ? '_blank' : undefined}
        rel={external ? 'noreferrer' : undefined}
        {...props}
      >
        {children}
      </a>
    )
  },
  div(props) {
    const componentName = (props as Record<string, unknown>)['data-mdx-component']

    if (typeof componentName === 'string' && componentName in embeddedComponents) {
      const Embedded = embeddedComponents[componentName as keyof typeof embeddedComponents]
      return <Embedded />
    }

    return <div {...props} />
  },
  img(props) {
    return <img loading="lazy" {...props} />
  },
  pre({ children, ...props }) {
    return <CodeBlock {...props}>{children}</CodeBlock>
  },
}

interface MarkdownRendererProps {
  content: string
  className?: string
}

export function MarkdownRenderer({ content, className = 'markdown-body' }: MarkdownRendererProps) {
  return (
    <div className={className}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeRaw, rehypeSlug]}
        components={components}
      >
        {content}
      </ReactMarkdown>
    </div>
  )
}

function CodeBlock({ children, ...props }: { children?: ReactNode }) {
  const [copied, setCopied] = useState(false)
  const [highlighted, setHighlighted] = useState<{ key: string; html: string } | null>(null)
  const code = extractText(children).replace(/\n$/, '')
  const language = extractLanguage(children)
  const highlightKey = `${language || 'text'}:${code}`
  const highlightedHtml = highlighted?.key === highlightKey ? highlighted.html : null

  useEffect(() => {
    let cancelled = false

    highlightCode(code, language)
      .then((html) => {
        if (!cancelled) setHighlighted({ key: highlightKey, html })
      })
      .catch(() => {
        if (!cancelled) setHighlighted(null)
      })

    return () => {
      cancelled = true
    }
  }, [code, highlightKey, language])

  const copy = async () => {
    if (!code) return
    await copyText(code)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1400)
  }

  return (
    <div className="code-block">
      <button
        type="button"
        className="code-copy-button"
        onClick={copy}
        aria-label={copied ? 'Copied code' : 'Copy code'}
        data-pagefind-ignore
      >
        {copied ? 'Copied' : 'Copy'}
      </button>
      {highlightedHtml ? (
        <div className="shiki-code" dangerouslySetInnerHTML={{ __html: highlightedHtml }} />
      ) : (
        <pre {...props}>{children}</pre>
      )}
    </div>
  )
}

function extractText(node: ReactNode): string {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(extractText).join('')
  if (isValidElement<{ children?: ReactNode }>(node)) return extractText(node.props.children)
  return ''
}

function extractLanguage(node: ReactNode): string | undefined {
  if (Array.isArray(node)) {
    return node.map(extractLanguage).find(Boolean)
  }

  if (!isValidElement<{ className?: string; children?: ReactNode }>(node)) return undefined

  const className = node.props.className
  const match = className?.match(/language-([A-Za-z0-9_-]+)/)
  return match?.[1] || extractLanguage(node.props.children)
}

async function copyText(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value)
      return
    } catch {
      // Fall through for browsers that expose Clipboard API but deny writes.
    }
  }

  const textarea = document.createElement('textarea')
  textarea.value = value
  textarea.setAttribute('readonly', '')
  textarea.style.position = 'fixed'
  textarea.style.top = '-9999px'
  document.body.appendChild(textarea)
  textarea.select()
  document.execCommand('copy')
  textarea.remove()
}
