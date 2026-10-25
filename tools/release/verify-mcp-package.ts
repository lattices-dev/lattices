#!/usr/bin/env bun
/** Smoke the actual npm payload without a checkout, personal profiles, or an app. */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { loadToolsets } from "../../bin/mcp/registry.ts";

const root = resolve(import.meta.dir, "../..");
const scratch = mkdtempSync(join(tmpdir(), "lattices-mcp-package-"));
try {
  let archive = process.argv[2] && resolve(process.argv[2]);
  if (!archive) {
    const packed = JSON.parse(execFileSync("npm", [
      "pack", "--ignore-scripts", "--json", "--pack-destination", scratch,
    ], { cwd: root, encoding: "utf8", timeout: 120_000 }));
    // npm 12 keys records by package name; older npm versions return an array.
    const record = Array.isArray(packed) ? packed[0] : Object.values(packed)[0] as { filename: string };
    assert(record?.filename, "npm pack did not report an artifact");
    archive = join(scratch, record.filename);
  }
  execFileSync("tar", ["-xzf", archive, "-C", scratch]);
  const payload = join(scratch, "package");
  const fixtureHome = join(scratch, "home");
  const chromeSource = join(fixtureHome, "chrome-source");
  mkdirSync(chromeSource, { recursive: true });
  writeFileSync(join(chromeSource, "Local State"), JSON.stringify({
    profile: { info_cache: { Default: { name: "Package smoke fixture", active_time: 1 } } },
  }));
  const env = {
    HOME: fixtureHome,
    PATH: "/usr/bin:/bin",
    LATTICES_BUN_BIN: process.execPath,
    BUN_INSTALL_AUTO: "disable",
    LATTICES_RUNTIME_DIR: join(fixtureHome, "runtime"),
    ACTION_BROWSER_PROFILE_ROOT: join(fixtureHome, "action-profiles"),
    ACTION_CHROME_SOURCE_USER_DATA: chromeSource,
  };
  const requests = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "package-smoke", version: "1" } } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "browser_import_cookies", arguments: { listSourceProfiles: true } } },
  ];
  const output = execFileSync(join(payload, "bin/lattices"), ["mcp"], {
    cwd: scratch, env, encoding: "utf8", timeout: 30_000,
    input: requests.map(request => JSON.stringify(request)).join("\n") + "\n",
  });
  const replies = output.trim().split("\n").map(line => JSON.parse(line));
  const reply = (id: number) => {
    const response = replies.find(item => item.id === id);
    assert(response && !response.error, `MCP request ${id} failed: ${JSON.stringify(response)}`);
    return response.result;
  };
  const manifest = JSON.parse(readFileSync(join(payload, "package.json"), "utf8"));
  const sourceManifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  assert.equal(manifest.version, sourceManifest.version, "Packed version must match source");
  assert.equal(reply(1).serverInfo.version, manifest.version);
  const toolsets = await loadToolsets();
  const expected = toolsets.flatMap(toolset => toolset.tools.map(tool => tool.name)).sort();
  const actual = reply(2).tools.map((tool: { name: string }) => tool.name).sort();
  assert.deepEqual(actual, expected, "Packed MCP must expose every source tool by default");
  const cookies = reply(3);
  assert(!cookies.isError, `Cookie helper failed: ${JSON.stringify(cookies)}`);
  const listing = cookies.structuredContent ?? JSON.parse(cookies.content[0].text);
  assert.equal(listing.sourceProfiles[0].name, "Package smoke fixture");
  assert.equal(listing.sourceProfiles[0].path, join(chromeSource, "Default"));
  console.log(JSON.stringify({
    version: manifest.version,
    tools: actual.length,
    toolsets: Object.fromEntries(toolsets.map(toolset => [toolset.name, toolset.tools.length])),
    isolatedStdio: "passed",
    packagedCookieHelpers: "passed",
  }, null, 2));
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
