import { expect, test } from "bun:test";
import { placeWithClient, searchWithClient } from "../bin/cli/search.ts";
import type { DaemonClient } from "../bin/cli/daemon.ts";

test("CLI search uses the advertised Linux window endpoint after unified search is unavailable", async () => {
  const calls: string[] = [];
  const client = { daemonCall: async (method: string, params?: Record<string, unknown>) => {
    calls.push(method);
    if (method === "search.query") throw new Error("Unknown method: lattices.search");
    if (method === "host.describe") return { platform: "linux", methods: ["windows.search"] };
    expect(params).toEqual({ query: "Lattices" });
    return [{ wid: 123, app: "org.quickshell", title: "Lattices", score: 90, matchSource: "title" }];
  } } as DaemonClient;
  const hits = await searchWithClient(client, "Lattices");
  expect(calls).toEqual(["search.query", "host.describe", "windows.search"]);
  expect(hits[0].window.wid).toBe(123);
  expect(hits[0].reasons).toEqual(["title"]);
});

test("search never falls back after an authorization failure", async () => {
  const calls: string[] = [];
  const client = { daemonCall: async (method: string) => { calls.push(method); throw new Error("unauthorized"); } } as DaemonClient;
  await expect(searchWithClient(client, "Lattices")).rejects.toThrow("unauthorized");
  expect(calls).toEqual(["search.query"]);
});

test("Linux search rejects unsupported filters instead of dropping them", async () => {
  const client = { daemonCall: async (method: string) => {
    if (method === "search.query") throw new Error("Unknown method: search.query");
    if (method === "host.describe") return { platform: "linux", methods: ["windows.search"] };
    throw new Error("Filtered search must not run");
  } } as DaemonClient;
  await expect(searchWithClient(client, "Lattices", { after: "2026-10-13" })).rejects.toThrow("does not support date or recency filters");
});

test("placement previews select an exact window without changing focus and use canonical placement", async () => {
  const calls: unknown[] = [];
  const client = { daemonCall: async (method: string, params: unknown) => {
    calls.push([method, params]);
    if (method === "search.query") return [{ wid: 123, app: "Terminal", title: "project", matchSources: ["title"] }];
    return { status: "planned" };
  } } as DaemonClient;
  const result = await placeWithClient(client, "project", "right", true);
  expect(calls).toEqual([["search.query", { query: "project", sources: ["all"] }], ["windows.place", { wid: 123, placement: "right", dryRun: true }]]);
  expect(result?.window.wid).toBe(123);
  expect(result?.status).toBe("planned");
});

test("placement cannot move a window identified only by its terminal app", async () => {
  const calls: string[] = [];
  const client = { daemonCall: async (method: string) => {
    calls.push(method);
    return [{ wid: 123, app: "Terminal", title: "zsh", matchSources: ["terminal-app"] }];
  } } as DaemonClient;
  expect(await placeWithClient(client, "project", "right", false)).toBeNull();
  expect(calls).toEqual(["search.query"]);
});

test("placement selects the exact window after an app-only match", async () => {
  const calls: unknown[] = [];
  const client = { daemonCall: async (method: string, params: unknown) => {
    calls.push([method, params]);
    if (method === "search.query") return [
      { wid: 123, app: "Terminal", title: "zsh", matchSources: ["terminal-app"] },
      { wid: 456, app: "Terminal", title: "project", matchSources: ["terminal-app", "title"] },
    ];
    return { status: "executed" };
  } } as DaemonClient;
  expect((await placeWithClient(client, "project", "right", false))?.window.wid).toBe(456);
  expect(calls).toEqual([
    ["search.query", { query: "project", sources: ["all"] }],
    ["windows.focus", { wid: 456 }],
    ["windows.place", { wid: 456, placement: "right", dryRun: false }],
  ]);
});
