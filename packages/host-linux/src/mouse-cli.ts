import { bringCursorHome, type CursorHomeDependencies } from "./cursor-home.ts";

export async function runMouseCommand(args: string[], deps?: CursorHomeDependencies) {
  if (args.length !== 1 || args[0] !== "mouse-home") throw new Error("Usage: lattices-host mouse-home");
  return bringCursorHome(deps);
}
