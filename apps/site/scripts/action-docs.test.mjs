import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { copyActionReferences } from './action-docs.mjs'

test('exports authoritative Action artifacts and replaces legacy entry points', async () => {
  const repoRoot = await mkdtemp(join(tmpdir(), 'action-docs-'))
  const productDir = join(repoRoot, 'products', 'action')
  const docsDir = join(productDir, 'docs')
  const distDir = join(repoRoot, 'dist')
  try {
    await mkdir(join(docsDir, 'agents'), { recursive: true })
    await writeFile(join(docsDir, 'agents', 'index.html'), 'stale instructions')
    await writeFile(join(docsDir, 'index.html'), 'legacy landing')
    for (const name of ['AGENTS.md', 'docs.json', 'llms.txt']) {
      await writeFile(join(docsDir, name), 'stale duplicate')
    }
    await writeFile(join(productDir, 'AGENTS.md'), '# Current instructions\n')
    await writeFile(join(productDir, 'docs.json'), '{"version":"0.3.1"}\n')
    await writeFile(join(productDir, 'llms.txt'), '# Action\n- Agent layer: /docs/agent-layer\n- Native-runtime.agent: /docs/native-runtime.agent\nKeep docs/agent-layer.md in repository instructions.\n')
    await writeFile(join(docsDir, 'agent-layer.md'), '# Current layer guide\n')
    await copyActionReferences({ repoRoot, distDir })
    const output = join(distDir, 'action')
    assert.equal(await readFile(join(output, 'AGENTS.md'), 'utf8'), '# Current instructions\n')
    assert.equal(await readFile(join(output, 'docs.json'), 'utf8'), '{"version":"0.3.1"}\n')
    assert.equal(await readFile(join(output, 'agent-layer.md'), 'utf8'), '# Current layer guide\n')
    assert.equal(await readFile(join(output, 'llms.txt'), 'utf8'), '# Action\n- Agent layer: /action/agent-layer.md\n- Native-runtime.agent: /action/native-runtime.agent.md\nKeep docs/agent-layer.md in repository instructions.\n')
    const entry = await readFile(join(output, 'agents', 'index.html'), 'utf8')
    assert.match(entry, /href="\/action\/agent-layer.md"/)
    assert.doesNotMatch(entry, /stale/)
    await assert.rejects(readFile(join(output, 'index.html')), { code: 'ENOENT' })
    await rm(join(productDir, 'AGENTS.md'))
    await assert.rejects(copyActionReferences({ repoRoot, distDir }), { code: 'ENOENT' })
  } finally {
    await rm(repoRoot, { recursive: true, force: true })
  }
})
