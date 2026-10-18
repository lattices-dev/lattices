// Cancellation is acknowledged immediately, not queued behind slow OCR.
// Only the worker can confirm that a mutation has not started.
export interface VirtualRequest { id: number; method: string; params?: Record<string, any>; deadline: number }
export class VirtualRequestQueue {
  private tail = Promise.resolve();
  private jobs = new Map<number, { started: boolean; settled: boolean }>();
  private stopped = false;
  constructor(
    private perform: (method: string, params: Record<string, any>) => Promise<unknown>,
    private emit: (value: unknown) => void,
    private now = Date.now,
  ) {}
  enqueue(request: VirtualRequest) {
    const job = { started: false, settled: false };
    this.jobs.set(request.id, job);
    const settle = (value: object) => {
      if (job.settled) return;
      job.settled = true;
      this.emit({ id: request.id, ...value });
    };
    this.tail = this.tail.then(async () => {
      if (job.settled) return;
      if (this.stopped || !Number.isFinite(request.deadline) || this.now() >= request.deadline) {
        settle({ error: "Virtual request cancelled before starting", outcome: "cancelled" });
        return;
      }
      job.started = true;
      this.emit({ id: request.id, event: "started" });
      try { settle({ result: await this.perform(request.method, request.params ?? {}) }); }
      catch (error) {
        const mutation = request.method === "launch" || (request.method.startsWith("computer.") && request.method !== "computer.observe" && request.params?.treatment === "execute" && request.params?.dryRun !== true);
        settle({ error: (error as Error).message + (mutation ? "; action outcome uncertain; do not retry blindly" : ""), ...(mutation ? { outcome: "uncertain" } : {}) });
      }
    }).finally(() => { this.jobs.delete(request.id); });
    return this.tail;
  }
  cancel(id: number) {
    const job = this.jobs.get(id);
    if (!job || job.settled) return;
    job.settled = true;
    this.emit({ id, error: job.started ? "Virtual action already started; outcome uncertain; do not retry blindly" : "Virtual request cancelled before starting",
      outcome: job.started ? "uncertain" : "cancelled" });
  }
  stop() { this.stopped = true; for (const id of this.jobs.keys()) this.cancel(id); }
}
