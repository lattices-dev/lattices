/** Only commands whose implementation uses the daemon client may cross hosts. */
export function supportsRemote(args: string[]): boolean {
  const [command, sub] = args;
  if (command === "capture") return !["log", "audit", "record-command", "record-exec", "record-run", "record-cmd", "recordCommand", "recordRun", "recordExec"].includes(sub);
  if (command === "actor" || command === "actors") return ["show", "hide", "toggle", "status", "hud"].includes(sub);
  return new Set([
    "ls", "list", "status", "inventory", "display", "displays", "bring", "main", "elsewhere", "here", "home",
    "visit", "mouse", "call", "windows", "window", "map", "search", "s", "place", "layer", "layers",
    "state", "states", "diag", "diagnostics", "log", "logs", "activity", "scan", "ocr", "run", "runs",
    "sessions", "terminals", "computer", "cua", "voice", "long", "distribute", "tile", "t", "daemon",
  ]).has(command);
}
