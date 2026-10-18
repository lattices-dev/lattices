import { copyFile, cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import guide from '../src/data/action-start.json' with { type: 'json' }

const siteDir = fileURLToPath(new URL('..', import.meta.url))

export function actionInstallMarkdown() {
  return `# ${guide.title}\n\n${guide.description}\n\n## Prerequisites\n\n${guide.prerequisites}\n\nInstall Bun: https://bun.sh/docs/installation\n\n${guide.steps.map((step, index) => `## ${index + 1}. ${step.title}\n\n\`\`\`sh\n${step.command}\n\`\`\`\n\nExpected result: ${step.expected}\n`).join('\n')}\n## Troubleshooting\n\n${guide.troubleshooting}\n\n## Connect an agent\n\n${guide.agentNote}\n\nMCP setup: ${guide.siteUrl}/action/agent-setup.md\n\n## Linux\n\n${guide.linuxNote}\n\nRemote setup: ${guide.siteUrl}${guide.links.linux}\n`
}

export async function copyActionReferences({ repoRoot, distDir }) {
  const productDir = join(repoRoot, 'products', 'action')
  const sourceDir = join(productDir, 'docs')
  const targetDir = join(distDir, 'action')
  const entries = await readdir(sourceDir, { withFileTypes: true })
  const excluded = new Set(['index.html', 'assets', 'agents', 'AGENTS.md', 'docs.json', 'llms.txt', 'install.md', 'agent-setup.md', 'remote-engine.md', 'agent.json', 'llms-full.txt'])

  await mkdir(targetDir, { recursive: true })
  for (const entry of entries) {
    if (excluded.has(entry.name)) continue
    await cp(join(sourceDir, entry.name), join(targetDir, entry.name), { recursive: true })
  }
  for (const name of ['AGENTS.md', 'docs.json']) {
    await copyFile(join(productDir, name), join(targetDir, name))
  }
  const llms = await readFile(join(productDir, 'llms.txt'), 'utf8')
  const publishedLlms = llms.replace(/^(\- [^\n]+: )\/docs\/([^\s]+)$/gm, '$1/action/$2.md')
  const install = actionInstallMarkdown()
  const setup = await readFile(join(siteDir, 'content/action/agent-setup.md'), 'utf8')
  const linux = await readFile(join(siteDir, 'content/action/remote-engine.md'), 'utf8')
  const onboardingIndex = `## Start here\n\n- Install and first screenshot: ${guide.links.install}\n- Connect MCP: /action/agent-setup.md\n- Remote Linux setup: ${guide.links.linux}\n- Setup manifest: ${guide.links.manifest}\n- Full context: ${guide.links.fullContext}\n- Skill discovery: ${guide.links.discovery}\n\n${guide.agentNote}\n\n`
  await writeFile(join(targetDir, 'llms.txt'), `${onboardingIndex}${publishedLlms}`)
  await writeFile(join(targetDir, 'install.md'), install)
  await writeFile(join(targetDir, 'agent-setup.md'), setup)
  await writeFile(join(targetDir, 'remote-engine.md'), linux)
  const instructions = await readFile(join(targetDir, 'AGENTS.md'), 'utf8')
  await writeFile(join(targetDir, 'llms-full.txt'), `${install}\n\n${setup}\n\n${linux}\n\n# Product reference\n\n${instructions}`)
  await writeFile(join(targetDir, 'agent.json'), JSON.stringify({
    schemaVersion: 1,
    kind: 'product-documentation',
    name: 'Action',
    description: 'Action setup and documentation catalog. Not an A2A endpoint or a hosted MCP service.',
    url: `${guide.siteUrl}/action`,
    prerequisites: guide.prerequisites,
    steps: guide.steps,
    links: Object.fromEntries(Object.entries(guide.links).map(([name, path]) => [name, `${guide.siteUrl}${path}`])),
    mcp: { transport: 'stdio', setup: `${guide.siteUrl}/action/agent-setup.md`, requiresMatchingRuntime: true },
    limitations: [guide.agentNote, guide.linuxNote, 'The video shows a scripted development preview, not a promise of feature availability in the latest release.'],
  }, null, 2) + '\n')
  const skillName = 'action-setup'
  const skillDescription = 'Install Action, verify native capture, and configure the matching local MCP runtime. Use before computer-use work on macOS or a remote Linux host.'
  const skill = `---\nname: ${skillName}\ndescription: ${skillDescription}\n---\n\n${install}\n\n${setup}\n`
  const skillPath = `/.well-known/agent-skills/${skillName}/SKILL.md`
  await mkdir(dirname(join(distDir, skillPath)), { recursive: true })
  await writeFile(join(distDir, skillPath), skill)
  await writeFile(join(distDir, '.well-known/agent-skills/index.json'), JSON.stringify({
    $schema: 'https://schemas.agentskills.io/discovery/0.2.0/schema.json',
    skills: [{ name: skillName, type: 'skill-md', description: skillDescription, url: skillPath, digest: `sha256:${createHash('sha256').update(skill).digest('hex')}` }],
  }, null, 2) + '\n')
  await mkdir(join(targetDir, 'agents'), { recursive: true })
  await writeFile(join(targetDir, 'agents', 'index.html'), `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Action for agents — current documentation</title>
  <meta name="description" content="Authoritative Action agent instructions, runtime setup, and private-layer requirements.">
  <link rel="canonical" href="https://lattices.dev/action/agents/">
  <link rel="alternate" type="text/plain" href="/action/llms.txt" title="Agent documentation index">
  <style>body{max-width:48rem;margin:4rem auto;padding:0 1.5rem;font:18px/1.6 system-ui,sans-serif;color:#20282b;background:#faf5eb}a{color:#175c6b}li{margin:.6rem 0}pre{overflow-x:auto;padding:1rem;background:#f3ebdd;font-size:14px}h3{margin-bottom:.5rem}:focus-visible{outline:2px solid #175c6b;outline-offset:4px}</style>
</head>
<body>
  <main>
    <p><a href="/action/">Action</a></p>
    <h1>Action for agents</h1>
    <p>Start with the macOS app and a first screenshot. Browser orchestration needs a matching MCP runtime. Linux uses a remote host, not Action.app.</p>
    <h2>Install and verify</h2>
    <p>Prerequisites: ${escapeHtml(guide.prerequisites)} <a href="https://bun.sh/docs/installation">Install Bun</a>.</p>
    <ol>${guide.steps.map((step) => `<li><h3>${escapeHtml(step.title)}</h3><pre><code>${escapeHtml(step.command)}</code></pre><p>Expected result: ${escapeHtml(step.expected)}</p></li>`).join('')}</ol>
    <p>${escapeHtml(guide.troubleshooting)}</p>
    <h2>Connect your agent</h2>
    <p>${escapeHtml(guide.agentNote)}</p>
    <p><a href="/action/agent-setup.md">Install the matching runtime and configure MCP</a> · <a href="/action/remote-engine.md">Remote Linux setup</a></p>
    <h2>Machine-readable references</h2>
    <ul>
      <li><a href="/action/install.md">Install instructions with expected results</a></li>
      <li><a href="/action/agent.json">Setup manifest (product documentation, not an A2A service)</a></li>
      <li><a href="/.well-known/agent-skills/index.json">Skill discovery index (draft v0.2 format)</a></li>
      <li><a href="/action/llms-full.txt">Full context bundle</a></li>
      <li><a href="/action/agent-layer.md">Private-layer workflow, acceptance requirements, and controls</a></li>
      <li><a href="/action/getting-started.md">Getting started</a></li>
      <li><a href="/action/native-runtime.md">Runtime installation and diagnostics</a></li>
      <li><a href="/action/browser-profiles.md">Browser ownership and profiles</a></li>
      <li><a href="/action/AGENTS.md">Complete agent instructions</a></li>
      <li><a href="/action/docs.json">Structured documentation</a></li>
      <li><a href="/action/llms.txt">Agent documentation index</a></li>
    </ul>
  </main>
</body>
</html>
`)
}

function escapeHtml(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;')
}
