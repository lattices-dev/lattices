import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

export const shellQuote = (text: string) => "'" + text.replaceAll("'", "'\\''") + "'";
export function desktopQuote(text: string): string {
  validPath(text);
  if (text.includes("=")) throw new Error("The desktop launcher path cannot contain '='.");
  return '"' + text.replace(/[\\"`$]/g, char => "\\" + char).replaceAll("\\", "\\\\").replaceAll("%", "%%") + '"';
}
function validPath(path: string) {
  if (!isAbsolute(path) || /[\x00-\x1f\x7f]/.test(path)) throw new Error(`Expected an absolute path without control characters: ${JSON.stringify(path)}`);
}
export interface InstallPaths { home: string; bin: string; data: string; config: string; state: string; runtime: string; receipt: string }
export function installPaths(env: NodeJS.ProcessEnv = process.env): InstallPaths {
  const home = env.HOME || homedir();
  const data = env.XDG_DATA_HOME || join(home, ".local/share");
  const config = env.XDG_CONFIG_HOME || join(home, ".config");
  const state = env.XDG_STATE_HOME || join(home, ".local/state");
  const bin = join(home, ".local/bin"), runtime = join(data, "lattices/linux-runtime");
  for (const value of [home, data, config, state, bin]) validPath(value);
  return { home, data, config, state, bin, runtime, receipt: join(runtime, "install.json") };
}
