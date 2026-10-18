/**
 * The app icon geometry every product shares, used by the brand exporter
 * (`scripts/export-brand.tsx`) to draw the kits and by the /brand page to
 * document them.
 */
import { latticesPalette } from './marks'

/**
 * The app icon grid every product shares: Apple's 824-pixel tile in a 1024
 * canvas. The corners are superellipse quadrants reaching 34.5% along each
 * edge with exponent 2.85, fitted to the mask macOS 26 draws around system
 * icons (within a pixel at 1024). Every mark fills the same square of its own
 * box, so one glyph share puts them all on the same guides. ActionBrandMark.swift
 * draws Action's in-app chip with the same numbers.
 */
export const iconGrid = {
  canvas: 1024, inset: 100, cornerRatio: 0.345, exponent: 2.85, samples: 48,
  /** The glyph's longer side as a share of the tile. */
  glyph: 0.56,
} as const

/**
 * The tile for each appearance, named like the marks for the background it
 * makes: the family's light ink or white, with the mark in the matching ink.
 * The hairline just inside the edge keeps the tile's shape against a Dock of
 * the same tone.
 */
export const iconTiles = {
  dark: { fill: latticesPalette.light.ink, edge: 'rgba(255,255,255,.08)' },
  light: { fill: '#ffffff', edge: 'rgba(16,21,24,.10)' },
} as const

/** The pixel sizes every kit exports its marks and icons at. */
export const iconSizes = [16, 24, 32, 48, 64, 80, 128, 256, 512, 1024] as const

/** Favicons have no margin to spare, so the glyph grows to fill the tile. */
export const faviconGlyphScale = 1.18

const round = (value: number) => Math.round(value * 1000) / 1000

/** A rounded square with superellipse corners, sampled the way ActionBrandMark.swift samples it. */
export function tilePath(x0: number, y0: number, side: number, cornerRatio: number = iconGrid.cornerRatio) {
  const x1 = x0 + side
  const y1 = y0 + side
  const r = side * cornerRatio
  const exponent = 2 / iconGrid.exponent
  const points: string[] = []
  const at = (x: number, y: number) => points.push(`${round(x)} ${round(y)}`)
  const corner = (cx: number, cy: number, sx: number, sy: number, reversed: boolean) => {
    for (let i = 0; i <= iconGrid.samples; i++) {
      const t = (Math.PI / 2) * ((reversed ? iconGrid.samples - i : i) / iconGrid.samples)
      at(cx + sx * r * Math.cos(t) ** exponent, cy + sy * r * Math.sin(t) ** exponent)
    }
  }

  at(x0 + r, y0)
  at(x1 - r, y0)
  corner(x1 - r, y0 + r, 1, -1, true)
  at(x1, y1 - r)
  corner(x1 - r, y1 - r, 1, 1, false)
  at(x0 + r, y1)
  corner(x0 + r, y1 - r, -1, 1, true)
  at(x0, y0 + r)
  corner(x0 + r, y0 + r, -1, -1, false)
  return `M${points.join('L')}Z`
}
