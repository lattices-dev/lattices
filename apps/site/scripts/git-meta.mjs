// Git-aware metadata: last-updated date per doc/blog post, plus the
// canonical GitHub URL. Cheap to call from a build script; on the SPA side
// the metadata is fetched at build time and inlined in the dist HTML so
// the runtime doesn't shell out.

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { resolve, join } from 'node:path'

const execFileAsync = promisify(execFile)

const GITHUB_REPO = 'lattices-dev/lattices'
const GITHUB_BRANCH = 'main'

export const repoInfo = {
  repo: GITHUB_REPO,
  branch: GITHUB_BRANCH,
  repoUrl: `https://github.com/${GITHUB_REPO}`,
  editDocUrl: (slug) =>
    `https://github.com/${GITHUB_REPO}/edit/${GITHUB_BRANCH}/docs/${slug}.md`,
  editBlogUrl: (slug) =>
    `https://github.com/${GITHUB_REPO}/edit/${GITHUB_BRANCH}/apps/site/content/blog/${slug}.mdx`,
}

export async function getLastUpdated(repoRoot, relativePath) {
  const filePath = resolve(repoRoot, relativePath)
  try {
    const { stdout } = await execFileAsync(
      'git',
      ['log', '-1', '--format=%cI', '--', filePath],
      { cwd: repoRoot, maxBuffer: 1024 * 64 },
    )
    return stdout.trim() || null
  } catch {
    return null
  }
}

export async function getLastUpdatedBatch(repoRoot, paths) {
  const entries = await Promise.all(
    paths.map(async (entry) => [entry.slug, await getLastUpdated(repoRoot, entry.path)]),
  )
  return Object.fromEntries(entries)
}
