import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { createHash } from 'node:crypto'
import { actionInstallMarkdown, copyActionReferences } from './action-docs.mjs'
import guide from '../src/data/action-start.json' with { type: 'json' }

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
    const index = await readFile(join(output, 'llms.txt'), 'utf8')
    assert.ok(index.endsWith('# Action\n- Agent layer: /action/agent-layer.md\n- Native-runtime.agent: /action/native-runtime.agent.md\nKeep docs/agent-layer.md in repository instructions.\n'))
    assert.ok(index.includes('/action/install.md'))
    const install = await readFile(join(output, 'install.md'), 'utf8')
    assert.equal(install, actionInstallMarkdown())
    for (const step of guide.steps) {
      assert.ok(install.includes(step.command))
      assert.ok(install.includes(step.expected))
    }
    assert.ok(install.includes('"output":"/tmp/action-first.png"'))
    assert.ok(!install.includes('"path":"/tmp/action-first.png"'))
    const manifest = JSON.parse(await readFile(join(output, 'agent.json'), 'utf8'))
    assert.deepEqual(manifest.steps, guide.steps)
    assert.equal(manifest.kind, 'product-documentation')
    assert.equal(manifest.mcp.transport, 'stdio')
    for (const [name, url] of Object.entries(manifest.links)) {
      if (name === 'agents') continue
      assert.ok((await readFile(join(distDir, new URL(url).pathname))).length > 0, url)
    }
    const discovery = JSON.parse(await readFile(join(distDir, '.well-known/agent-skills/index.json'), 'utf8'))
    assert.equal(discovery.$schema, 'https://schemas.agentskills.io/discovery/0.2.0/schema.json')
    const skill = discovery.skills[0]
    const artifact = await readFile(join(distDir, skill.url))
    assert.equal(skill.digest, `sha256:${createHash('sha256').update(artifact).digest('hex')}`)
    assert.ok(artifact.toString().includes(`name: ${skill.name}`))
    assert.ok(artifact.toString().includes(`description: ${skill.description}`))
    const bundle = await readFile(join(output, 'llms-full.txt'), 'utf8')
    assert.ok(bundle.includes(install))
    assert.ok(bundle.includes('# Current instructions'))
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
