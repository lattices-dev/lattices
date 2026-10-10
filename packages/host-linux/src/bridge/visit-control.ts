// The host's local control: end every visit from this machine, with no
// pairing and no network. Each running host listens on a unix socket in a
// directory only this user can enter, named for its bridge port, so one
// `lattices-host mouse-home` reaches every host on the desktop.

import { chmodSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { STATE_DIR } from "./security.ts";

export const ENDED_HERE = "Ended on this machine";
const SOCKET = /^visit-\d+\.sock$/;

export function visitControlDir(): string {
  const runtime = process.env.XDG_RUNTIME_DIR;
  return runtime ? join(runtime, "lattices-host") : join(STATE_DIR, "control");
}

/** Listens until stopped. `end` resolves once every visit has been cleaned up. */
export function startVisitControl(dir: string, port: number, end: () => Promise<number>) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  const path = join(dir, `visit-${port}.sock`);
  // This host holds the bridge port, so a socket left here is a dead host's.
  rmSync(path, { force: true });
  const server = Bun.serve({
    unix: path,
    async fetch(req) {
      if (req.method !== "POST" || new URL(req.url).pathname !== "/visits/end") return Response.json({ ok: false, error: "Unknown route" }, { status: 404 });
      return Response.json({ ok: true, ended: await end() });
    },
  });
  chmodSync(path, 0o600);
  return {
    path,
    stop() {
      server.stop(true);
      rmSync(path, { force: true });
    },
  };
}

export interface EndedVisits { hosts: number; ended: number; errors: string[] }

/** Never throws: Bring Cursor Home must still warp when a host is stuck or gone. */
export async function endLocalVisits(dir = visitControlDir(), timeoutMs = 3000): Promise<EndedVisits> {
  const result: EndedVisits = { hosts: 0, ended: 0, errors: [] };
  let sockets: string[];
  try { sockets = readdirSync(dir).filter((name) => SOCKET.test(name)).sort(); } catch { return result; }
  await Promise.all(sockets.map(async (name) => {
    try {
      const response = await fetch("http://localhost/visits/end", { method: "POST", unix: join(dir, name), signal: AbortSignal.timeout(timeoutMs) });
      const body = await response.json() as { ok?: boolean; ended?: number; error?: string };
      if (!response.ok || !body.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
      result.hosts++;
      result.ended += body.ended ?? 0;
    } catch (error) {
      // A host that died without cleaning up leaves a socket nobody answers.
      if (["FailedToOpenSocket", "ConnectionRefused"].includes((error as { code?: string }).code ?? "")) return;
      result.errors.push(`${name}: ${(error as Error).message}`);
    }
  }));
  return result;
}
