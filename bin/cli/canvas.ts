import { execFileSync } from "node:child_process";

/** Forward only to the independently installed local Canvas notes CLI. */
export function canvasCommand(args: string[], options: {
  remoteHost?: string;
  which?: (name: string) => string | null;
  execute?: (program: string, args: string[]) => void;
  report?: (message: string) => void;
} = {}): number {
  const report = options.report ?? console.error;
  if (options.remoteHost) {
    report("lats canvas is local-only. Select the local host to use the installed Canvas CLI.");
    return 1;
  }
  const which = options.which ?? (name => Bun.which(name));
  const executable = which("canvas") ?? which("blink");
  if (!executable) {
    report("Canvas CLI is not installed. Install with npm install -g @arach/blink, then run lats canvas --help. The blink command remains supported.");
    return 1;
  }
  try {
    (options.execute ?? ((program, argv) => { execFileSync(program, argv, { stdio: "inherit" }); }))(executable, args);
    return 0;
  } catch (error) {
    const status = (error as { status?: unknown }).status;
    if (typeof status === "number") return status;
    report(error instanceof Error ? error.message : String(error));
    return 1;
  }
}
