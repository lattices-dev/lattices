#!/usr/bin/env bun
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
const tab = process.argv[2];
if (!tab || !Number.isSafeInteger(Number(tab))) throw new Error('Supply the explicit demo tab ID.');
const subjects = ['Richard Feynman', 'Albert Einstein', 'Marie Curie', 'Niels Bohr', 'Quantum mechanics', 'Theory of relativity', 'Manhattan Project', 'Los Alamos National Laboratory', 'California Institute of Technology', 'Nobel Prize in Physics'];
const output = resolve(process.env.ACTION_DEMO_OUTPUT ?? `artifacts/jev-ten-${Date.now()}`);
await mkdir(output, { recursive: true });
const results = [];
const start = Number(process.env.ACTION_SEARCH_START ?? 1);
if (!Number.isInteger(start) || start < 1 || start > 10) throw new Error("ACTION_SEARCH_START must be 1–10.");
for (const [index, subject] of subjects.entries()) {
  if (index + 1 < start) continue;
  const directory = resolve(output, `search-${String(index + 1).padStart(2, '0')}`);
  const url = `https://en.wikipedia.org/wiki/${subject.replaceAll(' ', '_')}`;
  console.log(`Search ${index + 1}/10: ${subject}`);
  const child = Bun.spawn(['bun', resolve(import.meta.dir, 'demo-jev.ts'), tab, url, `Use Wikipedia's search field to search for ${subject} and open the article. If the search field is offscreen, click the visible (Top) link first to reveal it. Then type the search query. Once the correct article is open, choose DONE immediately; do not search again.`], {
    env: { ...process.env, ACTION_WATCH: '1', ACTION_DEMO_OUTPUT: directory }, stdout: 'inherit', stderr: 'inherit',
  });
  const code = await child.exited;
  const result = await readFile(resolve(directory, 'result.json'), 'utf8').then(JSON.parse).catch(() => ({ status: 'failed', exitCode: code }));
  results.push({ subject, directory, ...result });
  await writeFile(resolve(output, 'summary.json'), JSON.stringify(results, null, 2));
  if (code !== 0 || result.status !== 'verified') throw new Error(`Stopped at ${subject}; inspect the saved receipt before continuing.`);
  await Bun.sleep(2200);
}
console.log(`Verified ${results.length} searches in this run. ${output}`);
