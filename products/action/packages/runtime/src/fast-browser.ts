import type { FastChoice, FastReceipt, FastSnapshot } from "../../chrome-companion/src/fast-actions.js";
import type { FastPresentationPrefs } from "../../chrome-companion/src/fast-presentation.js";
import { chromeFastTransport } from "./adapters/chrome.js";

export type FastDecision = ({ operation: "DONE" | "BLOCKED" } | { operation: "CLICK" | "TYPE_TEXT"; target: string }) & { model?: string; confidence?: number; operationProbabilities?: Record<string, number>; targetProbabilities?: Record<string, number>; usage?: unknown };
export type FastStep = { observationId: string; observeMs: number; chooseMs: number; textMs: number; executeMs: number; settleMs?: number; decision?: FastDecision; receipt?: FastReceipt };
export interface FastPolicy {
  choose(goal: string, snapshot: FastSnapshot, history: readonly FastStep[]): Promise<FastDecision>;
  writeText?(goal: string, snapshot: FastSnapshot, target: string): Promise<string>;
  /** Independent outcome check on a fresh observation. DONE alone is never success. */
  verify(goal: string, snapshot: FastSnapshot): Promise<boolean>;
}
export interface FastTransport {
  observe(): Promise<FastSnapshot>;
  act(choice: FastChoice): Promise<FastReceipt>;
}

/** Bounded experiment. The caller supplies its model and independent verifier. */
export async function runFastBrowser(options: {
  goal: string; tabId: number; policy: FastPolicy; maxSteps?: number; transport?: FastTransport; settleTimeoutMs?: number; presentation?: boolean | FastPresentationPrefs;
  onStep?: (step: FastStep) => void;
}) {
  const maxSteps = options.maxSteps ?? 20;
  if (!options.goal.trim() || !Number.isSafeInteger(options.tabId) || options.tabId < 0 || !Number.isInteger(maxSteps) || maxSteps < 1 || maxSteps > 100) throw new Error("Supply a goal, explicit tab id, and a step budget from 1 to 100.");
  const settleTimeoutMs = options.settleTimeoutMs ?? 2000;
  if (!Number.isFinite(settleTimeoutMs) || settleTimeoutMs < 1 || settleTimeoutMs > 5000) throw new Error("Settle timeout must be 1–5000 ms.");
  const stateKey = (s: FastSnapshot) => JSON.stringify([s.url, s.title, s.text, s.controls.map(({ id: _id, ...control }) => control)]);
  let executedState: string | undefined;
  let navigationFrom: string | undefined;
  const transport = options.transport ?? chromeFastTransport(options.tabId, options.presentation);
  const history: FastStep[] = [];
  const started = performance.now();
  const finish = (status: "verified" | "unverified" | "blocked" | "uncertain" | "budget", reason?: string) => ({ status, reason, elapsedMs: performance.now() - started, history });
  for (let i = 0; i < maxSteps; i++) {
    let clock = performance.now();
    let snapshot = await transport.observe();
    const observeMs = performance.now() - clock;
    const settleStart = performance.now();
    // An acknowledged click can precede navigation. Do not offer the unchanged
    // page for another decision while that input is still taking effect.
    while ((navigationFrom !== undefined && snapshot.url === navigationFrom) || (executedState !== undefined && stateKey(snapshot) === executedState)) {
      if (performance.now() - settleStart >= settleTimeoutMs) return finish("blocked", "Input was issued but no visible progress followed; inspect before repeating it.");
      await new Promise(resolve => setTimeout(resolve, 50));
      snapshot = await transport.observe();
    }
    executedState = undefined;
    navigationFrom = undefined;
    const step: FastStep = { observationId: snapshot.observationId, observeMs, settleMs: performance.now() - settleStart, chooseMs: 0, textMs: 0, executeMs: 0 };
    history.push(step);
    clock = performance.now();
    const decision = await options.policy.choose(options.goal, structuredClone(snapshot), structuredClone(history.slice(0, -1)));
    step.chooseMs = performance.now() - clock;
    step.decision = decision;
    if (decision.operation === "DONE" || decision.operation === "BLOCKED") {
      options.onStep?.(step);
      if (decision.operation === "BLOCKED") return finish("blocked");
      const fresh = await transport.observe();
      return finish(await options.policy.verify(options.goal, fresh) ? "verified" : "unverified");
    }
    if (!("target" in decision) || !snapshot.controls.some(c => c.id === decision.target && c.operations.includes(decision.operation))) throw new Error("Policy selected an operation/target outside the observed action space.");
    let text: string | undefined;
    if (decision.operation === "TYPE_TEXT") {
      if (!options.policy.writeText) throw new Error("TYPE_TEXT requires a text provider.");
      clock = performance.now();
      text = await options.policy.writeText(options.goal, structuredClone(snapshot), decision.target);
      step.textMs = performance.now() - clock;
    }
    clock = performance.now();
    try {
      step.receipt = await transport.act({ observationId: snapshot.observationId, target: decision.target, operation: decision.operation, text, presentation: options.presentation });
    } catch {
      step.receipt = { status: "uncertain", reason: "Execution reply lost; inspect before continuing.", executeMs: performance.now() - clock };
    }
    step.executeMs = performance.now() - clock;
    if (step.receipt.status === "executed") {
      executedState = stateKey(snapshot);
      if (step.receipt.navigationExpected) navigationFrom = snapshot.url;
    }
    options.onStep?.(step); // Preserve execution before the next observation can fail.
    if (step.receipt.status === "uncertain") return finish("uncertain", step.receipt.reason);
    if (step.receipt.status === "invalid") return finish("blocked", step.receipt.reason);
  }
  return finish("budget");
}
