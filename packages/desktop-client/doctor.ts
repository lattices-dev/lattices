import type { Rpc } from "./contracts.ts";

export interface DoctorCheck { name: string; state: "pass" | "fail" | "unknown"; detail: string }
export interface DoctorReport { ok: boolean; platform: string | null; hostname: string | null; build: unknown; checks: DoctorCheck[] }

export async function diagnoseHost(rpc: Rpc): Promise<DoctorReport> {
  const report: DoctorReport = { ok: false, platform: null, hostname: null, build: null, checks: [] };
  let status: { platform?: string; version?: string; build?: unknown; windowCount?: number };
  try { status = await rpc("daemon.status", null, 3000) as typeof status; }
  catch (error) { report.checks.push({ name: "Host connection", state: "fail", detail: (error as Error).message }); return report; }
  report.platform = status.platform ?? null;
  report.build = status.build ?? null;
  report.checks.push({ name: "Host connection", state: "pass", detail: `Reachable · version ${status.version || "unknown"}` });
  let host: { platform?: string; hostname?: string; build?: unknown; capabilities?: string[]; capabilityHealth?: Record<string, { available: boolean; reason?: string | null }>; eventStream?: { state: string; reason?: string | null } };
  try { host = await rpc("host.describe", null, 5000) as typeof host; }
  catch (error) {
    const unsupported = (error as Error).message === "Unknown method: host.describe";
    report.checks.push({ name: "Detailed health", state: unsupported ? "unknown" : "fail", detail: unsupported ? "This host does not report detailed capability health." : (error as Error).message });
    report.ok = unsupported; return report;
  }
  report.platform = host.platform ?? report.platform;
  report.hostname = host.hostname ?? null;
  report.build = host.build ?? report.build;
  for (const [name, key] of [["Window inventory", "windows.read"], ["Window placement", "windows.place"], ["Spaces", "spaces.read"], ["Terminal sessions", "sessions.tmux"]]) {
    const health = host.capabilityHealth?.[key];
    const available = health?.available ?? host.capabilities?.includes(key);
    report.checks.push({ name, state: available === undefined ? "unknown" : available ? "pass" : "fail", detail: health?.reason || (available ? key : "Capability unavailable or unreported") });
  }
  if (host.eventStream) report.checks.push({ name: "Desktop events", state: host.eventStream.state === "connected" ? "pass" : "fail", detail: host.eventStream.reason || host.eventStream.state });
  report.ok = report.checks.every(check => check.state !== "fail");
  return report;
}
