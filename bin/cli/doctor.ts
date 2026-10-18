import type { DoctorReport } from "../../packages/desktop-client/doctor.ts";
export { diagnoseHost, type DoctorCheck, type DoctorReport } from "../../packages/desktop-client/doctor.ts";

export function printDoctor(report: DoctorReport): void {
  console.log(`Lattices doctor${report.hostname ? " · " + report.hostname : ""}${report.platform ? " · " + report.platform : ""}\n`);
  for (const check of report.checks) console.log(`  ${check.state === "pass" ? "✓" : check.state === "fail" ? "✗" : "?"} ${check.name.padEnd(20)} ${check.detail}`);
  const build = report.build as { commit?: string; dirty?: boolean } | null;
  if (build?.commit) console.log(`\n  Build ${build.commit.slice(0, 12)}${build.dirty ? " · includes local changes" : ""}`);
}
