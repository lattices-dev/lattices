import { cp, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'

const site = resolve(import.meta.dir, '..')
await mkdir(resolve(site, '.worker-assets'), { recursive: true })
await cp(resolve(site, 'dist'), resolve(site, '.worker-assets'), { recursive: true })
await cp(resolve(site, 'private-dist'), resolve(site, '.worker-assets/__private'), { recursive: true })
console.log('Worker assets assembled; private delivery requires server/access.ts.')
