import { CDPSession } from "./transport.ts";
import type { ViewportOverride } from "./viewport.ts";

// Hidden documents can suspend animation frames. Yield a browser task there;
// visible documents get two frames so resize handlers and rendering can run.
// Handle a tab becoming hidden during the wait without activating it.
export const SETTLE_LAYOUT_EXPRESSION = `new Promise(resolve => {
  let frame;
  let done = false;
  const channel = new MessageChannel();
  const finish = () => {
    if (done) return;
    done = true;
    if (frame !== undefined) cancelAnimationFrame(frame);
    document.removeEventListener("visibilitychange", visibilityChanged);
    channel.port1.close();
    channel.port2.close();
    resolve(true);
  };
  const visibilityChanged = () => {
    if (document.visibilityState === "hidden") channel.port2.postMessage(null);
  };
  channel.port1.onmessage = finish;
  document.addEventListener("visibilitychange", visibilityChanged);
  if (document.visibilityState === "hidden") visibilityChanged();
  else frame = requestAnimationFrame(() => { frame = requestAnimationFrame(finish); });
})`;

type Owner = {
  viewport: ViewportOverride;
  applied?: ViewportOverride;
  session?: CDPSession;
  connecting?: Promise<CDPSession>;
};

/** Device metrics belong to a CDP connection, not a tab or a tool call. */
export class ViewportSessions {
  private readonly owners = new Map<string, Owner>();

  constructor(private readonly connect = CDPSession.connect) {}

  get size(): number { return this.owners.size; }
  has(targetId: string): boolean { return this.owners.has(targetId); }
  keys(): IterableIterator<string> { return this.owners.keys(); }

  set(targetId: string, viewport: ViewportOverride): void {
    const owner = this.owners.get(targetId);
    if (owner) owner.viewport = viewport;
    else this.owners.set(targetId, { viewport });
  }

  private requireCurrent(targetId: string, owner: Owner): void {
    if (this.owners.get(targetId) !== owner) {
      throw new Error("Browser viewport was released while connecting or applying it.");
    }
  }

  /** Ordinary action/snapshot connections must never take emulation ownership. */
  async apply(targetId: string, url: string): Promise<void> {
    const owner = this.owners.get(targetId);
    if (!owner) return;
    if (owner.session?.isOpen && owner.applied === owner.viewport) return;
    if (!owner.session?.isOpen) {
      owner.session?.close();
      owner.session = undefined;
      owner.applied = undefined;
      owner.connecting ??= this.connect(url).then(session => {
        // Idle release and shutdown can interrupt an awaited connection.
        if (this.owners.get(targetId) !== owner) {
          session.close();
          this.requireCurrent(targetId, owner);
        }
        owner.session = session;
        return session;
      }).finally(() => { owner.connecting = undefined; });
      await owner.connecting;
    }
    this.requireCurrent(targetId, owner);
    const session = owner.session!;
    const viewport = owner.viewport;
    try {
      await session.call("Emulation.setDeviceMetricsOverride", viewport);
      this.requireCurrent(targetId, owner);
      await session.call("Emulation.setTouchEmulationEnabled", {
        enabled: viewport.mobile,
        maxTouchPoints: viewport.mobile ? 5 : 1,
      });
      this.requireCurrent(targetId, owner);
      // Keep ownership while resize/media-query work reaches a browser boundary.
      await session.call("Runtime.evaluate", {
        expression: SETTLE_LAYOUT_EXPRESSION,
        awaitPromise: true,
        returnByValue: true,
      });
      this.requireCurrent(targetId, owner);
      owner.applied = viewport;
    } catch (error) {
      // A command deadline closes its connection. Keep the desired size so the
      // next operation can reconnect, but never keep a dead owner as applied.
      session.close();
      if (owner.session === session) {
        owner.session = undefined;
        owner.applied = undefined;
      }
      throw error;
    }
  }

  /** Clear through the owning connection before dropping it. */
  async reset(targetId: string): Promise<boolean> {
    const owner = this.owners.get(targetId);
    if (!owner) return false;
    this.owners.delete(targetId);
    const session = owner.session;
    if (!session?.isOpen) { session?.close(); return false; }
    try {
      await session.call("Emulation.clearDeviceMetricsOverride");
      await session.call("Emulation.setTouchEmulationEnabled", { enabled: false, maxTouchPoints: 1 });
      return true;
    } finally { session.close(); }
  }

  delete(targetId: string): void {
    const owner = this.owners.get(targetId);
    this.owners.delete(targetId);
    owner?.session?.close();
  }

  clear(): void {
    for (const targetId of this.owners.keys()) this.delete(targetId);
  }
}
