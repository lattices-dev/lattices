#!/usr/bin/env bun
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { runFastBrowser, type FastPolicy } from "@action/runtime";

const [tab, policyPath, ...goalWords] = process.argv.slice(2);
if (!tab || !policyPath || !goalWords.length) throw new Error("Usage: bun packages/cli/src/fast-browser.ts <tab-id> <trusted-policy-module> <goal>");
// Operator-supplied code, never model output or page content.
const { default: policy } = await import(pathToFileURL(resolve(policyPath)).href) as { default: FastPolicy };
if (typeof policy?.choose !== "function" || typeof policy?.verify !== "function") throw new Error("Policy must export choose and independent verify functions.");
const result = await runFastBrowser({ tabId: Number(tab), goal: goalWords.join(" "), policy, onStep: step => console.log(JSON.stringify({ event: "step", ...step })) });
console.log(JSON.stringify({ event: "result", ...result }));
if (result.status !== "verified") process.exitCode = 1;
