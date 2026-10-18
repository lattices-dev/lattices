import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { daemonCall } from "../bin/daemon-client.ts";

// Opt in against a running app with Accessibility and Screen Recording access.
// The test opens, edits, and closes only its own temporary TextEdit document.
test("computer.typeElement preserves full text and verifies whitespace and append", {
  skip: process.env.LATTICES_CUA_TEXT_SMOKE !== "1",
  timeout: 30_000,
}, async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "lattices-cua-text-"));
  const title = `${path.basename(directory)}.txt`;
  const file = path.join(directory, title);
  const output = process.env.LATTICES_CUA_SMOKE_OUTPUT;
  const marker = "Release verification fixture";
  writeFileSync(file, `${marker}\n`);
  const readText = () => JSON.parse(execFileSync("/usr/bin/osascript", [
    "-l", "JavaScript", "-e",
    `JSON.stringify(Application("TextEdit").documents.byName(${JSON.stringify(title)}).text())`,
  ], { encoding: "utf8" }));
  const receipts = [];
  try {
    execFileSync("/usr/bin/open", ["-a", "TextEdit", file]);
    let snapshot;
    for (let attempt = 0; attempt < 20; attempt++) {
      try {
        snapshot = await daemonCall("computer.windowState", {
          app: "TextEdit", title, maxDepth: 8, maxElements: 200, capture: false,
        });
        if (snapshot.elements.some(e => e.role === "AXTextArea" && e.value?.includes(marker))) break;
      } catch { /* Wait for the owned document to enter the desktop inventory. */ }
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    assert.ok(snapshot?.elements.some(e => e.role === "AXTextArea" && e.value?.includes(marker)));
    let expected = "";
    for (const [text, append] of [
      ["  Lattices: observe, act, verify.\n\tWhitespace stays intact.  \n", false],
      ["  " + "Full document content. ".repeat(30) + "\n", false],
      ["\nAppended without losing the original text.\n", true],
    ]) {
      snapshot = await daemonCall("computer.windowState", { app: "TextEdit", title, capture: false });
      const editor = snapshot.elements.find(e => e.role === "AXTextArea");
      assert.ok(editor);
      const previous = readText();
      expected = append ? expected + text : text;
      const result = await daemonCall("computer.typeElement", {
        snapshotId: snapshot.snapshotId, elementId: editor.id, text, append,
        treatment: "execute", capture: false, source: "release-text-regression",
      });
      receipts.push(result);
      assert.equal(result.typed, true);
      assert.equal(result.verified, true);
      assert.equal(result.result.previousValue, previous);
      assert.equal(result.result.verifiedValue, expected);
      assert.equal(readText(), expected, "TextEdit must independently report the complete result");
    }
    const capture = await daemonCall("capture.screenshotWindow", {
      app: "TextEdit", title, source: "release-text-regression",
    });
    assert.equal(capture.ok, true);
    if (output) {
      mkdirSync(output, { recursive: true });
      writeFileSync(path.join(output, "computer-text-regression.json"), JSON.stringify({ receipts, capture }, null, 2));
      copyFileSync(capture.artifact.path, path.join(output, "computer-text-regression.png"));
    }
  } finally {
    try {
      execFileSync("/usr/bin/osascript", ["-e", `tell application "TextEdit" to close (documents whose name is ${JSON.stringify(title)}) saving no`]);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }
});
