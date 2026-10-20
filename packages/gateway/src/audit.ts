import { appendFileSync, closeSync, constants, fstatSync, ftruncateSync, openSync } from "node:fs";

/** Keep a bounded per-user metadata log without following links. */
export function appendAudit(path: string, record: Record<string, unknown>, maxBytes = 10 * 1024 * 1024): void {
  const line = JSON.stringify(record) + "\n";
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & 0o077)) throw new Error("Unsafe gateway audit file");
    if (stat.size + Buffer.byteLength(line) > maxBytes) ftruncateSync(fd, 0);
    appendFileSync(fd, line);
  } finally { closeSync(fd); }
}
