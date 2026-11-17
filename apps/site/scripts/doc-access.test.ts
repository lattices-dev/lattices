import { expect, test } from 'bun:test'
import { publicDocContent } from '../src/lib/doc-access'

test('installation stays public, long guides stop before details, and headings in code are ignored', () => {
  const raw = '# Guide\n\nAn introduction.\n\n```md\n## Example heading\n```\n\n## Detailed section\n\nPrivate implementation details.'
  expect(publicDocContent(raw, { slug: 'install' }).content).toBe(raw)
  const preview = publicDocContent(raw, { slug: 'api' })
  expect(preview.gated).toBe(true)
  expect(preview.content).toContain('## Example heading')
  expect(preview.content).not.toContain('Private implementation details')
})
test('quickstart includes four useful sections, then marks its cutoff', () => {
  const raw = '# Start\n\nIntro.\n' + Array.from({ length: 6 }, (_, index) => `\n## Step ${index + 1}\n\nInstructions ${index + 1}.`).join('\n')
  const preview = publicDocContent(raw, { slug: 'quickstart' })
  expect(preview.content).toContain('Instructions 4')
  expect(preview.content).not.toContain('Instructions 5')
  expect(preview.gated).toBe(true)
})
