import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const payloadSource = readFileSync(resolve(root, "apps/mac/Sources/Core/Overlays/Overview/OverviewDragPayload.swift"), "utf8");
const payloadType = payloadSource.match(/UTType\(exportedAs: "([^"]+)"/)?.[1];

for (const path of ["apps/mac/Info.plist", "bin/lattices-app.ts", "bin/lattices-dev"]) {
  test(`${path} exports the Overview drag payload type`, () => {
    expect(payloadType).toBeDefined();
    const source = readFileSync(resolve(root, path), "utf8");
    const declarations = source.match(/<key>UTExportedTypeDeclarations<\/key>\s*<array>([\s\S]*?)<\/dict>\s*<\/array>/)?.[1];
    expect(declarations).toBeDefined();
    expect(declarations).toContain(`<string>${payloadType}</string>`);
    expect(declarations).toMatch(/<key>UTTypeConformsTo<\/key>\s*<array>\s*<string>public.data<\/string>/);
  });
}
