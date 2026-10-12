import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { clickAt, devToolsKey, dragBetween, insertText, parseSpacesBinding, pressKey, type DevToolsPage } from "./agent-layer-browser.js";

const bindings = `{
    ":no-bundle:????" = AllSpaces;
    "com.apple.finder" = "";
    "com.apple.tv" = AllSpaces;
    "com.google.chrome" = "EDAF663A-F1FE-4CC5-AD2C-B8AD7C1B16DC";
}`;

describe("parseSpacesBinding", () => {
  test("an app assigned to one Desktop returns that Desktop", () => {
    assert.equal(parseSpacesBinding(bindings, "com.google.Chrome"), "EDAF663A-F1FE-4CC5-AD2C-B8AD7C1B16DC");
  });

  test("All Desktops, None and unlisted apps aren't pinned", () => {
    assert.equal(parseSpacesBinding(bindings, "com.apple.tv"), undefined);
    assert.equal(parseSpacesBinding(bindings, "com.apple.finder"), undefined);
    assert.equal(parseSpacesBinding(bindings, "com.google.chrome.for.testing"), undefined);
  });
});

describe("browser input cancellation", () => {
  function fixture(onEvent?: (event: Record<string, unknown>) => void) {
    const events: Array<Record<string, unknown>> = [];
    let refused = false;
    const page = {
      async call(method: string, params: Record<string, unknown>) {
        events.push({ method, ...params });
        onEvent?.({ method, ...params });
        return {};
      },
    } as unknown as DevToolsPage;
    return {
      events,
      page,
      stop() { refused = true; },
      async guard() { if (refused) throw new Error("operator stopped"); },
    };
  }

  test("refuses all input before the first dispatch", async () => {
    const input = fixture();
    input.stop();
    await assert.rejects(clickAt(input.page, { x: 0, y: 0 }, 0, input.guard), /operator stopped/);
    await assert.rejects(dragBetween(input.page, { x: 0, y: 0 }, { x: 10, y: 10 }, 0, input.guard), /operator stopped/);
    await assert.rejects(insertText(input.page, "hello\n", input.guard), /operator stopped/);
    await assert.rejects(pressKey(input.page, devToolsKey("return")!, input.guard), /operator stopped/);
    assert.deepEqual(input.events, []);
  });

  test("refuses mouse press if stopped after initial pointer move", async () => {
    const input = fixture(() => input.stop());
    await assert.rejects(clickAt(input.page, { x: 1, y: 2 }, 0, input.guard), /operator stopped/);
    assert.deepEqual(input.events.map((event) => event.type), ["mouseMoved"]);
  });

  test("releases a held click even when stopped", async () => {
    const input = fixture((event) => {
      if (event.type === "mousePressed") input.stop();
    });
    await assert.rejects(clickAt(input.page, { x: 1, y: 2 }, 1, input.guard), /operator stopped/);
    assert.deepEqual(input.events.map((event) => event.type), ["mouseMoved", "mousePressed", "mouseReleased"]);
  });

  test("aborts a drag at its last dispatched point and releases the mouse", async () => {
    const input = fixture((event) => {
      if (event.type === "mouseMoved" && event.buttons === 1) input.stop();
    });
    await assert.rejects(dragBetween(input.page, { x: 0, y: 0 }, { x: 40, y: 80 }, 0, input.guard), /operator stopped/);
    assert.deepEqual(input.events.map((event) => event.type), ["mouseMoved", "mousePressed", "mouseMoved", "mouseReleased"]);
    assert.deepEqual(input.events.at(-1), {
      method: "Input.dispatchMouseEvent", type: "mouseReleased", x: 10, y: 20, button: "left", buttons: 0, clickCount: 1,
    });
  });

  test("does not send Return or later lines after text insertion is stopped", async () => {
    const input = fixture(() => input.stop());
    await assert.rejects(insertText(input.page, "first\nsecond", input.guard), /operator stopped/);
    assert.deepEqual(input.events, [{ method: "Input.insertText", text: "first" }]);
  });

  test("releases Return after stop and refuses the next line", async () => {
    const input = fixture((event) => {
      if (event.type === "keyDown") input.stop();
    });
    await assert.rejects(insertText(input.page, "first\nsecond", input.guard), /operator stopped/);
    assert.deepEqual(input.events.map((event) => event.type ?? event.text), ["first", "keyDown", "keyUp"]);
  });

  test("attempts release even when a pressed event fails", async () => {
    for (const kind of ["key", "mouse"]) {
      const input = fixture((event) => {
        if (event.type === "keyDown" || event.type === "mousePressed") throw new Error("connection failed after press");
      });
      await assert.rejects(kind === "key"
        ? pressKey(input.page, devToolsKey("return")!, input.guard)
        : clickAt(input.page, { x: 1, y: 2 }, 0, input.guard), /connection failed/);
      assert.equal(input.events.at(-1)?.type, kind === "key" ? "keyUp" : "mouseReleased");
    }
  });
});
