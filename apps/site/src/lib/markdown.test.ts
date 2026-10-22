import { describe, expect, test } from 'bun:test'
import { extractHeadings, prepareMarkdown } from './markdown'

describe('prepareMarkdown', () => {
  test('drops MDX imports outside code fences', () => {
    const out = prepareMarkdown("import Chart from '../components/Chart'\nimport { A, B } from \"./ab\"\n\n# Title")
    expect(out).toBe('# Title')
  })

  test('keeps imports inside code samples', () => {
    const md = "```js\nimport { daemonCall } from '@lattices/lattices'\n\nawait daemonCall('windows.list')\n```"
    expect(prepareMarkdown(md)).toBe(md)
  })

  test('keeps prose lines that start with "import"', () => {
    const md = 'import names the product surface instead of the CLI package.'
    expect(prepareMarkdown(md)).toBe(md)
  })
})

test('table of contents matches rendered GitHub heading IDs and ignores fenced examples', () => {
  const markdown = '## Files & sockets\n## `lats voice.*`\n```md\n## Example only\n```\n## Files & sockets'
  expect(extractHeadings(markdown).map((heading) => heading.id)).toEqual([
    'files--sockets', 'lats-voice', 'files--sockets-1',
  ])
})
