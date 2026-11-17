// Whether a mutation reached the desktop, and so whether the caller may send it
// again. Mirrors apps/mac/Sources/Core/Daemon/DaemonDelivery.swift: the two
// hosts answer the same client, so the field means the same on both.
import type { Json } from "./router.ts";

export type DeliveryStatus = "not_delivered" | "delivery_uncertain" | "delivered_unverified";

/** Mutations that land the same however often they run: a second focus is still one focus. */
export const REPEATABLE_METHODS = new Set([
  "windows.focus",
  "windows.place",
  "windows.move",
  "windows.moveBack",
  "spaces.focus",
  "mouse.home",
  "computer.aim",
  "display.input.set",
  "displays.remove",
  "sessions.launch",
  "sessions.kill",
  "sessions.detach",
]);

export function delivery(status: DeliveryStatus, method: string): Json {
  const repeatable = REPEATABLE_METHODS.has(method);
  switch (status) {
    case "not_delivered":
      return { status, retrySafe: true, recovery: "retry" };
    case "delivery_uncertain":
      return repeatable
        ? { status, retrySafe: true, recovery: "retry" }
        : { status, retrySafe: false, recovery: "observe_then_retry" };
    case "delivered_unverified":
      return { status, retrySafe: repeatable, recovery: "none" };
  }
}
