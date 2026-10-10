import { endLocalVisits, type EndedVisits } from "./bridge/visit-control.ts";
import { bringCursorHome, type CursorHomeDependencies } from "./cursor-home.ts";

export async function runMouseCommand(args: string[], deps?: CursorHomeDependencies, endVisits: () => Promise<EndedVisits> = endLocalVisits) {
  if (args.length !== 1 || args[0] !== "mouse-home") throw new Error("Usage: lattices-host mouse-home");
  const visits = await endVisits();
  return { ...await bringCursorHome(deps), visits };
}
