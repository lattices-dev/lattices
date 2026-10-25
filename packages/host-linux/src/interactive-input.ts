import { PointerSession, type Button, type Extent } from "./wayland.ts";
import { PhysicalKeyboard } from "./physical-keyboard.ts";
import { assertRequestActive, currentRequestContext } from "./request-context.ts";

interface Pointer {
  move(x: number, y: number, extent: Extent): Promise<void>;
  button(button: Button, down: boolean): Promise<void>;
  close(): Promise<void>;
}
interface Keyboard { key(code: number, down: boolean): Promise<void>; ping(): Promise<void>; close(): void | Promise<void> }

/** One viewer connection owns its devices. Input is ordered, including release. */
export class InteractiveInput {
  private pointer?: Pointer;
  private keyboard?: Keyboard;
  private buttons = new Set<Button>();
  private tail: Promise<unknown> = Promise.resolve();
  private timer?: ReturnType<typeof setTimeout>;
  constructor(private lifetime: AbortSignal, private factories = {
    pointer: (): Promise<Pointer> => PointerSession.open(),
    keyboard: (): Promise<Keyboard> => PhysicalKeyboard.open(),
  }, private leaseMs = 3500) {
    lifetime.addEventListener("abort", () => { void this.reset(); }, { once: true });
  }
  private enqueue<T>(action: () => Promise<T>): Promise<T> {
    const result = this.tail.then(action);
    this.tail = result.catch(() => {});
    return result;
  }
  private perform(action: (check: () => void) => Promise<void>) {
    const context = currentRequestContext();
    const check = () => {
      assertRequestActive(context);
      if (this.lifetime.aborted) throw new Error("Input connection closed");
    };
    return this.enqueue(async () => {
      try {
        check();
        await action(check);
        clearTimeout(this.timer);
        this.timer = setTimeout(() => { void this.reset(); }, this.leaseMs);
        this.timer.unref?.();
      } catch (error) { await this.release(); throw error; }
    });
  }
  move(x: number, y: number, extent: Extent) {
    return this.perform(async check => { this.pointer ??= await this.factories.pointer(); check(); await this.pointer.move(x, y, extent); });
  }
  button(button: Button, down: boolean, point?: { x: number; y: number; extent: Extent }) {
    return this.perform(async check => {
      if (!down && !this.buttons.has(button)) return;
      this.pointer ??= await this.factories.pointer();
      check();
      if (point) await this.pointer.move(point.x, point.y, point.extent);
      check();
      // Record before sending: a failed acknowledgement still needs a release.
      if (down) this.buttons.add(button);
      await this.pointer.button(button, down);
      if (!down) this.buttons.delete(button);
    });
  }
  key(code: number, down: boolean) {
    return this.perform(async check => { this.keyboard ??= await this.factories.keyboard(); check(); await this.keyboard.key(code, down); });
  }
  keepalive() { return this.perform(async () => { await this.keyboard?.ping(); }); }
  reset(kind?: "pointer" | "keyboard") { return this.enqueue(() => this.release(kind)); }
  private async release(kind?: "pointer" | "keyboard") {
    clearTimeout(this.timer);
    if (kind !== "pointer") { await this.keyboard?.close(); this.keyboard = undefined; }
    if (kind !== "keyboard") {
      const pointer = this.pointer;
      this.pointer = undefined;
      if (pointer) {
        for (const button of this.buttons) await pointer.button(button, false).catch(() => {});
        await pointer.close().catch(() => {});
      }
      this.buttons.clear();
    }
    // Releasing one device must not remove the other's safety timeout.
    if (this.keyboard || this.pointer) {
      this.timer = setTimeout(() => { void this.reset(); }, this.leaseMs);
      this.timer.unref?.();
    }
  }
}

const sessions = new WeakMap<AbortSignal, InteractiveInput>();
export function interactiveInput() {
  const lifetime = currentRequestContext()?.connection;
  if (!lifetime || lifetime.aborted) throw new Error("Interactive input requires a live viewer connection");
  let session = sessions.get(lifetime);
  if (!session) { session = new InteractiveInput(lifetime); sessions.set(lifetime, session); }
  return session;
}

export function physicalKey(params: Record<string, unknown>) {
  const code = params.code;
  const phase = params.phase;
  if (phase !== "down" && phase !== "up" && phase !== "reset" && phase !== "keepalive") throw new Error("Invalid key phase");
  if ((phase === "down" || phase === "up") && (!Number.isInteger(code) || Number(code) < 1 || Number(code) > 255)) throw new Error("Invalid evdev key code");
  return { code: Number(code), phase };
}
