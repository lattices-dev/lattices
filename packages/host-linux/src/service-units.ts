export function unitQuote(text: string, expandVariables = true): string {
  if (/[\x00-\x1f\x7f]/.test(text)) throw new Error("Invalid service argument");
  return quotedUnitValue(text, expandVariables);
}

// Development installer compatibility: retain its existing path validation.
export function unitArgument(text: string): string {
  if (/[\r\n\0]/.test(text)) throw new Error("Invalid service path");
  return quotedUnitValue(text, true);
}

function quotedUnitValue(text: string, expandVariables: boolean): string {
  const escaped = text.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%");
  return '"' + (expandVariables ? escaped.replaceAll("$", () => "$$") : escaped) + '"';
}

/** Render the same units for development links and standalone runtime copies.
 * Supplying PATH selects the standalone policy: no tailnet startup dependency.
 * Development keeps the template's description, ordering and inherited PATH.
 */
export function renderServiceUnit(template: string, name: "host" | "tray", options: {
  bun: string; entry: string; environmentPath?: string;
}): string {
  const quote = options.environmentPath === undefined ? unitArgument : unitQuote;
  const command = `${quote(options.bun)} ${quote(options.entry)} ${name === "tray" ? "tray" : "--quiet"}`;
  let unit = template.replace(/^ExecStart=.*$/m, () => `ExecStart=${command}`);
  if (options.environmentPath !== undefined) {
    unit = unit.replace(/^#[^\n]*\n/gm, "").trimStart()
      .replace(/^Description=.*$/m, () => `Description=Lattices ${name}`)
      .replace(/^After=.*$/m, "After=graphical-session.target")
      .replace(/^ExecStart=.*$/m, line => `${line}\nEnvironment=${unitQuote("PATH=" + options.environmentPath, false)}`);
  }
  return unit;
}
