// How much a daemon method can do to the desktop, in the coarse terms the
// tests and acceptance runs use. The desktop runtime itself listens only on
// private Unix sockets and has no remote clients to pair: remote access goes
// through `lats gateway`, which pairs clients and grants exact product:method
// permissions (packages/gateway/src/policy.ts).

export type Scope = "read" | "act" | "drive";

export interface MethodInfo {
  method: string;
  access: "read" | "mutate";
  loopbackOnly?: boolean;
}

/**
 * The scope a method needs. Reads need read; mutations need act, except
 * driving the desktop: computer.* input, and capture.live, whose VNC session
 * takes pointer and keyboard input. apps.open also needs drive because it
 * accepts an arbitrary command.
 */
export function scopeFor(info: Pick<MethodInfo, "method" | "access">): Scope {
  if (["capture.live", "apps.open"].includes(info.method)) return "drive";
  if (info.access === "read") return "read";
  return info.method.startsWith("computer.") ? "drive" : "act";
}
