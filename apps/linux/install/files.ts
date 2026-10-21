import { createHash, randomUUID } from "node:crypto";
import { chmodSync, cpSync, lstatSync, mkdirSync, readFileSync, readlinkSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { PlannedFile, Receipt } from "./types.ts";

export const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
export const present = (path: string) => { try { lstatSync(path); return true; } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; return false; } };

export function checkOwnership(planned: PlannedFile[], previous: Receipt | null, current: string, replace: boolean): void {
  const conflicts: string[] = [];
  for (const file of planned) {
    if (!present(file.path)) continue;
    const stat = lstatSync(file.path);
    if (stat.isSymbolicLink() && file.shared) throw new Error(`Config file is a symlink: ${file.path}. Keep it intact and add the documented gesture include manually.`);
    if (stat.isDirectory()) throw new Error(`Expected a file: ${file.path}`);
    const unchanged = !stat.isSymbolicLink() && hash(readFileSync(file.path)) === hash(file.content);
    const owned = !stat.isSymbolicLink() && previous?.files[file.path] === hash(readFileSync(file.path));
    if (!unchanged && !file.shared && !owned && !replace) conflicts.push(file.path);
  }
  if (present(current) && (!previous || !lstatSync(current).isSymbolicLink())) conflicts.push(current);
  if (conflicts.length) throw new Error(`Existing files need review:\n${conflicts.join("\n")}\nUse --replace-existing to back them up and replace them.`);
}

// The caller chooses the commit boundary. Roll back file/config failures before
// activation; a later service failure must keep the usable installed runtime.
export function fileTransaction(state: string) {
  const backup = join(state, "lattices/install-backups", `${Date.now()}-${randomUUID().slice(0, 8)}`);
  const undo: Array<() => void> = [];
  const saveOld = (path: string) => {
    if (!present(path)) { undo.push(() => rmSync(path, { force: true })); return; }
    mkdirSync(backup, { recursive: true, mode: 0o700 });
    const saved = join(backup, `${undo.length}-${path.split("/").pop()}`);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) symlinkSync(readlinkSync(path), saved); else cpSync(path, saved);
    undo.push(() => { rmSync(path, { force: true }); cpSync(saved, path, { dereference: false, verbatimSymlinks: true }); });
  };
  const atomic = (path: string, content: string, mode: number) => {
    mkdirSync(dirname(path), { recursive: true }); saveOld(path);
    const temporary = path + `.install-${randomUUID()}`;
    try { writeFileSync(temporary, content, { mode }); chmodSync(temporary, mode); renameSync(temporary, path); }
    finally { rmSync(temporary, { force: true }); }
  };
  return { backup, saveOld, atomic, rollback: () => { for (const restore of undo.reverse()) restore(); } };
}
