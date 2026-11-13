import { expect, test } from "bun:test";
import { DaemonError } from "../../packages/desktop-client/daemon-client.ts";
import { toolError } from "./types.ts";

test("a mutation's failure tells the agent whether to resend", () => {
  const result = toolError(new DaemonError("wtype exited 1", { status: "delivery_uncertain", retrySafe: false, recovery: "observe_then_retry" }));
  expect(result.isError).toBe(true);
  expect(result.structuredContent?.delivery).toEqual({ status: "delivery_uncertain", retrySafe: false, recovery: "observe_then_retry" });
});

test("other failures stay plain text", () => {
  expect(toolError(new Error("windows_search needs a query"))).toEqual({
    content: [{ type: "text", text: "windows_search needs a query" }],
    isError: true,
  });
});
