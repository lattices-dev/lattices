// Build a relocatable single-file Bun host with its revision baked in.
// bun packages/host-linux/scripts/build.ts [output.js]
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sourceBuildIdentity } from "../src/build-info.ts";

const identity = sourceBuildIdentity();
if (!identity.commit) throw new Error("Cannot build host with unknown commit; build from its Git checkout");
const entry = fileURLToPath(new URL("../src/main.ts", import.meta.url));
const output = process.argv[2] ? resolve(process.argv[2]) : fileURLToPath(new URL("../dist/lattices-host.js", import.meta.url));
const result = await Bun.build({
  entrypoints: [entry],
  target: "bun",
  // dbus-next loads these optional native/X11 fallbacks lazily. A Wayland
  // session uses its Unix session-bus address and needs neither fallback.
  external: ["x11", "usocket"],
  define: { LATTICES_HOST_BUILD_IDENTITY: JSON.stringify(identity) },
});
if (!result.success) throw new Error(result.logs.map(String).join("\n"));
mkdirSync(dirname(output), { recursive: true });
await Bun.write(output, result.outputs[0]);
console.log(JSON.stringify({ output, build: identity }));
