import { setTimeout as delay } from "node:timers/promises";
import type { BackendCall, BackendContext, BackendSetupStep } from "./types.js";

export const SETUP_TIMEOUT_MS = 120_000;

/** Bound direct backend callers as well as calls made through BackendHost. */
export function setupCall(call: BackendCall): BackendCall {
  const deadline = Math.min(call.deadline, Date.now() + SETUP_TIMEOUT_MS);
  return { ...call, deadline, signal: AbortSignal.any([
    call.signal, AbortSignal.timeout(Math.max(0, deadline - Date.now())),
  ]) };
}

export function recordSetupStep(
  ctx: BackendContext, call: BackendCall, steps: BackendSetupStep[], step: BackendSetupStep,
): void {
  steps.push(step);
  if (call.onSetupStep) call.onSetupStep(step);
  else ctx.log(`[${step.status}] ${step.step}${step.detail ? `: ${step.detail}` : ""}`);
}

export async function waitForSetupPoll(call: BackendCall, intervalMs = 2_000): Promise<void> {
  call.signal.throwIfAborted();
  const remaining = call.deadline - Date.now();
  if (remaining <= 0) throw new Error("Setup timed out waiting for permissions.");
  await delay(Math.min(intervalMs, remaining), undefined, { signal: call.signal });
  call.signal.throwIfAborted();
  if (Date.now() >= call.deadline) throw new Error("Setup timed out waiting for permissions.");
}
