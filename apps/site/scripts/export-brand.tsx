/**
 * Exports each product's brand kit from its React mark.
 *
 *   bun scripts/export-brand.tsx               # every product
 *   bun scripts/export-brand.tsx blink speech  # just these
 *
 * Writes public/brand/<product>/ and each native app's icon: an Icon Composer
 * document with light and dark appearances, and on macOS the Assets.car that
 * actool compiles from it and the .icns fallback. The mark components are the
 * source of truth. Everything here is generated and committed, so the site and
 * the app builds stay offline.
 */
import { createElement as h, type ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import sharp from 'sharp'
import { execFileSync } from 'node:child_process'
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compileAssetCatalogIfNeeded } from './asset-catalog'
import { ActionMark } from '../src/components/ActionMark'
import { BlinkMark } from '../src/components/blink/BlinkMark'
import { LatticesMark } from '../src/components/LatticesMark'
import { SpeechMark } from '../src/components/SpeechMark'
import { faviconGlyphScale, iconGrid as grid, iconSizes as ladder, iconTiles as tiles, tilePath } from '../src/lib/iconGrid'
import { actionMarkBox, latticesAccent, latticesPalette } from '../src/lib/marks'

type Theme = 'light' | 'dark'
type Box = { x: number; y: number; width: number; height: number }

const siteDir = fileURLToPath(new URL('..', import.meta.url))
const repoRoot = join(siteDir, '..', '..')
const brandDir = join(siteDir, 'public', 'brand')
const themes = ['light', 'dark'] as const

type Paint = { color: string; opacity?: number }
type Role = 'accent' | 'ink' | 'dim'

/** One colour role of a mark, as an Icon Composer layer. */
interface Layer {
  name: Role
  /** The role's shapes in black, with every other role unpainted. */
  mark: (box: Box) => ReactElement
  /** The document fills the shapes with this, per appearance. */
  paint: Record<Theme, Paint>
}

interface Product {
  slug: string
  name: string
  source: string
  viewBox: readonly [number, number, number, number]
  /** The mark alone, baked for a light or dark background. */
  mark: (theme: Theme) => ReactElement
  /** The mark as it sits on the icon tile of the same theme. */
  iconMark: (theme: Theme, box?: Box) => ReactElement
  /** The mark split by colour role for the Icon Composer document, top layer first. */
  layers: Layer[]
  /**
   * The native app's icon, in a repo-relative folder: `<name>.icns`, the
   * `<name>.icon` Icon Composer document and the `Assets.car` compiled from it.
   * The name is the app's `CFBundleIconName` and `CFBundleIconFile`.
   */
  app: { dir: string; name: string; minimumSystem: string }
  /** Extra flat icon PNGs some product folders keep beside their .icns. */
  iconPngs?: { dir: string; sizes: number[] }
  /** A repo-relative copy of the icon SVG, for product folders that keep the vector beside their .icns. */
  iconSvg?: string
  colours: Array<[string, string]>
  notes: string[]
}

const actionKitProps = { guides: false, background: false, viewBox: actionMarkBox.join(' ') } as const

const themed = (colors: Record<Theme, string>, opacity?: Record<Theme, number>): Record<Theme, Paint> => ({
  light: { color: colors.light, opacity: opacity?.light },
  dark: { color: colors.dark, opacity: opacity?.dark },
})
const ink = themed({ light: latticesPalette.light.ink, dark: latticesPalette.dark.ink })
const dim = themed(
  { light: latticesPalette.light.dim, dark: latticesPalette.dark.dim },
  { light: latticesPalette.light.dimOpacity, dark: latticesPalette.dark.dimOpacity },
)

/**
 * Splits a mark into one layer per colour role. `draw` renders the mark with
 * each role painted as given; every layer paints its own role black and the
 * rest `none`, so each is a mask the document colours.
 */
function layers(
  draw: (paint: Record<Role, string>, box: Box) => ReactElement,
  paints: Partial<Record<Role, Record<Theme, Paint>>>,
): Layer[] {
  return (['accent', 'ink', 'dim'] as const).flatMap((role) => {
    const paint = paints[role]
    if (!paint) return []
    const only = { accent: 'none', ink: 'none', dim: 'none', [role]: '#000' }
    return [{ name: role, paint, mark: (box: Box) => draw(only, box) }]
  })
}

const products: Product[] = [
  {
    slug: 'lattices',
    name: 'Lattices',
    source: 'src/components/LatticesMark.tsx',
    viewBox: [0, 0, 20, 20],
    mark: (theme) => h(LatticesMark, { theme, size: 512 }),
    iconMark: (theme, box) => h(LatticesMark, { theme, ...box }),
    layers: layers(
      (paint, box) => h(LatticesMark, {
        theme: 'dark', palette: { ink: paint.ink, dim: paint.dim, dimOpacity: 1 }, accent: paint.accent, ...box,
      }),
      { accent: themed(latticesAccent), ink, dim },
    ),
    app: { dir: 'assets', name: 'AppIcon', minimumSystem: '26.0' },
    colours: [
      ['Ink on light', latticesPalette.light.ink],
      ['Dim cells on light', `${latticesPalette.light.dim} at ${latticesPalette.light.dimOpacity * 100}%`],
      ['Ink on dark', latticesPalette.dark.ink],
      ['Dim cells on dark', `${latticesPalette.dark.dim} at ${latticesPalette.dark.dimOpacity * 100}%`],
      ['Accent, both themes', latticesAccent.light],
      ['Icon tile, light', tiles.light.fill],
      ['Icon tile, dark', tiles.dark.fill],
    ],
    notes: [
      'A 3 × 3 grid with the left column and bottom row lit: the L. The centre carries the accent: the pointer, Action’s cursor with its tip in the crook of the L and its tail on the cell’s top and right edges. The `centre` prop swaps in another shape while Lattices does one job: `knob` to release, `sweep` to move, `bracket` for a session, `node` for live. `accent={false}` draws the centre as a plain dim cell. The site header draws the same component with `theme` unset, so it follows the `--logo-ink`, `--logo-dim` and `--logo-accent` tokens and their hover states.',
      '`public/favicon.svg` is a copy of `lattices-favicon.svg`.',
    ],
  },
  {
    slug: 'action',
    name: 'Action',
    source: 'src/components/ActionMark.tsx',
    viewBox: actionMarkBox,
    mark: (theme) => h(ActionMark, { theme, ...actionKitProps, width: 512, height: 512 }),
    iconMark: (theme, box) => h(ActionMark, {
      theme, ...actionKitProps, decorative: true,
      // The component styles itself to fill its container; inside the icon the
      // placement attributes have to win.
      style: { width: undefined, height: undefined },
      ...box,
    }),
    layers: layers(
      (paint, box) => h(ActionMark, {
        theme: 'dark', ...actionKitProps, decorative: true, style: { width: undefined, height: undefined },
        palette: { ink: paint.ink }, accent: paint.accent, ...box,
      }),
      { accent: themed(latticesAccent), ink },
    ),
    app: { dir: 'products/action/assets/brand', name: 'Action', minimumSystem: '14.0' },
    iconPngs: { dir: 'products/action/assets/brand', sizes: [512, 1024] },
    colours: [
      ['Ink on light', latticesPalette.light.ink],
      ['Ink on dark', latticesPalette.dark.ink],
      ['Cursor, both themes', latticesAccent.light],
      ['Icon tile, light', tiles.light.fill],
      ['Icon tile, dark', tiles.dark.fill],
    ],
    notes: [
      `The A fills a square and the cursor lies on its diagonal: the tip sits on the counter's edge and the tail touches the square's right and bottom sides, so the glyph is the square. The kit crops ActionMark's construction drawing to \`${actionMarkBox.join(' ')}\`, the square plus the family margin, so the glyph spans 80% of the box, as the Lattices grid's 16 units span 20.`,
      'The cursor carries the family accent, coral, which also means live in the menu bar. The 10-unit gap separates it from the letter. `accent={false}` draws both in the ink.',
      'The site hero uses the precomputed SVG. The full construction drawing remains a configurable React component.',
      '`products/action/native/engine/CoreSources/ActionBrandMark.swift` ports the same geometry for the menu bar and the in-app chip.',
    ],
  },
  {
    slug: 'blink',
    name: 'Blink',
    source: 'src/components/blink/BlinkMark.tsx',
    viewBox: [0, 0, 20, 20],
    mark: (theme) => h(BlinkMark, { theme, width: 512, height: 512 }),
    iconMark: (theme, box) => h(BlinkMark, { theme, ...box }),
    layers: layers(
      (paint, box) => h(BlinkMark, { theme: 'dark', color: paint.ink, accent: paint.accent, ...box }),
      { accent: themed(latticesAccent), ink },
    ),
    app: { dir: 'products/blink/assets', name: 'AppIcon', minimumSystem: '14.0' },
    iconSvg: 'products/blink/assets/AppIcon.svg',
    colours: [
      ['Ink on light', latticesPalette.light.ink],
      ['Ink on dark', latticesPalette.dark.ink],
      ['Accent, both themes', latticesAccent.light],
      ['Icon tile, light', tiles.light.fill],
      ['Icon tile, dark', tiles.dark.fill],
    ],
    notes: [
      'A panel frame with two blocks stepping across it, on the Lattices grid: the frame’s outer edge sits on the 16-unit square and its stroke is the grid’s 1.2-unit gap. The front block, the note in hand, carries the accent. The page header draws the same component in `currentColor`, with the accent from `--logo-accent`.',
    ],
  },
  {
    slug: 'speech',
    name: 'Speech',
    source: 'src/components/SpeechMark.tsx',
    viewBox: [0, 0, 20, 20],
    mark: (theme) => h(SpeechMark, { theme, size: 512 }),
    iconMark: (theme, box) => h(SpeechMark, { theme, ...box }),
    layers: layers(
      (paint, box) => h(SpeechMark, { theme: 'dark', palette: { ink: paint.ink }, accent: paint.accent, ...box }),
      { accent: themed(latticesAccent), ink },
    ),
    app: { dir: 'products/voice/assets', name: 'AppIcon', minimumSystem: '26.0' },
    colours: [
      ['Ink on light', latticesPalette.light.ink],
      ['Ink on dark', latticesPalette.dark.ink],
      ['Accent, both themes', latticesAccent.light],
      ['Icon tile, light', tiles.light.fill],
      ['Icon tile, dark', tiles.dark.fill],
    ],
    notes: [
      'Two waveform bars frozen at the playhead: the word just spoken in ink and the one sounding now in the accent, with the rest of the readout left out. Short then tall, the pair also draws a speaker. Each bar is a Lattices cell wide, the tall one a full column of the grid, so the glyph runs the 16-unit height and 10.27 units across, centred in the box. It uses the Lattices ink and has no dim.',
    ],
  },
]

const round = (value: number) => Math.round(value * 1000) / 1000

/** The drawn glyph's bounds in the mark's own viewBox units, measured from a large raster. */
async function glyphBounds(product: Product): Promise<Box> {
  const px = 2048
  const svg = renderToStaticMarkup(product.iconMark('dark', { x: 0, y: 0, width: px, height: px }))
  const { data } = await sharp(Buffer.from(svg)).resize(px, px).ensureAlpha().raw()
    .toBuffer({ resolveWithObject: true })
  let minX = px, minY = px, maxX = -1, maxY = -1
  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px; x++) {
      if (data[(y * px + x) * 4 + 3] < 16) continue
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
    }
  }
  const [vx, vy, vw] = product.viewBox
  const unit = vw / px
  return { x: vx + minX * unit, y: vy + minY * unit, width: (maxX + 1 - minX) * unit, height: (maxY + 1 - minY) * unit }
}

interface Composition {
  /** The tile's square inside the 1024 canvas. */
  body: Box
  glyphScale?: number
  /** Square corners, for icons the platform masks itself. */
  square?: boolean
  /** Draw the hairline. Favicons are too small for it. */
  finish?: boolean
}

/** Where the mark's viewBox lands so its measured glyph sits centred on `body` at the grid's share. */
function placeGlyph(product: Product, bounds: Box, body: Box, glyphScale = 1): Box {
  const [vx, vy, vw, vh] = product.viewBox
  const scale = (body.width * grid.glyph * glyphScale) / Math.max(bounds.width, bounds.height)
  const cx = body.x + body.width / 2
  const cy = body.y + body.height / 2
  return {
    x: round(cx - (bounds.x - vx + bounds.width / 2) * scale),
    y: round(cy - (bounds.y - vy + bounds.height / 2) * scale),
    width: round(vw * scale),
    height: round(vh * scale),
  }
}

function composeIcon(
  product: Product, bounds: Box, theme: Theme,
  { body, glyphScale = 1, square = false, finish = true }: Composition,
) {
  const tile = tiles[theme]
  const d = square
    ? `M${body.x} ${body.y}H${body.x + body.width}V${body.y + body.height}H${body.x}Z`
    : tilePath(body.x, body.y, body.width)

  return renderToStaticMarkup(
    h('svg', { xmlns: 'http://www.w3.org/2000/svg', viewBox: `0 0 ${grid.canvas} ${grid.canvas}`, role: 'img', 'aria-label': product.name },
      h('path', { d, fill: tile.fill }),
      finish ? h('path', { d, fill: 'none', stroke: tile.edge, strokeWidth: 2 }) : null,
      product.iconMark(theme, placeGlyph(product, bounds, body, glyphScale))),
  )
}

/** Icon Composer's colour notation: extended sRGB components, alpha last. */
function composerColor({ color, opacity = 1 }: Paint) {
  const hex = /^#([0-9a-f]{6})$/i.exec(color)?.[1]
  if (!hex) throw new Error(`Icon Composer colours must be #rrggbb, not ${color}`)
  const channels = [0, 2, 4].map((at) => parseInt(hex.slice(at, at + 2), 16) / 255)
  return `extended-srgb:${[...channels, opacity].map((value) => value.toFixed(5)).join(',')}`
}

const appearances = (paint: Record<Theme, Paint>) => [
  { value: { solid: composerColor(paint.light) } },
  { appearance: 'dark', value: { solid: composerColor(paint.dark) } },
]

/**
 * The Clear and Tinted icon styles draw every layer in one colour, so only
 * brightness tells the roles apart. The accent stays the brightest, the ink
 * steps down and the dim cells keep their dark-appearance share.
 */
const mono = (layer: Layer) => ({
  appearance: 'tinted',
  value: {
    solid: composerColor({
      color: '#ffffff',
      opacity: layer.name === 'accent' ? 1 : layer.name === 'ink' ? 0.7 : layer.paint.dark.opacity,
    }),
  },
})

/**
 * Icon Composer fills every shape in a layer with the layer's colour, painted
 * or not: it ignores `fill="none"`, zero opacity and strokes, though it keeps
 * masks and even-odd holes. So each layer keeps only the shapes of its role.
 */
const paintedOnly = (svg: string) =>
  svg.replace(/<(rect|path|circle)\b([^>]*)><\/\1>/g, (element, _tag, attributes: string) =>
    /\bfill="none"/.test(attributes) && !/\bstroke="(?!none")/.test(attributes) ? '' : element)

/**
 * The app icon as an Icon Composer document, which macOS 26 draws in the Dock
 * in the light or dark appearance the viewer picks. Its canvas is the tile
 * itself, so the glyph takes the same share of it as on the 824 px tile. The
 * layers stay flat, as the marks are: no glass, shadow or specular highlight.
 */
async function writeIconDocument(product: Product, bounds: Box) {
  const doc = join(repoRoot, product.app.dir, `${product.app.name}.icon`)
  const files = new Map<string, string>()

  const size = grid.canvas
  const placement = placeGlyph(product, bounds, { x: 0, y: 0, width: size, height: size })
  for (const layer of product.layers) {
    files.set(`Assets/${layer.name}.svg`, paintedOnly(renderToStaticMarkup(
      h('svg', { xmlns: 'http://www.w3.org/2000/svg', width: size, height: size, viewBox: `0 0 ${size} ${size}` },
        layer.mark(placement)),
    )))
  }

  const document = {
    'fill-specializations': appearances(themed({ light: tiles.light.fill, dark: tiles.dark.fill })),
    groups: [{
      name: product.name,
      layers: product.layers.map((layer) => ({
        name: layer.name,
        'image-name': `${layer.name}.svg`,
        glass: false,
        'fill-specializations': [...appearances(layer.paint), mono(layer)],
        position: { scale: 1, 'translation-in-points': [0, 0] },
      })),
      shadow: { kind: 'none', opacity: 0 },
      translucency: { enabled: false, value: 0 },
      specular: false,
    }],
    'supported-platforms': { squares: ['macOS'] },
  }
  files.set('icon.json', `${JSON.stringify(document, null, 2)}\n`)

  const current = await Promise.all(
    [...files].map(async ([name, text]) => (await readFile(join(doc, name), 'utf8').catch(() => undefined)) === text),
  )
  if (current.every(Boolean)) return { doc, changed: false }
  await rm(doc, { recursive: true, force: true })
  await mkdir(join(doc, 'Assets'), { recursive: true })
  for (const [name, text] of files) await writeFile(join(doc, name), text)
  return { doc, changed: true }
}

/**
 * Compiles the document to the Assets.car the app bundles; `CFBundleIconName`
 * points macOS at it. For systems before macOS 26 the car also carries the
 * icon flattened in its light appearance. actool stamps every build, so the
 * exporter caches a receipt only after successful compilation. actool ships
 * with Xcode, not the command line tools.
 */
async function writeAssetCatalog(product: Product, doc: string) {
  const work = await mkdtemp(join(tmpdir(), `${product.slug}-car-`))
  try {
    execFileSync('xcrun', [
      'actool', '--compile', work, '--platform', 'macosx',
      '--minimum-deployment-target', product.app.minimumSystem, '--app-icon', product.app.name,
      '--output-partial-info-plist', join(work, 'partial.plist'), doc,
    ], { stdio: ['ignore', 'ignore', 'pipe'] })
    await copyFile(join(work, 'Assets.car'), join(repoRoot, product.app.dir, 'Assets.car'))
    return true
  } catch (error) {
    throw new Error(`${product.slug}: Assets.car not rebuilt; actool failed`, { cause: error })
  } finally {
    await rm(work, { recursive: true, force: true })
  }
}

async function png(svg: string, size: number, file?: string, flatten?: string) {
  let image = sharp(Buffer.from(svg)).resize(size, size)
  if (flatten) image = image.flatten({ background: flatten })
  const buffer = await image.png().toBuffer()
  if (file && !(await samePixels(file, buffer))) await writeFile(file, buffer)
  return buffer
}

/** Leaves a PNG alone when only its encoding would change, so a sharp upgrade doesn't churn the kit. */
async function samePixels(file: string, buffer: Buffer) {
  const existing = await readFile(file).catch(() => undefined)
  if (!existing) return false
  const [before, after] = await Promise.all(
    [existing, buffer].map((image) => sharp(image).ensureAlpha().raw().toBuffer()),
  )
  return before.equals(after)
}

/** iconutil wants exactly these names. */
const iconset: Array<[string, number]> = [
  ['icon_16x16', 16], ['icon_16x16@2x', 32],
  ['icon_32x32', 32], ['icon_32x32@2x', 64],
  ['icon_128x128', 128], ['icon_128x128@2x', 256],
  ['icon_256x256', 256], ['icon_256x256@2x', 512],
  ['icon_512x512', 512], ['icon_512x512@2x', 1024],
]

async function writeIcns(product: Product, svg: string) {
  const work = await mkdtemp(join(tmpdir(), `${product.slug}-icon-`))
  try {
    const set = join(work, `${product.name}.iconset`)
    await mkdir(set)
    for (const [name, size] of iconset) await png(svg, size, join(set, `${name}.png`))
    const file = join(repoRoot, product.app.dir, `${product.app.name}.icns`)
    await mkdir(dirname(file), { recursive: true })
    execFileSync('iconutil', ['--convert', 'icns', set, '--output', file])
  } finally {
    await rm(work, { recursive: true, force: true })
  }
}

/** "a", "a and b", "a, b and c". */
const prose = (items: string[]) =>
  items.length < 2 ? items.join('') : `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`

function readme(product: Product, bounds: Box) {
  const { slug, name, iconPngs, iconSvg, app } = product
  const copies = [
    ...(iconSvg ? [iconSvg] : []),
    ...(iconPngs ? iconPngs.sizes.map((size) => `${iconPngs.dir}/${slug}-icon-${size}.png`) : []),
  ]
  const sizes = ladder.join(', ')
  const glyph = Math.round(grid.glyph * 100)
  const lines = [
    `# ${name} logo assets`,
    '',
    `Generated by \`bun run brand\` from \`${product.source}\`. Edit the component, not these files.`,
    '',
    '| File | Use |',
    '| --- | --- |',
    `| \`${slug}-light.svg\`, \`${slug}-dark.svg\` | The mark for light and dark backgrounds |`,
    `| \`${slug}-{light,dark}-{size}.png\` | The same, transparent, at ${sizes} px |`,
    `| \`${slug}-icon.svg\`, \`${slug}-icon-{size}.png\` | The app icon on Apple's grid, on the dark tile |`,
    `| \`${slug}-icon-light.svg\`, \`${slug}-icon-light-{size}.png\` | The same on the white tile, the light appearance |`,
    `| \`${slug}-favicon.svg\` | Browser tab icon: the dark tile edge to edge |`,
    `| \`${slug}-touch-icon.png\` | 180 px home screen icon, square and opaque |`,
    '',
    'Theme names describe the intended background, so `light` is dark ink. The PNGs are proportional exports, not separately optically adjusted drawings.',
    '',
    ...product.notes.flatMap((note) => [note, '']),
    '## Colour',
    '',
    '| Role | Value |',
    '| --- | --- |',
    ...product.colours.map(([role, value]) => `| ${role} | \`${value}\` |`),
    '',
    '## App icon',
    '',
    `An 824 px tile in a 1024 canvas with continuous corners, shared by every Lattices product: the family's light ink \`${tiles.dark.fill}\` for the dark appearance and white for the light. The glyph's longer side spans ${glyph}% of the tile, as in every product icon. The favicon and touch icon keep the dark tile, drop the margin and grow the glyph ${Math.round((faviconGlyphScale - 1) * 100)}%.`,
    '',
    `Measured glyph bounds in viewBox units: ${round(bounds.x)}, ${round(bounds.y)}, ${round(bounds.width)} × ${round(bounds.height)}.`,
    '',
    `The app draws its icon from \`${app.dir}/${app.name}.icon\`, an Icon Composer document with one flat layer per colour and both appearances, so the Dock follows the icon style set in System Settings. On macOS the export compiles it to \`${app.dir}/Assets.car\`, which the app build copies into the bundle with \`CFBundleIconName\` \`${app.name}\`, and writes \`${app.dir}/${app.name}.icns\` from the dark icon for the disk image. Before macOS 26 the system shows the light icon, which actool flattens into the car.`,
    '',
    ...(copies.length ? [`It also keeps ${prose(copies.map((file) => `\`${file}\``))} in step with the icon.`, ''] : []),
  ]
  return lines.join('\n')
}

/** public/brand/README.md: the kits at a glance and the grid they share. */
function indexReadme() {
  const tile = grid.canvas - grid.inset * 2
  const lines = [
    '# Brand kits',
    '',
    'One kit per product, generated by `bun run brand` (`scripts/export-brand.tsx`) from the React marks. Edit a component or the exporter and rerun it; the files here are output.',
    '',
    '| Product | Mark | Kit |',
    '| --- | --- | --- |',
    ...products.map(({ slug, name, source }) => `| ${name} | \`${source}\` | [\`${slug}/\`](${slug}/README.md) |`),
    '',
    'Each kit holds the mark for light and dark backgrounds as SVG and as transparent PNGs at ' +
      `${ladder.join(', ')} px, the app icon on the dark and the white tile at the same sizes, a favicon, a 180 px touch icon, and a README with the colours and icon measurements.`,
    '',
    '## App icon grid',
    '',
    'Every product icon shares one grid, so they sit together in the Dock:',
    '',
    `- An ${tile} px tile inset ${grid.inset} px in a ${grid.canvas} px canvas: Apple's macOS icon grid.`,
    `- Continuous corners: superellipse quadrants reaching ${round(grid.cornerRatio * 100)}% along each edge with exponent ${grid.exponent}, fitted to the mask macOS 26 draws around system icons.`,
    `- Two tiles: the family's light ink \`${tiles.dark.fill}\` for the dark appearance, with the mark in its dark-background ink, and white \`${tiles.light.fill}\` for the light, with the mark in its light-background ink. Each mark keeps its one accent on both.`,
    '- A 2 px hairline on the tile edge, so the tile holds its shape against a Dock of the same tone.',
    `- The glyph centred on its measured bounds, its longer side ${Math.round(grid.glyph * 100)}% of the tile. Every mark fills the same square of its box, the 16 units of the Lattices grid's 20, so overlaid the glyphs touch the same guides.`,
    '',
    `Favicons keep the dark tile, which holds in a light tab strip where white would not, and drop the margin: the tile runs edge to edge and the glyph grows ${Math.round((faviconGlyphScale - 1) * 100)}%, with no hairline. The touch icon is square and opaque, because iOS applies its own mask.`,
    '',
    '## Where they are used',
    '',
    '| Surface | Source |',
    '| --- | --- |',
    '| Tab and home screen icons on lattices.dev | Chosen per route by `src/lib/brand.ts` |',
    '| Social cards (`public/og*.png`) | `bun run og`, which reads the kits |',
    '| Native app icons | The Icon Composer documents, `Assets.car` and `.icns` files listed in each kit README |',
    '',
  ]
  return lines.join('\n')
}

const requested = process.argv.slice(2)
const unknown = requested.filter((slug) => !products.some((product) => product.slug === slug))
if (unknown.length) {
  console.error(`unknown product: ${unknown.join(', ')}. Choose from ${products.map((p) => p.slug).join(', ')}.`)
  process.exit(2)
}
const selected = requested.length ? products.filter((product) => requested.includes(product.slug)) : products
const canBuildIcns = process.platform === 'darwin'

for (const product of selected) {
  const { slug } = product
  const out = join(brandDir, slug)
  await mkdir(out, { recursive: true })

  for (const theme of themes) {
    const svg = renderToStaticMarkup(product.mark(theme))
    await writeFile(join(out, `${slug}-${theme}.svg`), svg)
    for (const size of ladder) await png(svg, size, join(out, `${slug}-${theme}-${size}.png`))
  }

  const bounds = await glyphBounds(product)
  const inset = grid.inset
  const body = { x: inset, y: inset, width: grid.canvas - inset * 2, height: grid.canvas - inset * 2 }
  const full = { x: 0, y: 0, width: grid.canvas, height: grid.canvas }

  const icon = composeIcon(product, bounds, 'dark', { body })
  await writeFile(join(out, `${slug}-icon.svg`), icon)
  for (const size of ladder) await png(icon, size, join(out, `${slug}-icon-${size}.png`))

  const lightIcon = composeIcon(product, bounds, 'light', { body })
  await writeFile(join(out, `${slug}-icon-light.svg`), lightIcon)
  for (const size of ladder) await png(lightIcon, size, join(out, `${slug}-icon-light-${size}.png`))

  // Tabs and home screens keep the dark tile: white would vanish into a light tab strip.
  const favicon = composeIcon(product, bounds, 'dark', { body: full, glyphScale: faviconGlyphScale, finish: false })
  await writeFile(join(out, `${slug}-favicon.svg`), favicon)

  const touch = composeIcon(product, bounds, 'dark', { body: full, glyphScale: faviconGlyphScale, square: true, finish: false })
  await png(touch, 180, join(out, `${slug}-touch-icon.png`), tiles.dark.fill)

  await writeFile(join(out, 'README.md'), readme(product, bounds))

  if (product.iconPngs) {
    for (const size of product.iconPngs.sizes) {
      await png(icon, size, join(repoRoot, product.iconPngs.dir, `${slug}-icon-${size}.png`))
    }
  }
  if (product.iconSvg) await writeFile(join(repoRoot, product.iconSvg), icon)
  if (slug === 'lattices') await writeFile(join(siteDir, 'public', 'favicon.svg'), favicon)

  const { doc } = await writeIconDocument(product, bounds)
  const car = join(repoRoot, product.app.dir, 'Assets.car')
  const compiled = canBuildIcns && await compileAssetCatalogIfNeeded({
    document: doc,
    catalog: car,
    settings: ['macosx', product.app.minimumSystem, product.app.name],
    compile: () => writeAssetCatalog(product, doc),
  })
  if (canBuildIcns) await writeIcns(product, icon)

  const wrote = [
    relative(repoRoot, out),
    relative(repoRoot, doc),
    ...(compiled ? [relative(repoRoot, car)] : []),
    ...(canBuildIcns ? [join(product.app.dir, `${product.app.name}.icns`)] : []),
  ]
  console.log(`${slug}: ${wrote.join(' + ')}`)
}

await writeFile(join(brandDir, 'README.md'), indexReadme())

if (!canBuildIcns) console.log('Skipped the .icns and Assets.car files: iconutil and actool need macOS.')
