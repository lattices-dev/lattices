#!/usr/bin/env bun
import { chromeCompanionRequest } from "../../runtime/src/chrome-companion-ipc.ts";
try {
  const health = await chromeCompanionRequest("/health");
  console.log(JSON.stringify(health, null, 2));
  process.exit(health.connected ? 0 : 1);
} catch (error) { console.error(error.message); process.exit(1); }
