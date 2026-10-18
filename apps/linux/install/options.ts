export interface InstallOptions { gestures: boolean; wheel: boolean; start: boolean; dryRun: boolean; replace: boolean }
export const usage = `Install Lattices for Linux (Hyprland + Quickshell)

  bun run linux:install [options]

  --gestures          Forward-button gestures and the pen trail (Omarchy only)
  --wheel-gestures    Also reserve plain wheel-click for gestures; implies --gestures
  --no-start          Install files without starting services or opening the app
  --dry-run           Show the plan without writing files or starting anything
  --replace-existing Back up and replace files owned by an older/manual install
  --no-deps           Bootstrap only: skip system packages (JS dependencies still install)
  --help              Show this help

Run inside your Hyprland desktop to start and verify the host and tray.
Use --no-start when preparing an installation over SSH or outside the desktop.`;

export function parseOptions(args: string[]): InstallOptions {
  const options = { gestures: false, wheel: false, start: true, dryRun: false, replace: false };
  for (const arg of args) {
    if (arg === "--gestures") options.gestures = true;
    else if (arg === "--wheel-gestures") { options.gestures = true; options.wheel = true; }
    else if (arg === "--no-start") options.start = false;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--replace-existing") options.replace = true;
    else if (arg !== "--no-deps") throw new Error(`Unknown option: ${arg}\n${usage}`);
  }
  return options;
}
