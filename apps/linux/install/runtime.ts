import { existsSync, lstatSync, readdirSync } from "node:fs";
import { join } from "node:path";

const payload = ["bin", "apps/linux", "packages/host-linux/src", "packages/host-linux/systemd", "packages/desktop-client", "packages/host-linux/visitor", "packages/host-linux/package.json", "packages/host-linux/bun.lock", "packages/npm/sdk", "assets/logo-mark.svg", "package.json", "docs"];
const excluded = new Set(["node_modules", ".systemd", "test", "tests", ".git"]);
export function walk(path: string, prefix = ""): string[] {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) throw new Error(`Runtime source contains a symlink: ${path}`);
  if (stat.isFile()) return [prefix];
  return readdirSync(path).sort().filter(name => !excluded.has(name)).flatMap(name => walk(join(path, name), join(prefix, name)));
}
export function runtimeFiles(source: string): string[] {
  return payload.flatMap(item => {
    if (!existsSync(join(source, item))) throw new Error(`Linux runtime source is missing ${item}`);
    return walk(join(source, item), item);
  });
}
