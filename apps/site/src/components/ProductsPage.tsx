import type { ReactNode } from 'react'
import { actionMarkBox } from '../lib/marks'
import { ActionMark } from './ActionMark'
import { BlinkMark } from './blink/BlinkMark'
import { LatticesMark } from './LatticesMark'
import { SiteFooter, SiteHeader } from './SiteChrome'
import { SpeechMark } from './SpeechMark'
import '../styles/products.css'

interface FamilyProduct {
  id: string
  name: string
  href: string
  docs: string
  platform: string
  label: string
  lede: string
  owns: string[]
  mark: ReactNode
  specimen: ReactNode
}

/*
 * Specimens: one ink, one coral accent, on the marks' grid language. They show
 * what each app is for, not how it is built. All are decorative.
 */
function Screen({ children }: { children: ReactNode }) {
  return (
    <svg className="pf-specimen-art" viewBox="0 0 320 208" aria-hidden="true" focusable="false">
      <rect className="pf-s-frame" x="0.5" y="0.5" width="319" height="207" rx="10" />
      <path className="pf-s-rule" d="M0.5 20.5H319.5" />
      <circle className="pf-s-dot" cx="13" cy="10.5" r="2.5" />
      <circle className="pf-s-dot" cx="22" cy="10.5" r="2.5" />
      <circle className="pf-s-dot" cx="31" cy="10.5" r="2.5" />
      {children}
    </svg>
  )
}

const latticesSpecimen = (
  <Screen>
    <rect className="pf-s-pane is-active" x="10" y="30" width="146" height="168" rx="5" />
    <path className="pf-s-line is-accent" d="M22 48h36" />
    <path className="pf-s-line" d="M22 62h88M22 76h64M22 90h100M22 104h52" />
    <path className="pf-s-caret" d="M22 118h7" />
    <rect className="pf-s-pane" x="164" y="30" width="146" height="80" rx="5" />
    <path className="pf-s-line" d="M176 50h70M176 64h96M176 78h52" />
    <rect className="pf-s-pane" x="164" y="118" width="69" height="80" rx="5" />
    <rect className="pf-s-pane" x="241" y="118" width="69" height="80" rx="5" />
    <path className="pf-s-line" d="M176 138h40M176 152h28M253 138h40M253 152h32" />
  </Screen>
)

const actionSpecimen = (
  <Screen>
    <path className="pf-s-line" d="M22 44h92M22 58h132" />
    <rect className="pf-s-pane" x="22" y="78" width="276" height="26" rx="5" />
    <path className="pf-s-line" d="M34 91h120" />
    <rect className="pf-s-pane" x="22" y="114" width="276" height="26" rx="5" />
    <rect className="pf-s-target" x="198" y="156" width="100" height="30" rx="6" />
    <rect className="pf-s-button" x="204" y="162" width="88" height="18" rx="4" />
    <path className="pf-s-cursor" d="M236 168l0 26 7-7 5 11 5-2-5-11 10 0z" />
    <circle className="pf-s-rec" cx="290" cy="34" r="4" />
    <path className="pf-s-line" d="M262 34h18" />
  </Screen>
)

const blinkSpecimen = (
  <svg className="pf-specimen-art" viewBox="0 0 320 208" aria-hidden="true" focusable="false">
    <rect className="pf-s-desk" x="0.5" y="0.5" width="319" height="207" rx="10" />
    <g className="pf-s-note">
      <rect x="26" y="26" width="118" height="92" rx="7" />
      <path className="pf-s-line" d="M40 46h52M40 62h88M40 76h70M40 90h80" />
    </g>
    <g className="pf-s-note">
      <rect x="214" y="22" width="84" height="66" rx="7" />
      <path className="pf-s-line" d="M228 40h38M228 54h56M228 68h44" />
    </g>
    <g className="pf-s-note is-front">
      <rect x="122" y="92" width="132" height="92" rx="7" />
      <path className="pf-s-line is-accent" d="M136 112h44" />
      <path className="pf-s-line" d="M136 128h100M136 142h78M136 156h92" />
    </g>
  </svg>
)

const speechBars = [10, 18, 26, 14, 34, 22, 40, 28, 16, 30, 44, 24, 12, 20, 32, 18, 26, 10, 22, 14, 8, 12]

const speechSpecimen = (
  <svg className="pf-specimen-art" viewBox="0 0 320 208" aria-hidden="true" focusable="false">
    <rect className="pf-s-frame" x="0.5" y="0.5" width="319" height="207" rx="10" />
    <g>
      {speechBars.map((height, index) => (
        <rect
          key={index}
          className={index === 10 ? 'pf-s-bar is-accent' : index < 10 ? 'pf-s-bar is-played' : 'pf-s-bar'}
          x={28 + index * 12}
          y={58 - height / 2}
          width="6"
          height={height}
          rx="3"
        />
      ))}
    </g>
    <path className="pf-s-rule" d="M20 96.5H300" />
    <g className="pf-s-queue">
      <rect className="pf-s-pane is-active" x="20" y="108" width="280" height="24" rx="5" />
      <path className="pf-s-line is-accent" d="M32 120h10" />
      <path className="pf-s-line" d="M52 120h150" />
      <path className="pf-s-line" d="M32 148h10M52 148h120M32 172h10M52 172h176" />
    </g>
  </svg>
)

const products: FamilyProduct[] = [
  {
    id: 'lattices',
    name: 'Lattices',
    href: '/',
    docs: '/lattices/docs',
    platform: 'macOS · Linux',
    label: 'Windows and sessions',
    lede: 'The programmable workspace. Tile windows, switch workspace layers, keep terminal sessions running, and give spoken commands.',
    owns: ['Windows and tiling', 'Spaces and layers', 'tmux sessions', 'Screen text search', 'Voice input'],
    mark: <LatticesMark size={28} />,
    specimen: latticesSpecimen,
  },
  {
    id: 'action',
    name: 'Action',
    href: '/action',
    docs: '/action/docs',
    platform: 'macOS',
    label: 'App and browser control',
    lede: 'Record, review, and drive computer use. Agents observe and operate native apps and Action-owned browsers, and you keep the recording.',
    owns: ['Native app control', 'Action-owned browsers', 'Recording and review', 'Private agent layers'],
    mark: (
      <ActionMark
        palette={{ ink: 'currentColor' }}
        guides={false}
        background={false}
        viewBox={actionMarkBox.join(' ')}
        decorative
        style={{ width: 28, height: 28 }}
      />
    ),
    specimen: actionSpecimen,
  },
  {
    id: 'canvas',
    name: 'Canvas',
    href: '/canvas',
    docs: '/canvas/docs',
    platform: 'macOS · formerly Blink',
    label: 'Spatial notes',
    lede: 'Spatial notes that live on your desktop. Each note is a Markdown file in its own floating panel, placed where you work and kept in named desks.',
    owns: ['Floating note panels', 'Markdown files', 'Placement', 'Named desks'],
    mark: <BlinkMark width={28} height={28} />,
    specimen: blinkSpecimen,
  },
  {
    id: 'speech',
    name: 'Speech',
    href: '/speech',
    docs: '/speech/docs',
    platform: 'macOS menu bar',
    label: 'Spoken output',
    lede: 'A standalone player for queued text. Agents and scripts queue the words; Speech picks the voice and plays them while you keep working.',
    owns: ['The speech queue', 'Voices', 'Playback controls'],
    mark: <SpeechMark size={28} />,
    specimen: speechSpecimen,
  },
]

export default function ProductsPage() {
  return (
    <div className="docs-page products-page">
      <SiteHeader />
      <main className="pf" data-pagefind-body>
        <header className="pf-head">
          <h1>Products</h1>
          <p className="pf-intro">
            Lattices manages windows, workspaces, and terminal sessions. Action observes and controls apps and browsers. Canvas keeps spatial notes on your desktop. Speech plays queued text aloud. Each runs as its own app and has its own docs.
          </p>
          <nav className="pf-index" aria-label="Jump to a product">
            {products.map((product) => (
              <a key={product.id} href={`#${product.id}`} className="pf-index-link">
                <span className="pf-index-mark" aria-hidden="true">{product.mark}</span>
                <span className="pf-index-name">{product.name}</span>
                <span className="pf-index-tag">{product.label}</span>
              </a>
            ))}
          </nav>
        </header>

        <div className="pf-list">
          {products.map((product) => (
            <article className="pf-product" id={product.id} key={product.id} aria-labelledby={`${product.id}-title`}>
              <div className="pf-specimen">{product.specimen}</div>
              <div className="pf-body">
                <p className="pf-meta">
                  <span>{product.label}</span>
                  <span aria-hidden="true">·</span>
                  <span>{product.platform}</span>
                </p>
                <h2 id={`${product.id}-title`} className="pf-name">
                  <span className="pf-name-mark" aria-hidden="true">{product.mark}</span>
                  {product.name}
                </h2>
                <p className="pf-lede">{product.lede}</p>
                <ul className="pf-owns" aria-label={`${product.name} covers`}>
                  {product.owns.map((item) => <li key={item}>{item}</li>)}
                </ul>
                <div className="pf-links">
                  <a className="pf-link is-primary" href={product.href}>
                    Explore {product.name}
                    <span className="pf-arrow" aria-hidden="true">→</span>
                  </a>
                  <a className="pf-link" href={product.docs}>
                    {product.name} docs
                    <span className="pf-arrow" aria-hidden="true">→</span>
                  </a>
                </div>
              </div>
            </article>
          ))}
        </div>

        <aside className="pf-runtime" aria-labelledby="pf-runtime-title">
          <h2 id="pf-runtime-title">Runtimes</h2>
          <p>
            Each product starts and stops as its own app. The shared <code>lats</code> CLI and MCP launcher connect to them; they are interfaces, not another product or a single runtime.
          </p>
          <a className="pf-link" href="/lattices/docs/concepts">
            Runtime boundaries
            <span className="pf-arrow" aria-hidden="true">→</span>
          </a>
        </aside>
      </main>
      <SiteFooter current="/products" />
    </div>
  )
}
