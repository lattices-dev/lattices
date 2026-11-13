import { spawn } from "node:child_process";

export type AgentDesktopProcessInput = {
  command: string;
  args: string[];
  env: NodeJS.ProcessEnv;
  stdin?: string;
  signal: AbortSignal;
  deadline: number;
};
export type AgentDesktopProcessResult = { stdout: string; exitCode: number | null };
export type AgentDesktopRunner = (input: AgentDesktopProcessInput) => Promise<AgentDesktopProcessResult>;

/** Direct argv delivery. Output and runtime are bounded; text never enters argv or a shell. */
export const runAgentDesktop: AgentDesktopRunner = async (input) => {
  if (input.signal.aborted) throw new Error("agent-desktop call cancelled before launch.");
  if (Date.now() >= input.deadline) throw new Error("agent-desktop deadline expired before launch.");
  return await new Promise((resolve, reject) => {
    const child = spawn(input.command, input.args, {
      env: input.env, stdio: ["pipe", "pipe", "pipe"], detached: process.platform !== "win32", shell: false,
    });
    const chunks: Buffer[] = [];
    let size = 0;
    let failure: Error | undefined;
    const stop = (error: Error) => {
      failure ??= error;
      try {
        if (child.pid && process.platform !== "win32") process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch { /* The process may have exited before cancellation. */ }
    };
    const abort = () => stop(new Error("agent-desktop call cancelled; delivery may be uncertain."));
    const timer = setTimeout(() => stop(new Error("agent-desktop deadline exceeded; delivery may be uncertain.")), Math.max(1, input.deadline - Date.now()));
    input.signal.addEventListener("abort", abort, { once: true });
    if (input.signal.aborted) abort();
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 4 * 1024 * 1024) stop(new Error("agent-desktop exceeded its output limit."));
      else chunks.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 4 * 1024 * 1024) stop(new Error("agent-desktop exceeded its output limit."));
    });
    // Never echo stderr: native diagnostics can contain the supplied text or observed UI.
    child.on("error", () => { failure ??= new Error("Could not launch agent-desktop. Check the configured command."); });
    child.stdin.on("error", () => { /* The child can refuse before consuming stdin; inspect its envelope. */ });
    child.on("close", (exitCode) => {
      clearTimeout(timer);
      input.signal.removeEventListener("abort", abort);
      if (failure) reject(failure);
      else resolve({ stdout: Buffer.concat(chunks).toString("utf8"), exitCode });
    });
    child.stdin.end(input.stdin ?? "");
  });
};
