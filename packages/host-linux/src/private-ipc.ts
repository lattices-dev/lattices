import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, closeSync, constants, existsSync, fstatSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { dirname } from "node:path";

/** Server-side private IPC setup. Never replace a live listener or follow a symlink. */
export function privateDirectory(path: string): void {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error(`Unsafe IPC directory: ${path}`);
  chmodSync(path, 0o700);
}

/** Read the credential at `path`, creating it if absent. Creation never
 * replaces an existing credential and never exposes a partly written file:
 * the token is written to a private temporary file, then hard-linked in. */
export function privateToken(path: string): string {
  privateDirectory(dirname(path));
  if (!existsSync(path)) {
    const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}`;
    const fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      try { writeFileSync(fd, randomBytes(32).toString("hex") + "\n"); } finally { closeSync(fd); }
      try { linkSync(temporary, path); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    } finally { unlinkSync(temporary); }
  }
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0 || stat.size > 256) throw new Error(`Unsafe IPC token: ${path}`);
    const token = readFileSync(fd, "utf8").trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error(`Invalid IPC token: ${path}`);
    return token;
  } finally { closeSync(fd); }
}

/** A server's credential: fixed, or read at each admission so replacing the
 * file revokes at once. A read failure denies instead of throwing. */
export type LocalCredential = string | (() => string);
export function currentToken(credential: LocalCredential): string {
  if (typeof credential === "string") return credential;
  try { return credential(); } catch { return ""; }
}

/** Remove a pre-consolidation per-service credential. Call only after taking
 * the service's endpoint, so no live server still owns the file. */
export function removeLegacyToken(path: string): void {
  try {
    const stat = lstatSync(path);
    if (stat.uid === process.getuid?.() && (stat.isFile() || stat.isSymbolicLink())) unlinkSync(path);
  } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
}

export function authorizeLocalRequest(req: Request, credential: LocalCredential): boolean {
  const token = currentToken(credential);
  if (!token) return false;
  // Native/CLI transports do not send Origin. Reject even "null" and localhost
  // origins: web content has no reason to reach a privileged local endpoint.
  if (req.headers.has("origin")) return false;
  const host = req.headers.get("host") ?? "";
  if (!/^(localhost|127\.0\.0\.1)(:\d{1,5})?$/.test(host)) return false;
  const value = req.headers.get("x-lattices-token") ?? "";
  const a = Buffer.from(value), b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function prepareSocket(path: string): Promise<void> {
  privateDirectory(dirname(path));
  if (!existsSync(path)) return;
  const stat = lstatSync(path);
  if (!stat.isSocket() || stat.uid !== process.getuid?.()) throw new Error(`Unsafe IPC socket: ${path}`);
  await new Promise<void>((resolve, reject) => {
    const socket = createConnection(path);
    const timer = setTimeout(() => { socket.destroy(); reject(new Error(`IPC socket did not answer: ${path}`)); }, 300);
    socket.once("connect", () => { clearTimeout(timer); socket.destroy(); reject(new Error(`IPC service already running: ${path}`)); });
    socket.once("error", error => {
      clearTimeout(timer);
      if (["ECONNREFUSED", "ENOENT"].includes((error as NodeJS.ErrnoException).code ?? "")) {
        if (existsSync(path) && lstatSync(path).ino === stat.ino) unlinkSync(path);
        resolve();
      } else reject(error);
    });
  });
}

export function protectSocket(path: string): () => void {
  chmodSync(path, 0o600);
  const inode = lstatSync(path).ino;
  return () => { if (existsSync(path) && lstatSync(path).ino === inode) unlinkSync(path); };
}

/** Bun supports authenticated WebSockets over Unix sockets. Keep its runtime
 * constructor extension in one place because DOM's constructor shadows the
 * Bun overload when both type libraries are present. */
export function privateWebSocket(socketPath: string, path: string, headers: Record<string, string>): WebSocket {
  const Constructor = WebSocket as unknown as { new(url: string, options: Bun.WebSocketOptions): WebSocket };
  return new Constructor(`ws+unix://${socketPath}:${path}`, { headers });
}
