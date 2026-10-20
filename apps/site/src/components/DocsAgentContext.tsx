import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { docs, type DocPage } from '../lib/content'
import { docRawUrl, docsProduct, isCurrentDoc, productAgentUrls, type ProductId } from '../lib/docs-catalog'

type Scope = 'page' | 'product'

const scopeKey = 'lattices.docs.agentScope'

function readScope(): Scope {
  try {
    return localStorage.getItem(scopeKey) === 'product' ? 'product' : 'page'
  } catch {
    return 'page'
  }
}

function writeScope(scope: Scope) {
  try {
    localStorage.setItem(scopeKey, scope)
  } catch {
    // Private windows may refuse storage; the default scope still works.
  }
}

const absolute = (path: string) => (typeof window === 'undefined' ? `https://lattices.dev${path}` : new URL(path, window.location.origin).href)
const tokens = (chars: number) => {
  const n = Math.round(chars / 4)
  return n >= 1000 ? `≈${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k tokens` : `≈${n} tokens`
}

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    const area = document.createElement('textarea')
    area.value = text
    area.setAttribute('readonly', '')
    area.style.position = 'fixed'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    const ok = document.execCommand('copy')
    area.remove()
    return ok
  }
}

/** Fetch the Markdown artifact the build publishes; fall back to the bundled source in dev. */
async function fetchMarkdown(url: string, fallback: () => string) {
  try {
    const response = await fetch(url, { headers: { Accept: 'text/markdown, text/plain' } })
    const type = response.headers.get('content-type') || ''
    if (response.ok && !type.includes('text/html')) return await response.text()
  } catch {
    // Offline or dev server without built artifacts.
  }
  return fallback()
}

const withTitle = (doc: DocPage) => (/^#\s/.test(doc.content.trimStart()) ? doc.content : `# ${doc.title}\n\n${doc.content}`)

export function DocsAgentContext({ doc, product }: { doc: DocPage; product: ProductId }) {
  const [open, setOpen] = useState(false)
  const [scope, setScope] = useState<Scope>(readScope)
  const [status, setStatus] = useState('')
  const panelId = useId()
  const triggerRef = useRef<HTMLButtonElement>(null)
  const meta = docsProduct(product)
  const urls = productAgentUrls(product)
  const current = isCurrentDoc(doc)

  const productDocs = useMemo(() => docs.filter((entry) => entry.product === product && entry.agent && isCurrentDoc(entry)), [product])
  const productChars = useMemo(() => productDocs.reduce((sum, entry) => sum + entry.content.length, 0), [productDocs])
  const guide = productDocs.find((entry) => entry.canonicalPath === meta.agent.guide)

  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onPointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('pointerdown', onPointer)
    return () => document.removeEventListener('pointerdown', onPointer)
  }, [open])

  const choose = (next: Scope) => {
    setScope(next)
    setStatus('')
    writeScope(next)
  }

  const close = () => {
    setOpen(false)
    triggerRef.current?.focus()
  }

  const target = scope === 'page'
    ? { label: `${doc.title} page`, url: docRawUrl(doc) }
    : { label: `${meta.title} docs`, url: urls.full }

  const prompt = () => [
    scope === 'page'
      ? `Read the ${meta.title} documentation page "${doc.title}" as Markdown: ${absolute(docRawUrl(doc))}`
      : `Read the current ${meta.title} documentation. Index: ${absolute(urls.index)} Full text: ${absolute(urls.full)}`,
    !current && scope === 'page'
      ? `This page is an archived ${doc.kind}. Treat it as history, not as current behavior. Current docs: ${absolute(urls.index)}`
      : '',
    `Scope: ${meta.agent.boundary}`,
    `Before you change anything, run the read-only check \`${meta.agent.firstCheck}\`. Expect: ${meta.agent.expect}`,
    `Agent guide: ${absolute(meta.agent.guide)}`,
    'Task: ',
  ].filter(Boolean).join('\n\n')

  const copyMarkdown = async () => {
    setStatus('Copying…')
    const text = scope === 'page'
      ? await fetchMarkdown(docRawUrl(doc), () => withTitle(doc))
      : await fetchMarkdown(urls.full, () => productDocs.map(withTitle).join('\n\n---\n\n'))
    const ok = await copyText(text)
    setStatus(ok ? `Copied ${target.label} as Markdown (${tokens(text.length)}).` : 'Copy failed. Open the Markdown link and copy it from there.')
  }

  const copyPrompt = async () => {
    const ok = await copyText(prompt())
    setStatus(ok ? `Copied a prompt that links the ${target.label}. Add your task at the end.` : 'Copy failed. Open the Markdown link instead.')
  }

  return (
    <div ref={rootRef} className="agent-context" onKeyDown={(event) => { if (event.key === 'Escape' && open) close() }}>
      <button
        ref={triggerRef}
        type="button"
        className="agent-context-trigger"
        aria-expanded={open}
        aria-controls={panelId}
        onClick={() => setOpen((value) => !value)}
      >
        <svg aria-hidden="true" viewBox="0 0 16 16" width="14" height="14"><path d="M5 3.5 1.5 8 5 12.5M11 3.5 14.5 8 11 12.5" /></svg>
        Use with an agent
      </button>
      <section id={panelId} className="agent-context-panel" hidden={!open} aria-label={`Give ${meta.title} documentation to an agent`}>
        <fieldset className="agent-context-scope">
          <legend>Context</legend>
          <label>
            <input type="radio" name={`${panelId}-scope`} value="page" checked={scope === 'page'} onChange={() => choose('page')} />
            <span>
              <strong>This page</strong>
              <small>{doc.title} · {tokens(doc.content.length)}{!current && ' · archived'}</small>
            </span>
          </label>
          <label>
            <input type="radio" name={`${panelId}-scope`} value="product" checked={scope === 'product'} onChange={() => choose('product')} />
            <span>
              <strong>{meta.title} docs</strong>
              <small>{productDocs.length} current pages · {tokens(productChars)}</small>
            </span>
          </label>
        </fieldset>

        <div className="agent-context-actions">
          <button type="button" onClick={copyMarkdown}>Copy Markdown</button>
          <button type="button" onClick={copyPrompt}>Copy prompt</button>
          <a href={target.url} target="_blank" rel="noopener noreferrer">
            Open <code>{target.url.split('/').pop()}</code>
          </a>
        </div>

        <dl className="agent-context-start">
          <div>
            <dt>First check</dt>
            <dd><code>{meta.agent.firstCheck}</code> <span>read-only</span></dd>
          </div>
          <div>
            <dt>Agent guide</dt>
            <dd><a href={meta.agent.guide}>{guide?.title ?? 'For agents'}</a> · <a href={urls.index}>llms.txt</a> · <a href={urls.json}>JSON</a></dd>
          </div>
        </dl>
        <p className="agent-context-note">{scope === 'product'
          ? `Includes ${meta.title}'s current guides. Archived proposals and other products are excluded.`
          : current
            ? `Includes this ${meta.title} page. Choose ${meta.title} docs for all current guides.`
            : 'Includes this archived page. Use it as historical context; choose the product docs for current guidance.'}</p>
        <p className="agent-context-status" role="status" aria-live="polite">{status}</p>
      </section>
    </div>
  )
}
