#!/usr/bin/env bun
import { mkdir, appendFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { runFastBrowser } from "../packages/runtime/src/fast-browser.js";
import { createJevPolicy } from "../packages/runtime/src/providers/jev.js";
import { createFastBrowserPolicy } from "../packages/runtime/src/providers/fast-browser-model.js";

const [tab, expectedURL, ...words] = process.argv.slice(2);
if (!tab || !expectedURL || !words.length) throw new Error("Usage: bun scripts/demo-jev.ts <tab-id> <exact-result-url> <goal>");
const goal = words.join(" ");
const output = resolve(process.env.ACTION_DEMO_OUTPUT ?? `artifacts/jev-${Date.now()}`);
await mkdir(output, { recursive: true });
const verify = async (_goal: string, page: { url: string }) => page.url === expectedURL;
const textProvider = process.env.TEXT_MODEL && process.env.TEXT_MODEL_BASE_URL && process.env.TEXT_MODEL_API_KEY
  ? createFastBrowserPolicy({ baseURL: process.env.TEXT_MODEL_BASE_URL, apiKey: process.env.TEXT_MODEL_API_KEY, model: process.env.TEXT_MODEL, verify })
  : undefined;
const policy = createJevPolicy({ apiKey: process.env.TYPESAFE_API_KEY ?? "", model: process.env.TYPESAFE_MODEL, writeText: textProvider?.writeText, verify });
const pending: Promise<void>[] = [];
console.log(JSON.stringify({ event: "start", goal, output, chooser: process.env.TYPESAFE_MODEL ?? "jev-latest", textModel: process.env.TEXT_MODEL ?? null }));
try {
  const result = await runFastBrowser({ tabId: Number(tab), goal, policy, presentation: process.env.ACTION_WATCH === "1" ? {
    sound: process.env.ACTION_SOUND !== "0",
    volume: Number.isFinite(Number(process.env.ACTION_VOLUME)) ? Number(process.env.ACTION_VOLUME) : 0.35,
  } : false, onStep(step) {
    pending.push(appendFile(resolve(output, "trace.jsonl"), JSON.stringify(step) + "\n"));
    console.log(JSON.stringify({ event: "step", operation: step.decision?.operation, target: "target" in (step.decision ?? {}) ? (step.decision as { target: string }).target : undefined, model: step.decision?.model, confidence: step.decision?.confidence, status: step.receipt?.status, observeMs: step.observeMs, chooseMs: step.chooseMs, textMs: step.textMs, executeMs: step.executeMs, settleMs: step.settleMs }));
  } });
  await Promise.all(pending);
  await writeFile(resolve(output, "result.json"), JSON.stringify({ goal, expectedURL, ...result }, null, 2));
  console.log(JSON.stringify({ event: "result", status: result.status, elapsedMs: result.elapsedMs, steps: result.history.length, output }));
  if (result.status !== "verified") process.exitCode = 1;
} catch (error) {
  await Promise.all(pending);
  await writeFile(resolve(output, "failure.json"), JSON.stringify({ goal, error: error instanceof Error ? error.message : String(error) }, null, 2));
  throw error;
}
