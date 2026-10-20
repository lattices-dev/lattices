#!/usr/bin/env bun
import { gatewayMain } from "../packages/gateway/src/main.ts";

gatewayMain().catch(error => { console.error(`lattices-gateway: ${(error as Error).message}`); process.exitCode = 1; });
