/**
 * Whether an act reached the app, and so whether the caller may send it again.
 * An agent that sees only "failed" cannot tell a click that never left Action
 * from one the host ran before its reply was lost, and retrying the second kind
 * clicks twice. Every act reply carries one of these, success or error.
 */
export type DeliveryStatus =
  /** Refused or failed before anything was sent to the host. Nothing happened. */
  | "not_delivered"
  /** The host command started and did not report back cleanly. It may have landed. */
  | "delivery_uncertain"
  /** The host ran it. Nothing read the result back. */
  | "delivered_unverified";

export type DeliveryRecovery =
  /** Send the same act again. */
  | "retry"
  /** Look first (observe.snapshot or ax), then act only if the change is missing. */
  | "observe_then_retry"
  /** Don't resend it. Observe if the outcome matters. */
  | "none";

export interface Delivery {
  status: DeliveryStatus;
  /** Sending the identical act again can't double its effect. */
  retrySafe: boolean;
  recovery: DeliveryRecovery;
}

/** Acts that land the same however often they run: a second focus is still one focus. */
const IDEMPOTENT_KINDS = new Set([
  "focus-window",
  "open-app",
  "show-cue",
  "wait-for-condition",
]);

export function delivery(status: DeliveryStatus, kind: string | undefined): Delivery {
  const idempotent = kind !== undefined && IDEMPOTENT_KINDS.has(kind);
  switch (status) {
    case "not_delivered":
      return { status, retrySafe: true, recovery: "retry" };
    case "delivery_uncertain":
      return idempotent
        ? { status, retrySafe: true, recovery: "retry" }
        : { status, retrySafe: false, recovery: "observe_then_retry" };
    case "delivered_unverified":
      return { status, retrySafe: idempotent, recovery: "none" };
  }
}

/** An act failure that knows how far the act got. The message is the original one. */
export class DeliveryError extends Error {
  readonly delivery: Delivery;

  constructor(cause: unknown, delivery: Delivery) {
    super(cause instanceof Error ? cause.message : String(cause), { cause });
    this.name = "DeliveryError";
    this.delivery = delivery;
  }
}

/** Tag a failure with its delivery, keeping a tag an inner act already set. */
export function withDelivery(error: unknown, status: DeliveryStatus, kind: string | undefined): DeliveryError {
  return error instanceof DeliveryError ? error : new DeliveryError(error, delivery(status, kind));
}
