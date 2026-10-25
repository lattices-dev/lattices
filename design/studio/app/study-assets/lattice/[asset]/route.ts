import { readFile } from "node:fs/promises";
import path from "node:path";

export const runtime = "nodejs";

const captures = new Set([
  "current-overview.png",
  "current-layers.png",
  "current-machines.png",
]);

export async function GET(_request: Request, { params }: { params: Promise<{ asset: string }> }) {
  const { asset } = await params;
  if (!captures.has(asset)) return new Response("Study asset not found", { status: 404 });
  const root = path.resolve(process.cwd(), "../../studies/lattice-surfaces-2026-10-24/captures");
  try {
    const body = await readFile(path.join(root, asset));
    return new Response(body, { headers: { "content-type": "image/png", "cache-control": "no-store" } });
  } catch {
    return new Response("Study capture unavailable", { status: 404 });
  }
}
