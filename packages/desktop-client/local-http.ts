import { request } from "node:http";
import { localEndpoint, readLocalToken, validateLocalSocket } from "./local-ipc.ts";

/** Read a product's private HTTP endpoint without a TCP fallback. */
export async function localHTTPGet<T>(product: string, path: string, timeoutMs = 3000): Promise<T> {
  if (!path.startsWith("/") || /[\r\n]/.test(path)) throw new Error("Invalid local request path");
  const endpoint = localEndpoint(product);
  validateLocalSocket(endpoint.socketPath!);
  const token = readLocalToken(endpoint.tokenFile!);
  return new Promise((resolve, reject) => {
    const req = request({ socketPath: endpoint.socketPath, path, method: "GET", headers: { Host: "localhost", "x-lattices-token": token } }, response => {
      const chunks: Buffer[] = []; let size = 0;
      response.on("error", reject);
      response.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > 1024 * 1024) { req.destroy(new Error("Local HTTP reply exceeds limit")); return; }
        chunks.push(chunk);
      });
      response.on("end", () => {
        if ((response.statusCode ?? 500) >= 400) { reject(new Error(`Local product returned HTTP ${response.statusCode}`)); return; }
        try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")) as T); } catch (error) { reject(error); }
      });
    });
    const timer = setTimeout(() => req.destroy(new Error("Local HTTP request timed out")), timeoutMs);
    req.on("error", reject);
    req.on("close", () => clearTimeout(timer));
    req.end();
  });
}
