import { actionDescription } from '../lib/action-schema'

/** Canonical origin. Matches public/CNAME and the tags in index.html. */
export const SITE_ORIGIN = 'https://lattices.dev'

export const latticesAppVersion = '0.15.0'
export const latticesDownloadUrl =
  `https://github.com/lattices-dev/lattices/releases/download/v${latticesAppVersion}/Lattices.dmg`
export const speechDownloadUrl =
  'https://github.com/lattices-dev/lattices/releases/download/speech-v0.2.0/Speech.dmg'

export interface SoftwareFacts {
  name: string
  applicationCategory: 'DeveloperApplication' | 'ProductivityApplication'
  operatingSystem: 'macOS'
  downloadUrl: string
  softwareVersion?: string
  /** The product page says the download is free. */
  free?: boolean
}

export type JsonLdKind = 'home' | 'software' | 'none'

export interface RouteMeta {
  path: string
  title: string
  description: string
  /** Overrides the image from routeBrand. */
  ogImage?: string
  /** Set when this path is an alias of another page. */
  canonicalPath?: string
  noindex?: boolean
  /** Defaults to indexed pages that are their own canonical URL. */
  sitemap?: boolean
  priority: string
  jsonLd: JsonLdKind
  software?: SoftwareFacts
}

const latticesApp: SoftwareFacts = {
  name: 'Lattices',
  applicationCategory: 'DeveloperApplication',
  operatingSystem: 'macOS',
  downloadUrl: latticesDownloadUrl,
  softwareVersion: latticesAppVersion,
}

export const staticRoutes: readonly RouteMeta[] = [
  {
    path: '/',
    title: 'Lattices — the programmable workspace for Mac',
    description:
      'Organize windows, run your tools, and automate your workflow. Lattices puts your Mac workspace in your hands, with shortcuts, mouse gestures, and a local API.',
    priority: '1.0',
    jsonLd: 'home',
    software: latticesApp,
  },
  {
    path: '/experiment',
    title: 'SYS. 01 — Lattices Architectural Study',
    description:
      'An architectural design study: Dieter Rams meets Teenage Engineering for macOS and agent workspaces.',
    priority: '0.4',
    jsonLd: 'none',
  },
  {
    path: '/concept',
    title: 'SYS. 01 — Lattices Architectural Study',
    description:
      'An architectural design study: Dieter Rams meets Teenage Engineering for macOS and agent workspaces.',
    canonicalPath: '/experiment',
    sitemap: false,
    priority: '0.4',
    jsonLd: 'none',
  },
  {
    path: '/action',
    title: 'Action — computer use from Lattices',
    description: actionDescription,
    priority: '0.9',
    jsonLd: 'none',
    software: {
      name: 'Action',
      applicationCategory: 'DeveloperApplication',
      operatingSystem: 'macOS',
      downloadUrl: `${SITE_ORIGIN}/action/download`,
    },
  },
  {
    path: '/blink',
    title: 'Blink — spatial notes from Lattices',
    description:
      'Blink is spatial notes from Lattices: each note is a floating panel, and the desktop is the workspace.',
    priority: '0.9',
    jsonLd: 'software',
    software: {
      name: 'Blink',
      applicationCategory: 'ProductivityApplication',
      operatingSystem: 'macOS',
      downloadUrl: `${SITE_ORIGIN}/blink/download`,
      free: true,
    },
  },
  {
    path: '/speech',
    title: 'Speech — a standalone player from Lattices',
    description: 'Queue text, choose a voice, and control playback independently.',
    priority: '0.9',
    jsonLd: 'software',
    software: {
      name: 'Speech',
      applicationCategory: 'ProductivityApplication',
      operatingSystem: 'macOS',
      downloadUrl: speechDownloadUrl,
      softwareVersion: '0.2.0',
    },
  },
  {
    path: '/products',
    title: 'Products — Lattices',
    description: 'Browse Lattices, Action, Blink, Speech, and the agent API.',
    priority: '0.9',
    jsonLd: 'none',
  },
  {
    path: '/family',
    title: 'What Lattices can do — Lattices',
    description:
      'A guided tour from workspace layout and agent collaboration to computer use, spatial notes, and speech.',
    priority: '0.9',
    jsonLd: 'none',
  },
  {
    path: '/brand',
    title: 'Brand — Lattices',
    description: 'Marks, app icons, favicons and social cards for Lattices, Action, Blink and Speech.',
    priority: '0.6',
    jsonLd: 'none',
  },
  {
    path: '/blog',
    title: 'Blog — Lattices',
    description: 'Ideas and engineering notes from the Lattices team.',
    priority: '0.8',
    jsonLd: 'none',
  },
  {
    path: '/docs/blog',
    title: 'Blog — Lattices',
    description: 'Ideas and engineering notes from the Lattices team.',
    canonicalPath: '/blog',
    sitemap: false,
    priority: '0.8',
    jsonLd: 'none',
  },
]

export function routeMeta(path: string): RouteMeta | undefined {
  return staticRoutes.find((route) => route.path === path)
}

export function absoluteUrl(path: string): string {
  if (path === '/') return `${SITE_ORIGIN}/`
  return `${SITE_ORIGIN}${path}`
}
