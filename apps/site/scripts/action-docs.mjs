import { copyFile, cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export async function copyActionReferences({ repoRoot, distDir }) {
  const productDir = join(repoRoot, 'products', 'action')
  const sourceDir = join(productDir, 'docs')
  const targetDir = join(distDir, 'action')
  const entries = await readdir(sourceDir, { withFileTypes: true })
  const excluded = new Set(['index.html', 'assets', 'agents', 'AGENTS.md', 'docs.json', 'llms.txt'])

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
  await writeFile(join(targetDir, 'llms.txt'), publishedLlms)
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
  <style>body{max-width:48rem;margin:4rem auto;padding:0 1.5rem;font:18px/1.6 system-ui,sans-serif;color:#20282b;background:#faf5eb}a{color:#175c6b}li{margin:.6rem 0}</style>
</head>
<body>
  <main>
    <p><a href="/action/">Action</a></p>
    <h1>Action for agents</h1>
    <p>Use the current product documentation below. These references are exported from the same source as the app and runtime instructions, rather than maintained as a separate setup guide.</p>
    <ul>
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
