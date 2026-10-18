import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { findEntryBySlug } from "@/studio/lib/engDocs";

/** design/studio lives two levels below the repo root. */
const REPO_ROOT = path.resolve(process.cwd(), "../..");

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ slug: string }> },
) {
  const { slug } = await params;
  const entry = findEntryBySlug(slug);
  if (!entry) {
    return NextResponse.json({ error: `Unknown doc: ${slug}` }, { status: 404 });
  }

  // sourcePath is repo-relative and comes from our own registry, never the
  // request — but re-check containment so a bad entry can't escape the repo.
  const file = path.resolve(REPO_ROOT, entry.sourcePath);
  if (!file.startsWith(`${REPO_ROOT}${path.sep}`)) {
    return NextResponse.json({ error: "Invalid source path" }, { status: 400 });
  }

  try {
    const body = await readFile(file, "utf8");
    return new NextResponse(body, {
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  } catch {
    return NextResponse.json(
      { error: `Missing file: ${entry.sourcePath}` },
      { status: 404 },
    );
  }
}
