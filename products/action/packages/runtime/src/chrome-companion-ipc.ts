import { request } from "node:http";
import { join } from "node:path";
import { runtimeDirectory, readPrivateToken } from "./local-security.js";

export const chromeCompanionSocket = () => join(runtimeDirectory(), "action-chrome.sock");
export const chromeCompanionToken = () => join(runtimeDirectory(), "action-chrome.token");
export async function chromeCompanionRequest<T>(path: string, body?: unknown, timeoutMs = 30_000): Promise<T> {
  const payload = body === undefined ? undefined : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = request({ socketPath: chromeCompanionSocket(), path, method: payload ? "POST" : "GET", headers: {
      Host: "localhost", "x-lattices-token": readPrivateToken(chromeCompanionToken()),
      ...(payload ? { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } : {}),
    } }, res => {
      const chunks: Buffer[] = []; let size = 0;
      res.on("data", chunk => { size += chunk.length; if (size > 16_777_216) { req.destroy(new Error("Companion response exceeds limit")); return; } chunks.push(chunk); });
      res.on("end", () => {
        try {
          const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          if ((res.statusCode ?? 500) >= 400) reject(new Error(value.error ?? `Companion HTTP ${res.statusCode}`)); else resolve(value as T);
        } catch (error) { reject(error); }
      });
    });
    req.on("error", reject); req.setTimeout(timeoutMs, () => req.destroy(new Error("Chrome companion request timed out")));
    req.end(payload);
  });
}
