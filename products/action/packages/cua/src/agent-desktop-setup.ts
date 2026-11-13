import { recordSetupStep, setupCall, waitForSetupPoll } from "./setup.js";
import type { BackendAvailability, BackendCall, BackendContext, BackendNeed, BackendSetupOptions, BackendSetupResult, BackendSetupStep } from "./types.js";

export const agentDesktopPermissionContext = {
  kind: "launcher" as const,
  description: "macOS assigns agent-desktop permissions to the app that launches it, such as Rex Server or Terminal. Approve the identity macOS shows, then check again from that same launcher. Action.app does not hold these grants.",
};
const object = (value: unknown): value is Record<string, any> => !!value && typeof value === "object" && !Array.isArray(value);
const validState = (value: unknown) => object(value) && ["granted", "denied", "unknown", "not_required"].includes(value.state);
const granted = (value: unknown) => object(value) && ["granted", "not_required"].includes(value.state);
const permissions = [["accessibility", "accessibility", "Accessibility"], ["screen_recording", "screen-recording", "Screen Recording"]] as const;
const unavailable = (): BackendAvailability => ({ ready: false,
  reason: "Could not verify agent-desktop permissions from this launcher.",
  needs: [{ kind: "config", detail: "The configured executable did not return a valid permission status.",
    fix: "Check agent-desktop.command and run action setup agent-desktop from the launcher that will use this backend." }] });

/** Requests and verification use the backend's configured executable and launch context. */
export function createAgentDesktopSetup(ctx: BackendContext, lifetime: AbortSignal,
  read: (call: BackendCall) => Promise<unknown>, request: (call: BackendCall, args: string[]) => Promise<unknown>) {
  const pending = new Set<Promise<BackendSetupResult>>();
  const wait = typeof ctx.options.__wait === "function" ? ctx.options.__wait as typeof waitForSetupPoll : waitForSetupPoll;
  async function availability(call: BackendCall): Promise<BackendAvailability> {
    try {
      const status = await read(call);
      if (!object(status) || permissions.some(([key]) => !validState(status[key]))) return unavailable();
      const needs: BackendNeed[] = permissions.filter(([key]) => !granted(status[key])).map(([, permission, name]) => ({
        kind: "permission", permission, detail: `${name} is missing or unknown for agent-desktop's launcher.`,
        fix: "Run action setup agent-desktop or action ask agent-desktop from the same launcher that will use the backend.",
      }));
      if (!needs.length) return { ready: true, permissionContext: agentDesktopPermissionContext };
      const capability = status.request_capabilities;
      if (!object(capability) || capability.scoped !== true || !Array.isArray(capability.permissions)
        || !permissions.every(([key]) => capability.permissions.includes(key))) return { ready: false,
        reason: "This agent-desktop build cannot request only Action's required permissions.",
        permissionContext: agentDesktopPermissionContext,
        needs: [{ kind: "install", detail: "Managed setup needs an agent-desktop build advertising scoped permission requests.",
          fix: "Update the configured executable to a build supporting permissions --request --only accessibility,screen-recording. Or grant Accessibility and Screen Recording manually with agent-desktop permissions --guide from this launcher, then run setup again." }] };
      return { ready: false, reason: "Setup requires Accessibility and Screen Recording for agent-desktop's launcher.",
        needs, permissionContext: agentDesktopPermissionContext };
    } catch { return unavailable(); }
  }
  async function perform(input: BackendCall, options: BackendSetupOptions): Promise<BackendSetupResult> {
    const call = setupCall({ ...input, signal: AbortSignal.any([input.signal, lifetime]) });
    const steps: BackendSetupStep[] = [];
    const record = (step: BackendSetupStep) => recordSetupStep(ctx, call, steps, step);
    let status: BackendAvailability = unavailable();
    const check = () => {
      call.signal.throwIfAborted();
      if (Date.now() >= call.deadline) throw new Error("Setup expired.");
    };
    try {
      check();
      status = await availability(call);
      check();
      if (status.ready) {
        record({ step: "Verify permissions", status: "done", detail: "Accessibility and Screen Recording are granted in this launcher context." });
        return { ready: true, steps };
      }
      if (status.needs?.some((need) => need.kind !== "permission")) {
        record({ step: "Check permission request support", status: "failed", detail: status.reason });
        return { ready: false, steps, needs: status.needs };
      }
      if (!options.interactive) {
        record({ step: "Request permissions", status: "skipped", detail: "Interactive setup is required to ask macOS for permissions." });
        return { ready: false, steps, needs: status.needs };
      }
      record({ step: "Request permissions", status: "waiting-on-user", detail: agentDesktopPermissionContext.description });
      check();
      await request(call, ["--request", "--only", "accessibility,screen-recording", "--timeout-ms", String(Math.max(1, Math.floor(call.deadline - Date.now())))]);
      check();
      // Request replies are acknowledgments; only a fresh process can establish readiness.
      for (;;) {
        status = await availability(call);
        check();
        if (status.ready) {
          record({ step: "Verify permissions", status: "done", detail: "A fresh agent-desktop process confirmed both permissions." });
          return { ready: true, steps };
        }
        if (status.needs?.some((need) => need.kind !== "permission")) {
          record({ step: "Verify permissions", status: "failed", detail: status.reason });
          return { ready: false, steps, needs: status.needs };
        }
        await wait(call);
        check();
      }
    } catch {
      record({ step: "Verify permissions", status: "failed", detail: call.signal.aborted || Date.now() >= call.deadline
        ? "Setup cancelled or timed out. No further permission request will be sent." : "The permission request or verification failed. Check from this launcher before trying again." });
      return { ready: false, steps, needs: status.needs };
    }
  }
  return {
    availability,
    setup(call: BackendCall, options: BackendSetupOptions): Promise<BackendSetupResult> {
      if (pending.size) return Promise.resolve({ ready: false, steps: [{ step: "Request permissions", status: "skipped", detail: "A permission setup is already running for this backend." }] });
      const result = perform(call, options);
      pending.add(result);
      void result.then(() => pending.delete(result), () => pending.delete(result));
      return result;
    },
    async settle() { await Promise.allSettled(pending); },
  };
}
