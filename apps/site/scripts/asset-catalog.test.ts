import { afterEach, expect, test } from 'bun:test'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { compileAssetCatalogIfNeeded } from './asset-catalog'

const temporary: string[] = []
afterEach(async () => { await Promise.all(temporary.splice(0).map((path) => rm(path, { recursive: true, force: true }))) })

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'lattices-catalog-test-'))
  temporary.push(root)
  const document = join(root, 'AppIcon.icon')
  const catalog = join(root, 'Assets.car')
  await mkdir(document)
  await writeFile(join(document, 'icon.json'), 'original document')
  await writeFile(catalog, 'committed catalogue')
  return { document, catalog, settings: ['macosx', '14.0', 'AppIcon'] }
}

test('retries after a failed compile with a changed document and old catalogue', async () => {
  const options = await fixture()
  let calls = 0
  const compile = async () => { calls++; await writeFile(options.catalog, 'new catalogue'); return true }
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(true)
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(false)
  await writeFile(join(options.document, 'icon.json'), 'updated document')
  expect(await compileAssetCatalogIfNeeded({ ...options, compile: async () => { calls++; return false } })).toBe(false)
  expect(await readFile(options.catalog, 'utf8')).toBe('new catalogue')
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(true)
  expect(calls).toBe(3)
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(false)
})

test('compiles documents generated on another host and invalidates changed outputs/settings', async () => {
  const options = await fixture()
  let calls = 0
  const compile = async () => { calls++; await writeFile(options.catalog, `compile ${calls}`); return true }
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(true)
  await writeFile(options.catalog, 'old catalogue restored by git')
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(true)
  expect(await compileAssetCatalogIfNeeded({ ...options, settings: ['macosx', '15.0', 'AppIcon'], compile })).toBe(true)
  await rm(options.catalog)
  expect(await compileAssetCatalogIfNeeded({ ...options, compile })).toBe(true)
})

test('a compiler exception leaves the previous receipt eligible for retry', async () => {
  const options = await fixture()
  await expect(compileAssetCatalogIfNeeded({ ...options, compile: async () => { throw new Error('actool failed') } })).rejects.toThrow('actool failed')
  expect(await compileAssetCatalogIfNeeded({ ...options, compile: async () => { await writeFile(options.catalog, 'recovered'); return true } })).toBe(true)
})
