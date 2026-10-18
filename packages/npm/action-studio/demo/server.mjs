import { extname, join, normalize } from "node:path";

const packageRoot = new URL("..", import.meta.url).pathname;
const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8"
};

const server = Bun.serve({
  port: Number(process.env.PORT || 4177),
  async fetch(request) {
    const url = new URL(request.url);
    const requestPath = url.pathname === "/" ? "/demo/index.html" : url.pathname;
    const safePath = normalize(requestPath).replace(/^(\.\.(\/|\\|$))+/, "");
    const path = join(packageRoot, safePath);
    const file = Bun.file(path);

    if (!(await file.exists())) {
      return new Response("Not found", { status: 404 });
    }

    return new Response(file, {
      headers: {
        "Content-Type": mimeTypes[extname(path)] || "application/octet-stream",
        "Cache-Control": "no-store"
      }
    });
  }
});

console.log("Action Studio preview: http://127.0.0.1:" + server.port);
