import { expect, test } from "bun:test";
import { authorizeRequest, grantsForScope, remoteResult } from "../src/policy.ts";

const read = grantsForScope("lattices", "read");
const screen = grantsForScope("lattices", "read", ["screen"]);

test("remote metadata search resolves defaults and legacy modes into explicit sources", () => {
  for (const method of ["search.query", "lattices.search"]) {
    for (const params of [{}, { sources: [] }, { mode: "quick" }, { mode: "terminal" }, { sources: ["terminals"] }, { sources: ["titles"], mode: "complete" }]) {
      const normalized = authorizeRequest(read, "lattices", method, { query: "fixture", ...params });
      expect(normalized.sources).toBeArray();
      expect(normalized.sources).not.toContain("ocr");
      expect(normalized).not.toHaveProperty("mode");
    }
    expect(authorizeRequest(read, "lattices", method, { sources: ["titles", "terminals"] }).sources).toEqual(["titles", "cwd", "tabs", "tmux", "processes"]);
  }
});

test("every remote OCR search form requires the cached OCR grant as well as the method grant", () => {
  for (const method of ["search.query", "lattices.search"]) {
    for (const params of [{ sources: ["ocr"] }, { sources: ["titles", "ocr"] }, { sources: ["ocr", "terminals"] }, { sources: ["all"] }, { sources: ["titles", "all"] }, { mode: "complete" }]) {
      expect(() => authorizeRequest(read, "lattices", method, params)).toThrow("scope_denied: OCR search requires lattices:ocr.snapshot");
      expect(authorizeRequest(screen, "lattices", method, params).sources).toContain("ocr");
      expect(authorizeRequest(["lattices:search.query", "lattices:ocr.snapshot"], "lattices", method, params).sources).toContain("ocr");
      expect(() => authorizeRequest(["lattices:ocr.snapshot"], "lattices", method, params)).toThrow("scope_denied");
    }
  }
});

test("malformed or unreviewed search source parameters fail closed", () => {
  for (const params of [{ sources: "all" }, { sources: null }, { sources: [null] }, { sources: ["new-content-source"] }, { sources: ["titles", "new-content-source"] }, { mode: "unknown" }, { mode: "" }, { mode: false }, { mode: null }]) {
    expect(() => authorizeRequest(read, "lattices", "search.query", params)).toThrow("Invalid search");
  }
});

test("remote windows.search defaults to metadata and requires explicit OCR authority", () => {
  expect(authorizeRequest(read, "lattices", "windows.search", { query: "test" })).toEqual({ query: "test", ocr: false });
  expect(authorizeRequest(screen, "lattices", "windows.search", {})).toEqual({ ocr: false });
  expect(authorizeRequest(read, "lattices", "windows.search", { ocr: false })).toEqual({ ocr: false });
  expect(() => authorizeRequest(read, "lattices", "windows.search", { ocr: true })).toThrow("scope_denied");
  expect(authorizeRequest(screen, "lattices", "windows.search", { ocr: true })).toEqual({ ocr: true });
  for (const ocr of [null, "false", "true", 0, 1, []]) expect(() => authorizeRequest(read, "lattices", "windows.search", { ocr })).toThrow("Invalid ocr flag");
});

const artifact = { id: "artifact-1", runId: "run-1", kind: "screenshot", mimeType: "image/png", createdAt: "now", path: "/private/typed-secret.png", relativePath: "typed-secret.png", metadata: { text: "observed-secret" } };
const run = { id: "run-1", title: "Type into editor", source: "daemon", state: "completed", startedAt: "then", completedAt: "now", artifactDirectoryPath: "/private/run-1", surfaces: [{ id: "window-1", kind: "window", app: "Editor", title: "Document", unreviewedText: "observed-secret" }], artifacts: [artifact], trace: [{ data: { text: "typed-secret" } }], futureContent: "observed-secret" };

test("remote run metadata omits captured and typed content, paths and future fields", () => {
  for (const method of ["runs.get", "runs.list", "runs.artifacts"]) {
    const input = method === "runs.get" ? run : method === "runs.list" ? [run] : [artifact];
    const original = JSON.stringify(input);
    const params = authorizeRequest(read, "lattices", method, {});
    const projected = remoteResult("lattices", method, params, input);
    const record = Array.isArray(projected) ? projected[0] : projected;
    expect(record).toHaveProperty("metadataOnly", true);
    expect(record).toHaveProperty("id");
    const json = JSON.stringify(projected);
    for (const hidden of ["typed-secret", "observed-secret", "/private", "trace", "futureContent", "unreviewedText", "relativePath", "artifactDirectoryPath"]) expect(json).not.toContain(hidden);
    expect(JSON.stringify(input)).toBe(original);
  }
});

test("full stored run content requires an explicit request and file-content grant", () => {
  for (const method of ["runs.get", "runs.list", "runs.artifacts"]) {
    expect(() => authorizeRequest(read, "lattices", method, { includeContent: true })).toThrow("scope_denied");
    expect(() => authorizeRequest(["lattices:files.read"], "lattices", method, { includeContent: true })).toThrow("scope_denied");
    for (const includeContent of ["true", null, 1]) expect(() => authorizeRequest(screen, "lattices", method, { includeContent })).toThrow("Invalid includeContent");
    const input = method === "runs.get" ? run : method === "runs.list" ? [run] : [artifact];
    const params = authorizeRequest(screen, "lattices", method, { includeContent: true });
    expect(remoteResult("lattices", method, params, input)).toBe(input);
    expect(remoteResult("lattices", method, authorizeRequest(screen, "lattices", method, {}), input)).not.toBe(input);
  }
});
