import { AsyncLocalStorage } from "node:async_hooks";

/** Transport lifecycle, never client-controlled action parameters. */
export interface RequestContext { deadline?: number; signal?: AbortSignal }
const context = new AsyncLocalStorage<RequestContext>();
export const currentRequestContext = () => context.getStore();
export const withRequestContext = <T>(value: RequestContext, action: () => T): T => context.run(value, action);
export function assertRequestActive(value = currentRequestContext()) {
  if (value?.signal?.aborted || (value?.deadline !== undefined && Date.now() >= value.deadline)) {
    throw new Error("Request cancelled before starting");
  }
}
