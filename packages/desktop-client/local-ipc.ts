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

export function localEndpoint(product: string, env: Record<string, string | undefined> = process.env): DaemonEndpoint {
  if (!/^[a-z][a-z-]*$/.test(product)) throw new Error("Invalid local product name");
  const directory = localRuntimeDirectory(env);
  return { host: "localhost", port: 0, socketPath: join(directory, `${product}.sock`), tokenFile: join(directory, `${product}.token`) };
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
