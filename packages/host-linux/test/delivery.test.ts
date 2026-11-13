import { describe, expect, test } from "bun:test";
import { Router, RouterError } from "../src/router.ts";

describe("mutation delivery", () => {
  const router = new Router(() => new Set(["windows.place"]));
  router.register({ method: "windows.list", description: "", access: "read", returns: "", handler: () => [] });
  router.register({ method: "windows.place", description: "", access: "mutate", returns: "", handler: () => true });
  router.register({ method: "computer.typeText", description: "", access: "mutate", returns: "", handler: (p) => {
    if (p.text === undefined) throw RouterError.missingParam("text");
    throw new Error("wtype exited 1");
  } });
  router.register({ method: "displays.create", description: "", access: "mutate", capability: "displays.manage", returns: "", handler: () => true });

  test("reads carry no delivery", async () => {
    expect((await router.handle({ id: "1", method: "windows.list" })).delivery).toBeUndefined();
  });

  test("a mutation that ran is delivered; a repeatable one is safe to resend", async () => {
    expect((await router.handle({ id: "2", method: "windows.place" })).delivery)
      .toEqual({ status: "delivered_unverified", retrySafe: true, recovery: "none" });
  });

  test("a refusal never reached the desktop", async () => {
    expect((await router.handle({ id: "3", method: "computer.typeText", params: {} })).delivery)
      .toEqual({ status: "not_delivered", retrySafe: true, recovery: "retry" });
    expect((await router.handle({ id: "4", method: "displays.create" })).delivery)
      .toEqual({ status: "not_delivered", retrySafe: true, recovery: "retry" });
  });

  test("a typing failure inside the handler may have typed", async () => {
    const reply = await router.handle({ id: "5", method: "computer.typeText", params: { text: "hi" } });
    expect(reply.error).toBe("wtype exited 1");
    expect(reply.delivery).toEqual({ status: "delivery_uncertain", retrySafe: false, recovery: "observe_then_retry" });
  });
});
