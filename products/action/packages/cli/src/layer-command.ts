const usage = "Usage: layer prepare|display-status|open|status|snapshot|pip|record start|record stop|close|release. Prepare explicitly connects a persistent monitor; open attaches a task, close leaves the monitor connected, release disconnects it. Browser interaction requires MCP layer_open {browser:true}, then layer_click/type/js.";

const allowed: Record<string, readonly string[]> = {
  prepare: ["width", "height"],
  "display-status": [], release: [],
  open: ["bundle-id", "pid", "width", "height", "window-id", "window-title", "pip"],
  status: [], close: [], pip: [],
  snapshot: ["window-id", "full", "out"],
  "record start": ["out"], "record stop": [],
};

/** Validate the entire command before constructing a director or touching a host. */
export function parseLayerCommand(args: string[]): { positionals: string[]; flags: Record<string, string> } {
  const verb = args[0] ?? "status";
  const recordVerb = verb === "record" ? args[1] : undefined;
  const command = verb === "record" ? `record ${recordVerb}` : verb;
  if (!(command in allowed)) throw new Error(`Unknown layer command: ${command}. ${usage}`);
  const positionals = recordVerb ? [verb, recordVerb] : [verb];
  const flags: Record<string, string> = {};
  for (let index = recordVerb ? 2 : args.length ? 1 : 0; index < args.length; index++) {
    const token = args[index];
    if (!token.startsWith("--")) throw new Error(`Unexpected layer argument: ${token}. ${usage}`);
    const [name, ...inlineParts] = token.slice(2).split("=");
    if (!allowed[command].includes(name)) throw new Error(`Unsupported layer ${command} flag: --${name}. ${usage}`);
    if (name in flags) throw new Error(`Duplicate layer flag: --${name}`);
    let value = inlineParts.length ? inlineParts.join("=") : undefined;
    if (value === undefined && args[index + 1] && !args[index + 1].startsWith("--")) value = args[++index];
    if (value === undefined && name === "full") value = "true";
    if (value === undefined || value === "") throw new Error(`Missing value for --${name}`);
    if (["pid", "width", "height", "window-id"].includes(name) && (!/^\d+$/.test(value) || Number(value) <= 0 || !Number.isSafeInteger(Number(value)))) {
      throw new Error(`Invalid --${name}: expected a positive integer`);
    }
    if (name === "full" && !["true", "false"].includes(value)) throw new Error("Invalid --full: expected true or false");
    if (name === "pip" && !["on", "off", "true", "false", "1", "0", "yes", "no"].includes(value)) throw new Error("Invalid --pip: expected on or off");
    flags[name] = value;
  }
  if (flags["bundle-id"] && flags.pid) throw new Error("Use --bundle-id or --pid, not both");
  if (flags["window-id"] && flags["window-title"]) throw new Error("Use --window-id or --window-title, not both");
  if (flags["window-id"] && flags.full === "true") throw new Error("Use --window-id or --full, not both");
  return { positionals, flags };
}
