import { readFile } from "node:fs/promises";
import path from "node:path";
import { SPACE_NAVIGATION_ASSETS, SPACE_NAVIGATION_HREF, SPACE_NAVIGATION_SOURCE, spaceNavigationStudies } from "@/studio/lib/spaceNavigationStudies";

export const runtime = "nodejs";

export async function GET(_request: Request, { params }: { params: Promise<{ asset: string[] }> }) {
  const { asset } = await params;
  const requested = asset.join("/");
  const study = spaceNavigationStudies.find((entry) => entry.file === requested);
  const gestureScript = requested === "aperture-lens/gesture.js";
  // Only registered artifacts are readable; this is not a general file server.
  if (!study && !gestureScript && requested !== "baseline.mp4") return new Response("Study not found", { status: 404 });
  const root = path.resolve(process.cwd(), "../..", SPACE_NAVIGATION_SOURCE);
  try {
    const body = await readFile(path.join(root, requested));
    if (gestureScript) return new Response(body, { headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-store" } });
    if (!study) return new Response(body, { headers: { "content-type": "video/mp4", "content-length": String(body.length) } });
    // Keep original studies intact. Their relative navigation opens the matching
    // Studio exhibit so the sidebar, URL, and selected treatment stay together.
    const html = body.toString("utf8").replace(/<a\b([^>]*?)href="([^"]+)"([^>]*)>/g, (tag, before, href, after) => {
      const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(study.file), href));
      const file = (resolved === "." || resolved === "./") ? "index.html" : resolved.replace(/\/$/, "") + (resolved.endsWith(".html") ? "" : "/index.html");
      const destination = spaceNavigationStudies.find((entry) => entry.file === file);
      return destination ? `<a${before}href="${SPACE_NAVIGATION_HREF}/${destination.slug}"${after} target="_top">` : tag;
    }).replace('src="baseline.mp4"', `src="${SPACE_NAVIGATION_ASSETS}/baseline.mp4"`);
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  } catch {
    return new Response("The study source is unavailable. Check the design workspace.", { status: 404 });
  }
}
