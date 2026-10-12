import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { mkdirSync } from 'node:fs';

// One JS file the app runs with the host's Bun. A compiled executable would
// embed a whole Bun runtime (~60 MB) to carry ~11 KB of installer.
const output = process.argv[2];
if (!output) throw new Error('Usage: build-companion-installer.ts <output .js>');
mkdirSync(dirname(resolve(output)), { recursive: true });
execFileSync(process.execPath, ['build', '--target=bun',
  resolve(import.meta.dir, 'companion-installer.ts'), '--outfile', resolve(output)], { stdio: 'inherit' });
