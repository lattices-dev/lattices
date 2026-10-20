import { constants, openSync, closeSync, fstatSync, lstatSync, mkdirSync, chmodSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export const runtimeDirectory = () => resolve(process.env.LATTICES_RUNTIME_DIR ?? join(homedir(), ".lattices/run"));
export const actionSocketPath = () => process.env.ACTION_SOCKET_PATH ?? join(runtimeDirectory(), "action.sock");
export const actionTokenPath = () => join(runtimeDirectory(), "action.token");
export const companionTokenPath = () => join(runtimeDirectory(), "action-companion.token");
export function secureDirectory(path: string): void {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid?.()) throw new Error("IPC directory must be owned by the current user and cannot be a symlink");
  chmodSync(path, 0o700);
}
export function readPrivateToken(path: string): string {
  const directory = lstatSync(dirname(path));
  if (!directory.isDirectory() || directory.uid !== process.getuid?.() || (directory.mode & 0o077) !== 0) throw new Error("IPC directory must be private and user-owned");
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & 0o777) !== 0o600 || stat.size > 1024) {
      throw new Error("IPC token must be a user-owned regular file with mode 0600");
    }
    const token = readFileSync(fd, "utf8").trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error("Invalid IPC token");
    return token;
  } finally { closeSync(fd); }
}
export function ensurePrivateToken(path: string): string {
  secureDirectory(dirname(path));
  let fd: number;
  try { fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "EEXIST") return readPrivateToken(path); throw error; }
  try {
    const token = randomBytes(32).toString("hex");
    writeFileSync(fd, token + "\n");
    return token;
  } finally { closeSync(fd); }
}
export function tokenMatches(candidate: unknown, token: string): boolean {
  if (typeof candidate !== "string") return false;
  const a = Buffer.from(candidate); const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}
