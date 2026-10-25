import type { Identity } from "../../host-linux/src/auth.ts";

export const PAIRING_COOLDOWN_MS = 5 * 60_000;

/** The machine a pairing request comes from: its tailnet node, else its address. */
export function pairingIdentity(identity: Identity, address: string): string {
  return identity.node && identity.node !== "unknown" ? `node:${identity.node.toLowerCase()}` : `ip:${address || "unknown"}`;
}

interface InFlight<T> { deviceID: string; result: Promise<T>; waiters: number }

/**
 * Keeps one approval prompt per machine. A repeat from the same device waits
 * on the prompt already showing; another device on that machine is refused
 * until it is answered. A person's denial holds the machine off for a while.
 * Unanswered prompts that time out do not start a cooldown.
 */
export class PairingLimits<T = unknown> {
  private inflight = new Map<string, InFlight<T>>();
  private cooldowns = new Map<string, number>();
  constructor(readonly cooldownMs = PAIRING_COOLDOWN_MS, private readonly now = () => Date.now()) {}

  /** Throws pairing_cooldown or pairing_pending; otherwise joins or starts the request. */
  enter(channel: string, who: string, deviceID: string, start: () => Promise<T>): { result: Promise<T>; leave(): boolean } {
    const until = this.cooldowns.get(who);
    if (until !== undefined) {
      if (until > this.now()) throw new Error(`pairing_cooldown: pairing from this machine was denied; try again in ${Math.ceil((until - this.now()) / 60_000)} min`);
      this.cooldowns.delete(who);
    }
    const key = `${channel}|${who}`;
    let entry = this.inflight.get(key);
    if (entry && entry.deviceID !== deviceID) throw new Error("pairing_pending: another pairing request from this machine is waiting for approval");
    if (!entry) {
      const created: InFlight<T> = { deviceID, waiters: 0, result: Promise.resolve(undefined as T) };
      created.result = start().finally(() => { if (this.inflight.get(key) === created) this.inflight.delete(key); });
      this.inflight.set(key, created);
      entry = created;
    }
    const joined = entry;
    joined.waiters++;
    let left = false;
    return { result: joined.result, leave: () => { if (!left) { left = true; joined.waiters--; } return joined.waiters === 0; } };
  }

  /** A person denied this machine. */
  deny(who: string) {
    this.cooldowns.set(who, this.now() + this.cooldownMs);
    if (this.cooldowns.size > 1024) for (const [key, until] of this.cooldowns) if (until <= this.now()) this.cooldowns.delete(key);
  }

  /** The machine whose pending request carries this device, if any. */
  pendingIdentity(deviceID: string): string | undefined {
    for (const [key, entry] of this.inflight) if (entry.deviceID === deviceID) return key.slice(key.indexOf("|") + 1);
    return undefined;
  }
}
