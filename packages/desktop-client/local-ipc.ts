import { constants, closeSync, fstatSync, openSync, readFileSync, lstatSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";

export interface DaemonEndpoint {
  host: string;
  port: number;
  socketPath?: string;
  tokenFile?: string;
}

export function localRuntimeDirectory(env: Record<string, string | undefined> = process.env): string {
  return env.LATTICES_RUNTIME_DIR || join(homedir(), ".lattices", "run");
}

/**
 * Lattices-owned endpoints share one per-user credential, `lattices.token`.
 * Separately shipped products (Action, Speech, the Vox voice runtime) keep
 * their own `<product>.token`.
 */
export const SHARED_TOKEN_PRODUCTS: ReadonlySet<string> = new Set(["lattices", "gateway", "companion"]);

export function sharedTokenFile(env: Record<string, string | undefined> = process.env): string {
  return join(localRuntimeDirectory(env), "lattices.token");
}

/** Per-service credential from before the consolidation, e.g. `companion.token`. */
export function legacyTokenFile(product: string, env: Record<string, string | undefined> = process.env): string {
  return join(localRuntimeDirectory(env), `${product}.token`);
}

/**
 * The credential a client sends to `product`. Transition: a server from
 * before the consolidation still owns its `<product>.token`. Current servers
 * delete that file when they take the endpoint, so its presence means the old
 * server is the live one.
 */
export function localTokenFile(product: string, env: Record<string, string | undefined> = process.env): string {
  if (!SHARED_TOKEN_PRODUCTS.has(product)) return legacyTokenFile(product, env);
  if (product !== "lattices") {
    const legacy = legacyTokenFile(product, env);
    try { lstatSync(legacy); return legacy; } catch { /* consolidated */ }
  }
  return sharedTokenFile(env);
}

export function localEndpoint(product: string, env: Record<string, string | undefined> = process.env): DaemonEndpoint {
  if (!/^[a-z][a-z-]*$/.test(product)) throw new Error("Invalid local product name");
  const directory = localRuntimeDirectory(env);
  return { host: "localhost", port: 0, socketPath: join(directory, `${product}.sock`), tokenFile: localTokenFile(product, env) };
}

/** Credentials are local capabilities, never sent to a remote endpoint. */
export function readLocalToken(path: string): string {
  const directory = lstatSync(dirname(path));
  const uid = process.getuid?.();
  if (!directory.isDirectory() || (uid !== undefined && directory.uid !== uid) || (directory.mode & 0o077) !== 0) {
    throw new Error("Local IPC directory must be owned by this user with mode 0700");
  }
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = fstatSync(fd);
    if (!info.isFile() || info.nlink !== 1 || (uid !== undefined && info.uid !== uid) || (info.mode & 0o077) !== 0 || info.size > 256) {
      throw new Error("Local IPC token must be a private, user-owned regular file");
    }
    const token = readFileSync(fd, "utf8").trim();
    if (!/^[A-Za-z0-9_+/=-]{32,256}$/.test(token)) throw new Error("Invalid local IPC token");
    return token;
  } finally { closeSync(fd); }
}

export function validateLocalSocket(path: string): void {
  const dir = lstatSync(dirname(path));
  const info = lstatSync(path);
  const uid = process.getuid?.();
  if (!dir.isDirectory() || (dir.mode & 0o077) !== 0 || (uid !== undefined && dir.uid !== uid)
    || !info.isSocket() || (info.mode & 0o077) !== 0 || (uid !== undefined && info.uid !== uid)) {
    throw new Error("Local IPC socket must be private and owned by this user");
  }
}
