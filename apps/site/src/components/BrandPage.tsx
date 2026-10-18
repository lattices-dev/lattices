import '../styles/brand.css'
import { Fragment, useId, useState, type ReactNode } from 'react'
import { productLinks } from '../data/products'
import { routeBrand, type BrandSlug } from '../lib/brand'
import { faviconGlyphScale, iconGrid, iconSizes, iconTiles, tilePath } from '../lib/iconGrid'
import { actionMarkBox, latticesAccent, latticesCentres, latticesGrid, latticesPalette, type LatticesCentre } from '../lib/marks'
import { ActionMark } from './ActionMark'
import { BlinkMark } from './blink/BlinkMark'
import { LatticesMark } from './LatticesMark'
import { SiteFooter, SiteHeader } from './SiteChrome'
import { SpeechMark } from './SpeechMark'

type Ground = 'light' | 'dark'

const grounds: readonly Ground[] = ['light', 'dark']

const products = productLinks.map((link) => ({ ...link, slug: routeBrand(link.href).slug }))

/** What each mark draws, what its accent stands for, and its pages' tab title. */
const markNotes: Record<BrandSlug, { meaning: string; accent: string; tab: string }> = {
  lattices: {
    meaning: "The L of a 3 × 3 grid, with Action's cursor in the centre and its tip in the crook of the L: Lattices puts a window where you point.",
    accent: 'The pointer taking aim',
    tab: 'Lattices — the programmable workspace for Mac',
  },
  action: {
    meaning: "An A that fills its square, with the cursor on its diagonal: the tip on the counter's edge, the tail on the square's right and bottom sides.",
    accent: 'The cursor',
    tab: 'Action — computer use from Lattices',
  },
  blink: {
    meaning: 'A panel frame with two blocks stepping across it. The front block, the note in hand, carries the accent.',
    accent: 'The note in hand',
    tab: 'Blink — spatial notes from Lattices',
  },
  speech: {
    meaning: 'Two waveform bars frozen at the playhead: the word just spoken and the one sounding now. Short then tall, they also draw a speaker.',
    accent: 'The word sounding now',
    tab: 'Speech — a standalone player from Lattices',
  },
}

/** Where each app keeps the icon `bun run brand` compiles for it. */
const nativeIcons: Record<BrandSlug, { dir: string; files: readonly string[]; note?: string }> = {
  lattices: { dir: 'assets/', files: ['AppIcon.icon', 'Assets.car', 'AppIcon.icns'] },
  action: { dir: 'products/action/assets/brand/', files: ['Action.icon', 'Assets.car', 'Action.icns', 'action-icon-{512,1024}.png'] },
  blink: { dir: 'products/blink/assets/', files: ['AppIcon.icon', 'Assets.car', 'AppIcon.icns', 'AppIcon.svg'] },
  speech: { dir: 'products/voice/assets/', files: ['AppIcon.icon', 'Assets.car', 'AppIcon.icns'], note: 'bundled into Voice.app' },
}

const repoTree = 'https://github.com/lattices-dev/lattices/tree/main'

const toc = [
  ['marks', 'Marks'],
  ['accent', 'Accent'],
  ['centres', 'Centres'],
  ['icons', 'App icons'],
  ['favicons', 'Favicons'],
  ['open-graph', 'Open Graph'],
  ['colour', 'Colour'],
  ['icon-grid', 'Icon grid'],
  ['files', 'Files'],
] as const

const kit = (slug: BrandSlug, file: string) => `/brand/${slug}/${slug}-${file}`

const iconFile = (ground: Ground) => (ground === 'light' ? 'icon-light' : 'icon')

const percent = (share: number) => `${Math.round(share * 1000) / 10}%`

/** The alpha of an `rgba()` colour as a percentage. */
const alphaPercent = (rgba: string) => Math.round(Number(rgba.slice(rgba.lastIndexOf(',') + 1, -1)) * 100)

/** WCAG contrast between two hex colours, as `n.nn:1`. */
function contrast(a: string, b: string) {
  const luminance = (hex: string) => {
    const [r, g, bl] = [1, 3, 5].map((at) => {
      const c = parseInt(hex.slice(at, at + 2), 16) / 255
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
    })
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return `${((hi + 0.05) / (lo + 0.05)).toFixed(2)}:1`
}

export default function BrandPage() {
  const coral = latticesAccent.light
  const ink = latticesPalette.light.ink

  return (
    <div className="brand-page">
      <SiteHeader />
      <main className="brand-main" data-pagefind-body>
        <header className="brand-intro">
          <h1>Brand</h1>
          <p>Four marks on one grid, with one ink and one accent.</p>
          <nav className="brand-toc" aria-label="On this page">
            <ul>
              {toc.map(([id, title]) => (
                <li key={id}>
                  <a href={`#${id}`}>{title}</a>
                </li>
              ))}
            </ul>
          </nav>
        </header>

        <div className="brand-desks">
          {grounds.map((ground) => (
            <ul key={ground} className="brand-desk" data-ground={ground} aria-label={`App icons, ${ground}`}>
              {products.map(({ slug, title }) => (
                <li key={slug}>
                  <img
                    src={kit(slug, `${iconFile(ground)}-256.png`)}
                    srcSet={`${kit(slug, `${iconFile(ground)}-256.png`)} 1x, ${kit(slug, `${iconFile(ground)}-512.png`)} 2x`}
                    width={152}
                    height={152}
                    alt={`${title} app icon`}
                  />
                  <span aria-hidden="true">{title}</span>
                </li>
              ))}
            </ul>
          ))}
        </div>

        <Section id="marks" title="Marks" lede="Every mark spans the same 16 units of a 20-unit box, so the four line up at any size.">
          <ul className="brand-marks">
            {products.map(({ slug, title }) => (
              <li key={slug} className="brand-card brand-mark-card">
                <div className="brand-mark-grounds">
                  {grounds.map((ground) => (
                    <div key={ground} className="brand-mark-ground" data-ground={ground}>
                      <img src={kit(slug, `${ground}.svg`)} width={80} height={80} alt={`${title} mark for ${ground} grounds`} loading="lazy" />
                    </div>
                  ))}
                </div>
                <div className="brand-mark-body">
                  <h3>{title}</h3>
                  <p>{markNotes[slug].meaning}</p>
                  <FileLinks slug={slug} files={['light.svg', 'dark.svg']} />
                </div>
              </li>
            ))}
          </ul>
        </Section>

        <Section id="accent" title="One accent">
          <div className="brand-accent">
            <div className="brand-swatch" style={{ background: coral, color: ink }}>
              <p className="brand-swatch-name">
                <strong>Coral</strong>
                <code>{coral}</code>
              </p>
              <dl>
                <div>
                  <dt>On white</dt>
                  <dd>{contrast(coral, '#ffffff')}</dd>
                </div>
                <div>
                  <dt>On {ink}</dt>
                  <dd>{contrast(coral, ink)}</dd>
                </div>
              </dl>
              <p>Coral also means live in Action's menu bar.</p>
            </div>
            <ul className="brand-accent-marks">
              {products.map(({ slug, title }) => (
                <li key={slug}>
                  <Mark slug={slug} size={56} />
                  <strong>{title}</strong>
                  <span>{markNotes[slug].accent}</span>
                </li>
              ))}
            </ul>
          </div>
        </Section>

        <Section
          id="centres"
          title="Centres"
          lede={<>The pointer is the Lattices centre. A surface swaps in another with <code>centre</code> only while Lattices does that job there.</>}
        >
          <ul className="brand-accent-marks brand-centres">
            {(Object.keys(latticesCentres) as LatticesCentre[]).map((centre) => (
              <li key={centre}>
                <LatticesMark size={56} centre={centre} />
                <p className="brand-centre-name">
                  <strong>{latticesCentres[centre].name}</strong>
                  <code>{latticesCentres[centre].job}</code>
                </p>
                <span>{latticesCentres[centre].note}</span>
              </li>
            ))}
          </ul>
        </Section>

        <Section id="icons" title="App icons">
          <div className="brand-ladders">
            {grounds.map((ground) => (
              <Ladder key={ground} ground={ground} />
            ))}
          </div>
        </Section>

        <Section id="favicons" title="Favicons">
          <h3 className="brand-sub brand-sub-first">Browser tabs</h3>
          <div className="brand-strips">
            <TabStrip ground="light" active="lattices" />
            <TabStrip ground="dark" active="action" />
          </div>
          <h3 className="brand-sub">Touch icons</h3>
          <ul className="brand-touch">
            {products.map(({ slug, title, href }) => (
              <li key={slug}>
                <img src={routeBrand(href).touchIcon} width={60} height={60} alt={`${title} touch icon`} loading="lazy" />
                <span aria-hidden="true">{title}</span>
              </li>
            ))}
          </ul>
        </Section>

        <Section id="open-graph" title="Open Graph">
          <OpenGraph />
        </Section>

        <Section id="colour" title="Colour">
          <Colours />
        </Section>

        <Section id="icon-grid" title="Icon grid">
          <div className="brand-gridspec">
            <IconGridDiagram />
            <Spec rows={gridSpec} />
          </div>
        </Section>

        <Section
          id="files"
          title="Files"
          lede={
            <>
              Every file is generated from the marks' React components. Edit a component, then run <code>bun run brand</code>.
            </>
          }
        >
          <ul className="brand-kits">
            {products.map(({ slug, title }) => (
              <li key={slug} className="brand-card brand-kit">
                <div className="brand-kit-head">
                  <Mark slug={slug} size={20} />
                  <h3>{title}</h3>
                  <a href={`${repoTree}/apps/site/public/brand/${slug}`} target="_blank" rel="noopener noreferrer">
                    Kit on GitHub <span aria-hidden="true">↗</span>
                  </a>
                </div>
                <dl>
                  <div>
                    <dt>Mark</dt>
                    <dd>
                      <FileLinks slug={slug} files={['light.svg', 'dark.svg', 'light-1024.png', 'dark-1024.png']} />
                    </dd>
                  </div>
                  <div>
                    <dt>App icon</dt>
                    <dd>
                      <FileLinks slug={slug} files={['icon.svg', 'icon-light.svg', 'icon-1024.png', 'icon-light-1024.png']} />
                    </dd>
                  </div>
                  <div>
                    <dt>Web</dt>
                    <dd>
                      <FileLinks slug={slug} files={['favicon.svg', 'touch-icon.png']} />
                    </dd>
                  </div>
                </dl>
              </li>
            ))}
          </ul>

          <h3 className="brand-sub">Pipeline</h3>
          <ol className="brand-flow">
            <li>
              <code>src/components/…Mark.tsx</code>
            </li>
            <li>
              <code>bun run brand [product]</code>
            </li>
            <li>
              <code>public/brand/&lt;product&gt;/</code> and each app's <code>.icon</code>, <code>.icns</code> and <code>Assets.car</code>
            </li>
          </ol>

          <h3 className="brand-sub">In each kit</h3>
          <dl className="brand-tree">
            {kitFiles.map(([patterns, use]) => (
              <div key={patterns[0]}>
                <dt>
                  <CodeList items={patterns} />
                </dt>
                <dd>{use}</dd>
              </div>
            ))}
          </dl>

          <h3 className="brand-sub">In the apps</h3>
          <dl className="brand-tree">
            {products.map(({ slug, title }) => {
              const { dir, files, note } = nativeIcons[slug]
              return (
                <div key={slug}>
                  <dt>
                    <code>{dir}</code>
                  </dt>
                  <dd>
                    {title}: <CodeList items={files} />
                    {note && `, ${note}`}
                  </dd>
                </div>
              )
            })}
          </dl>
        </Section>
      </main>
      <SiteFooter current="/brand" />
    </div>
  )
}

function Section({ id, title, lede, children }: { id: string; title: string; lede?: ReactNode; children: ReactNode }) {
  return (
    <section className="brand-section" id={id} aria-labelledby={`${id}-title`}>
      <header className="brand-section-head">
        <h2 id={`${id}-title`}>{title}</h2>
        {lede && <p>{lede}</p>}
      </header>
      {children}
    </section>
  )
}

/** Each product's live mark, following the page's logo tokens. */
function Mark({ slug, size }: { slug: BrandSlug; size: number }) {
  if (slug === 'action') {
    return (
      <ActionMark
        palette={{ ink: 'currentColor' }}
        guides={false}
        background={false}
        viewBox={actionMarkBox.join(' ')}
        decorative
        style={{ width: size, height: size }}
      />
    )
  }
  if (slug === 'blink') return <BlinkMark width={size} height={size} />
  if (slug === 'speech') return <SpeechMark size={size} />
  return <LatticesMark size={size} />
}

/** File names in code, separated by commas, so a line only breaks between names. */
function CodeList({ items }: { items: readonly string[] }) {
  return items.map((item, index) => (
    <Fragment key={item}>
      {index > 0 && ', '}
      <code>{item}</code>
    </Fragment>
  ))
}

/** Download links that show a kit file's name without its product prefix. */
function FileLinks({ slug, files }: { slug: BrandSlug; files: readonly string[] }) {
  return (
    <ul className="brand-files">
      {files.map((file) => (
        <li key={file}>
          <a href={kit(slug, file)} download>
            <span className="brand-sr">{slug}-</span>
            {file}
          </a>
        </li>
      ))}
    </ul>
  )
}

const ladderSizes = [16, 32, 64, 128] as const

function Ladder({ ground }: { ground: Ground }) {
  const file = iconFile(ground)
  const wide = (size: number) => (size === 128 ? 'brand-x128' : undefined)

  return (
    <div className="brand-ladder" data-ground={ground}>
      <table>
        <caption>{ground === 'light' ? 'Light' : 'Dark'}</caption>
        <thead>
          <tr>
            <th scope="col">
              <span className="brand-sr">Product</span>
            </th>
            {ladderSizes.map((size) => (
              <th key={size} scope="col" className={wide(size)}>
                {size}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {products.map(({ slug, title }) => (
            <tr key={slug}>
              <th scope="row">{title}</th>
              {ladderSizes.map((size) => (
                <td key={size} className={wide(size)}>
                  <img
                    src={kit(slug, `${file}-${size}.png`)}
                    srcSet={`${kit(slug, `${file}-${size}.png`)} 1x, ${kit(slug, `${file}-${size * 2}.png`)} 2x`}
                    width={size}
                    height={size}
                    alt={`${title} icon at ${size} px`}
                    loading="lazy"
                  />
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function TabStrip({ ground, active }: { ground: Ground; active: BrandSlug }) {
  return (
    <div className="brand-tabs" data-ground={ground} role="img" aria-label={`The four favicons in a ${ground} tab strip`}>
      <ul>
        {products.map(({ slug, href }) => (
          <li key={slug} className="brand-tab" data-active={slug === active || undefined}>
            <img src={routeBrand(href).icon} width={16} height={16} alt="" />
            <span>{markNotes[slug].tab}</span>
          </li>
        ))}
      </ul>
      <div className="brand-tabs-bar" />
    </div>
  )
}

const ogSpec = [
  ['Card', '1200 × 630 on a 30 px grid, exported at 2×.'],
  ['Mark', "Cropped to the glyph bounds in its kit's README and fitted to a 120 px box at (120, 120)."],
  ['Copy', 'Title 30 px under the mark, then subtitle and tag, in a 360 px column.'],
  ['Preview', 'From (540, 120) off the right and bottom edges, 660 × 510 visible.'],
  ['Family', 'Action, Blink and Speech only: the Lattices mark and name, 60 px above the bottom edge.'],
  ['Accent', `Each mark keeps its coral. A 4 px bar runs along the bottom edge, ${latticesAccent.light} to #d4502c, on every card.`],
] as const

const ogRoutes = ['/', '/docs', '/action', '/blink', '/speech'] as const

function OpenGraph() {
  const [guides, setGuides] = useState(false)

  return (
    <>
      <div className="brand-og-plan-wrap">
        <OgPlan />
        <Spec rows={ogSpec} />
      </div>
      <div className="brand-og-head">
        <h3 className="brand-sub">Cards</h3>
        <button type="button" className="brand-toggle" aria-pressed={guides} onClick={() => setGuides((on) => !on)}>
          Guides
        </button>
      </div>
      <ul className="brand-og" data-guides={guides || undefined}>
        {ogRoutes.map((route) => {
          const { ogImage, slug } = routeBrand(route)
          return (
            <li key={route}>
              <a className="brand-og-card" href={ogImage} target="_blank" rel="noopener">
                <img src={ogImage} width={1200} height={630} alt={`The social card for ${route}`} loading="lazy" decoding="async" />
                <OgGuides family={slug !== 'lattices'} />
              </a>
              <code>{route}</code>
            </li>
          )
        })}
      </ul>
    </>
  )
}

/** Every 30 px line of the card's grid, drawn as one path so it stays a hairline at any width. */
const planGrid =
  Array.from({ length: 41 }, (_, i) => `M${i * 30} 0V630`).join('') +
  Array.from({ length: 22 }, (_, i) => `M0 ${i * 30}H1200`).join('')

/** The social card's construction, on the card's own 1200 × 630 canvas. */
function OgPlan() {
  const barId = `${useId()}-bar`

  return (
    <svg className="brand-og-plan" viewBox="0 0 1200 630" role="img" aria-label="The social card's construction: a mark box, a copy column and a preview area on a 30 px grid">
      <defs>
        <linearGradient id={barId}>
          <stop offset="0" stopColor={latticesAccent.light} />
          <stop offset="1" stopColor="#d4502c" />
        </linearGradient>
      </defs>
      <path className="brand-plan-cell" d={planGrid} />
      <path className="brand-plan-preview" d="M540 136a16 16 0 0 1 16-16H1200V630H540Z" />
      <path className="brand-plan-guide" d="M0 120H1200M120 0V630" />
      <rect className="brand-plan-box" x="120" y="120" width="120" height="120" />
      <text className="brand-plan-label" x="180" y="192">mark</text>
      <rect className="brand-plan-ink" x="120" y="272" width="220" height="44" rx="6" />
      <rect className="brand-plan-soft" x="120" y="340" width="330" height="15" rx="4" />
      <rect className="brand-plan-soft" x="120" y="366" width="250" height="15" rx="4" />
      <rect className="brand-plan-line" x="120" y="409" width="170" height="31" rx="6" />
      <path className="brand-plan-dim" d="M120 506H480M120 494V518M480 494V518" />
      <text className="brand-plan-label" x="300" y="488">360</text>
      <LatticesMark x={117} y={542} size={30} />
      <rect className="brand-plan-mid" x="156" y="549" width="96" height="17" rx="4" />
      <text className="brand-plan-label brand-plan-note" x="276" y="569">family</text>
      <text className="brand-plan-label" x="870" y="364">preview</text>
      <text className="brand-plan-label" x="870" y="408">660 × 510</text>
      <rect x="0" y="626" width="1200" height="4" fill={`url(#${barId})`} />
    </svg>
  )
}

/** The plan's guides, laid over a finished card. */
function OgGuides({ family }: { family: boolean }) {
  return (
    <svg className="brand-og-lines" viewBox="0 0 1200 630" aria-hidden="true">
      <g className="brand-og-fill">
        <rect x="120" y="120" width="120" height="120" />
        <rect x="540" y="120" width="660" height="510" />
      </g>
      <path className="brand-og-line" d="M0 120H1200M120 0V630M480 120V630M0 270H480" />
      <g className="brand-og-box">
        <rect x="120" y="120" width="120" height="120" />
        <rect x="540" y="120" width="660" height="510" />
        {family && <rect x="120" y="544" width="132" height="26" />}
      </g>
    </svg>
  )
}

interface Swatch {
  name: string
  value: string
  fill: string
  opacity?: number
  ground?: string
  edge?: string
}

function Colours() {
  const { light, dark } = latticesPalette
  const groups: { title: string; swatches: Swatch[] }[] = [
    {
      title: 'Every mark',
      swatches: [
        { name: 'Ink on light', value: light.ink, fill: light.ink },
        { name: 'Ink on dark', value: dark.ink, fill: dark.ink },
        { name: 'Accent, both themes', value: latticesAccent.light, fill: latticesAccent.light },
      ],
    },
    {
      title: 'Every icon',
      swatches: [
        {
          name: 'Light tile',
          value: `${iconTiles.light.fill}, ${alphaPercent(iconTiles.light.edge)}% ink edge`,
          fill: iconTiles.light.fill,
          edge: iconTiles.light.edge,
        },
        {
          name: 'Dark tile',
          value: `${iconTiles.dark.fill}, ${alphaPercent(iconTiles.dark.edge)}% white edge`,
          fill: iconTiles.dark.fill,
          edge: iconTiles.dark.edge,
        },
      ],
    },
    {
      title: 'Lattices',
      swatches: [
        {
          name: 'Dim cells on light',
          value: `${light.dim} at ${Math.round(light.dimOpacity * 100)}%`,
          fill: light.dim,
          opacity: light.dimOpacity,
          ground: iconTiles.light.fill,
        },
        {
          name: 'Dim cells on dark',
          value: `${dark.dim} at ${Math.round(dark.dimOpacity * 100)}%`,
          fill: dark.dim,
          opacity: dark.dimOpacity,
          ground: iconTiles.dark.fill,
        },
      ],
    },
  ]

  return (
    <div className="brand-colours">
      {groups.map(({ title, swatches }) => (
        <div key={title}>
          <h3 className="brand-sub brand-sub-first">{title}</h3>
          <ul className="brand-swatches">
            {swatches.map(({ name, value, fill, opacity, ground, edge }) => (
              <li key={name}>
                <svg viewBox="0 0 28 28" width={28} height={28} aria-hidden="true">
                  {ground && <rect width="28" height="28" rx="7" fill={ground} />}
                  <rect width="28" height="28" rx="7" fill={fill} fillOpacity={opacity} />
                  <rect className="brand-chip-edge" x=".5" y=".5" width="27" height="27" rx="6.5" style={edge ? { stroke: edge } : undefined} />
                </svg>
                <strong>{name}</strong>
                <code>{value}</code>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  )
}

const tileSide = iconGrid.canvas - 2 * iconGrid.inset

const gridSpec = [
  ['Canvas', `${iconGrid.canvas} px`],
  ['Tile', `${tileSide} px, inset ${iconGrid.inset} on every side: white for the light icon, ${iconTiles.dark.fill} for the dark.`],
  ['Corners', `Superellipse quadrants reaching ${percent(iconGrid.cornerRatio)} along each edge, exponent ${iconGrid.exponent}, fitted to the mask macOS 26 draws around system icons.`],
  ['Edge', `A 2 px hairline, ${alphaPercent(iconTiles.light.edge)}% ink on the light tile and ${alphaPercent(iconTiles.dark.edge)}% white on the dark, so each holds its shape on a Dock of its own colour.`],
  ['Glyph', `Longer side ${percent(iconGrid.glyph)} of the tile for every product, centred.`],
  ['Styles', 'Default and Dark take the two tiles. Clear and Tinted draw the glyph in one colour: the accent at full strength, the ink at 70%, the dims at their dark share.'],
  ['Favicon', `The dark tile edge to edge, glyph ${Math.round((faviconGlyphScale - 1) * 100)}% larger, no hairline.`],
  ['Touch icon', '180 px, square, opaque, on the dark tile.'],
  ['Sizes', `${iconSizes.slice(0, -1).join(', ')} and ${iconSizes[iconSizes.length - 1]} px`],
] as const

/** The icon grid measured on the Lattices icon, in the 1024 canvas's units. */
function IconGridDiagram() {
  const { canvas, inset, cornerRatio, glyph } = iconGrid
  const mid = canvas / 2
  const extent = tileSide * glyph
  const markSize = (extent / (latticesGrid.box - 2 * latticesGrid.pad)) * latticesGrid.box
  const round = (value: number) => Math.round(value * 100) / 100
  const glyphStart = round(mid - extent / 2)
  const glyphEnd = round(mid + extent / 2)
  const corner = round(inset + tileSide * cornerRatio)
  const far = canvas - inset

  return (
    <svg className="brand-diagram" viewBox="-70 -96 1164 1196" role="img" aria-label={`The app icon grid: a ${tileSide} px tile inset ${inset} in a ${canvas} px canvas, with the glyph at ${percent(glyph)} of the tile`}>
      <rect className="brand-diagram-canvas" width={canvas} height={canvas} />
      <path className="brand-diagram-tile" d={tilePath(inset, inset, tileSide)} />
      <LatticesMark x={round(mid - markSize / 2)} y={round(mid - markSize / 2)} size={round(markSize)} />
      <path
        className="brand-diagram-dim"
        d={[
          `M0 -40H${canvas}M0 -54V-26M${canvas} -54V-26`,
          `M${inset} 62H${corner}M${inset} 50V74M${corner} 50V${inset}`,
          `M0 ${mid}H${inset}M0 ${mid - 14}V${mid + 14}M${inset} ${mid - 14}V${mid + 14}`,
          `M${glyphStart} 806H${glyphEnd}M${glyphStart} 792V820M${glyphEnd} 792V820`,
          `M${inset} 976H${far}M${inset} 962V990M${far} 962V990`,
        ].join('')}
      />
      <g className="brand-diagram-label">
        <text x={mid} y={-58}>{canvas}</text>
        <text x={round((inset + corner) / 2)} y={44}>{percent(cornerRatio)}</text>
        <text x={inset / 2} y={mid - 20}>{inset}</text>
        <text x={mid} y={862}>{percent(glyph)}</text>
        <text x={mid} y={962}>{tileSide}</text>
      </g>
    </svg>
  )
}

function Spec({ rows }: { rows: readonly (readonly [string, string])[] }) {
  return (
    <dl className="brand-spec">
      {rows.map(([term, detail]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{detail}</dd>
        </div>
      ))}
    </dl>
  )
}

const sizeRange = `{${iconSizes[0]}…${iconSizes[iconSizes.length - 1]}}`

const kitFiles = [
  [['<product>-light.svg', '<product>-dark.svg'], 'Mark for light and for dark grounds'],
  [[`<product>-{light,dark}-${sizeRange}.png`], 'Mark rasters'],
  [['<product>-icon.svg', `<product>-icon-${sizeRange}.png`], 'App icon, dark tile'],
  [['<product>-icon-light.svg', `<product>-icon-light-${sizeRange}.png`], 'App icon, light tile'],
  [['<product>-favicon.svg'], 'Browser tab icon'],
  [['<product>-touch-icon.png'], 'Touch icon, 180 px'],
  [['README.md'], 'Colours, grid and notes'],
] as const
