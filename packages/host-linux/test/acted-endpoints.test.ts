import { test, expect } from "bun:test";
import { registerEndpoints } from "../src/endpoints.ts";
import { Router } from "../src/router.ts";
import { typeLabel } from "../src/acted.ts";

for (const failure of ["cursor", "snapshot", "emitter", "none", "no-emitter"]) {
  test("scroll telemetry is best effort: " + failure, async () => {
    let inputs = 0, samples = 0, cursors = 0, events = 0;
    const router = new Router(() => new Set(["input.pointer"]));
    registerEndpoints(router, {
      bindHost: "127.0.0.1", startedAt: 0, clientCount: () => 0,
      emit: failure === "no-emitter" ? undefined : () => {
        events++; if (failure === "emitter") throw Error("emitter");
      },
    }, undefined, {
      snapshot: async () => {
        samples++;
        if (failure === "snapshot" && samples > 1) throw Error("snapshot");
        return { displays: [], windows: [] } as any;
      },
      cursorPos: async () => {
        cursors++; if (failure === "cursor") throw Error("cursor");
        return { x: 1, y: 2 };
      },
      scroll: async () => { inputs++; },
    });
    expect((await router.dispatch("computer.scroll", {dy: 1}) as any).status).toBe("staged");
    expect(inputs).toBe(0);
    expect(samples).toBe(0);
    expect(events).toBe(0);
    expect((await router.dispatch("computer.scroll", {dy: 1, treatment: "execute"}) as any).status).toBe("executed");
    expect(inputs).toBe(1);
    expect(events).toBe(failure === "none" || failure === "emitter" ? 1 : 0);
    if (failure === "no-emitter") { expect(cursors).toBe(0); expect(samples).toBe(1); }
  });
}
test("typed labels contain only length and enter flag", () => {
  const secret = "never-repeat-this-password";
  expect(typeLabel(secret.length, true)).toBe("Type 26 chars + Enter");
  expect(typeLabel(secret.length, true)).not.toContain(secret);
});
