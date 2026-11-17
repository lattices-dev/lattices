// Hyprland draws a software cursor into headless outputs, so screencopy's
// overlay_cursor flag cannot leave it out of their frames. While a
// cursor-free stream of a headless output runs, the viewer draws its own
// pointer and the compositor hides its one, everywhere: Hyprland has no
// per-output switch. A marker survives a crash so the next start restores it.
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import * as hypr from "./hyprland.ts";

export const MARKER = join(homedir(), ".lattices", "cursor-hidden");

let holders = 0;
let queue: Promise<void> = Promise.resolve();

function set(hidden: boolean) {
  queue = queue.then(async () => {
    try {
      if (hidden) {
        mkdirSync(dirname(MARKER), { recursive: true });
        writeFileSync(MARKER, "");
      }
      await hypr.setCursorInvisible(hidden);
      if (!hidden) rmSync(MARKER, { force: true });
    } catch (err) {
      console.error(`[lattices-host] cursor ${hidden ? "hide" : "restore"} failed: ${(err as Error).message}`);
    }
  });
}

/** Hides the pointer until every returned release has run. */
export function hold(): () => void {
  if (++holders === 1) set(true);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    if (--holders === 0) set(false);
  };
}

/** Undo a hide left behind by a host that exited while streaming. */
export function recover(): Promise<void> {
  if (holders === 0 && existsSync(MARKER)) set(false);
  return queue;
}
