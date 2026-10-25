import { expect, test } from "bun:test";
import { InteractiveInput, interactiveInput, physicalKey } from "../src/interactive-input.ts";
import { withRequestContext } from "../src/request-context.ts";
import { keysym, wtypeKeyArgs } from "../src/input.ts";

function fixture(leaseMs = 3500) {
  const events: string[] = [];
  const lifetime = new AbortController();
  const session = new InteractiveInput(lifetime.signal, {
    pointer: async () => ({
      move: async (x, y) => { events.push(`move ${x} ${y}`); },
      button: async (button, down) => { events.push(`${button} ${down}`); },
      close: async () => { events.push("pointer closed"); },
    }),
    keyboard: async () => ({
      key: async (code, down) => { events.push(`key ${code} ${down}`); },
      ping: async () => { events.push("ping"); },
      close: () => { events.push("keyboard closed"); },
    }),
  }, leaseMs);
  return { session, events, lifetime };
}
const extent = { x: 0, y: 0, w: 3440, h: 1440 };

test("a held Super drag preserves key, button and motion order across requests", async () => {
  const f = fixture();
  await Promise.all([
    f.session.key(125, true), f.session.button("right", true, { x: 10, y: 20, extent }),
    f.session.move(30, 40, extent), f.session.button("right", false), f.session.key(125, false),
  ]);
  expect(f.events).toEqual(["key 125 true", "move 10 20", "right true", "move 30 40", "right false", "key 125 false"]);
  await f.session.reset();
});

test("disconnect releases held buttons and destroys the keyboard; later input is refused", async () => {
  const f = fixture();
  await f.session.button("left", true);
  await f.session.key(42, true);
  f.lifetime.abort();
  await expect(f.session.key(13, true)).rejects.toThrow("closed");
  expect(f.events.slice(-3)).toEqual(["keyboard closed", "left false", "pointer closed"]);
});

test("the lease releases input if a viewer disappears without disconnecting", async () => {
  const f = fixture(25);
  await f.session.key(125, true);
  await f.session.button("right", true);
  await Bun.sleep(60);
  expect(f.events.slice(-3)).toEqual(["keyboard closed", "right false", "pointer closed"]);
});

test("releasing just the keyboard keeps a dragged button protected by its lease", async () => {
  const f = fixture(25);
  await f.session.button("left", true);
  await f.session.key(125, true);
  await f.session.reset("keyboard");
  expect(f.events.at(-1)).toBe("keyboard closed");
  await Bun.sleep(60);
  expect(f.events.slice(-2)).toEqual(["left false", "pointer closed"]);
});

test("expired queued requests cannot press a key after a reset", async () => {
  const f = fixture();
  await expect(withRequestContext({ deadline: Date.now() - 1 }, () => f.session.key(125, true))).rejects.toThrow("cancelled");
  expect(f.events).toEqual([]);
});

test("an expired key release still clears the held keyboard", async () => {
  const f = fixture();
  await f.session.key(125, true);
  await expect(withRequestContext({ deadline: Date.now() - 1 }, () => f.session.key(125, false))).rejects.toThrow("cancelled");
  expect(f.events).toEqual(["key 125 true", "keyboard closed"]);
});

test("cancelling while the keyboard connects prevents a late key press", async () => {
  const events: string[] = [];
  const entered = Promise.withResolvers<void>(), ready = Promise.withResolvers<void>();
  const lifetime = new AbortController(), request = new AbortController();
  const session = new InteractiveInput(lifetime.signal, {
    pointer: async () => { throw new Error("unexpected pointer"); },
    keyboard: async () => {
      entered.resolve(); await ready.promise;
      return { key: async () => { events.push("pressed"); }, ping: async () => {}, close: () => { events.push("closed"); } };
    },
  });
  const result = withRequestContext({ signal: request.signal }, () => session.key(125, true));
  await entered.promise;
  request.abort(); ready.resolve();
  await expect(result).rejects.toThrow("cancelled");
  expect(events).toEqual(["closed"]);
});

test("disconnect during the move before a click prevents the button down", async () => {
  const events: string[] = [];
  const entered = Promise.withResolvers<void>(), moved = Promise.withResolvers<void>();
  const lifetime = new AbortController();
  const session = new InteractiveInput(lifetime.signal, {
    pointer: async () => ({
      move: async () => { entered.resolve(); await moved.promise; },
      button: async () => { events.push("pressed"); },
      close: async () => { events.push("closed"); },
    }),
    keyboard: async () => { throw new Error("unexpected keyboard"); },
  });
  const result = session.button("left", true, { x: 10, y: 20, extent });
  await entered.promise;
  lifetime.abort(); moved.resolve();
  await expect(result).rejects.toThrow("closed");
  expect(events).toEqual(["closed"]);
});

test("ownership comes from the transport, never from action parameters", () => {
  expect(() => interactiveInput()).toThrow("live viewer connection");
  const a = new AbortController(), b = new AbortController();
  const first = withRequestContext({ connection: a.signal }, () => interactiveInput());
  expect(withRequestContext({ connection: a.signal }, () => interactiveInput())).toBe(first);
  expect(withRequestContext({ connection: b.signal }, () => interactiveInput())).not.toBe(first);
  a.abort(); b.abort();
});

test("physical key phases reject invalid codes before touching input", () => {
  for (const code of [-1, 0, 256, 1.5, "13", null]) expect(() => physicalKey({ code, phase: "down" })).toThrow();
  expect(physicalKey({ code: 13, phase: "down" })).toEqual({ code: 13, phase: "down" });
  expect(() => physicalKey({ code: 13, phase: "click" })).toThrow();
});

test("literal plus works through the existing discrete key API too", () => {
  expect(keysym("+")).toBe("plus");
  expect(wtypeKeyArgs("+", ["super"])).toEqual(["-M", "logo", "-k", "plus", "-m", "logo"]);
});
