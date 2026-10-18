import { createHash } from 'node:crypto'
import { readFile, readdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const digest = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')

async function documentDigest(directory: string): Promise<string> {
  const entries = await readdir(directory, { withFileTypes: true })
  const contents = await Promise.all(entries.sort((a, b) => a.name.localeCompare(b.name)).map(async (entry) => [
    entry.name,
    entry.isDirectory() ? await documentDigest(join(directory, entry.name)) : digest(await readFile(join(directory, entry.name))),
  ]))
  return digest(JSON.stringify(contents))
}

/** Cache only successful compiles, including their input settings and output. */
export async function compileAssetCatalogIfNeeded({ document, catalog, settings, compile }: {
  document: string
  catalog: string
  settings: readonly string[]
  compile: () => Promise<boolean>
}): Promise<boolean> {
  const inputs = digest(JSON.stringify([settings, await documentDigest(document)]))
  const receipt = `${catalog}.build.json`
  const previous = await readFile(receipt, 'utf8').then((text) => JSON.parse(text) as { inputs?: string; output?: string }).catch(() => null)
  const existing = await readFile(catalog).catch(() => undefined)
  if (existing && previous?.inputs === inputs && previous.output === digest(existing)) return false

  // A failure must not advance the receipt: changed documents and missing or
  // replaced catalogues remain eligible for retry on the next invocation.
  if (!await compile()) return false
  await writeFile(receipt, `${JSON.stringify({ inputs, output: digest(await readFile(catalog)) }, null, 2)}\n`)
  return true
}
