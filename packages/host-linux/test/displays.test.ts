import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { displayService, readOwned } from "../src/displays.ts";

const spec = { width: 800, height: 600, refresh: 60, scale: 1 };
async function fixture(fn: (f: any) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), "lats-displays-"));
  const path = join(root, "registry.json");
  expect(resolve(path).startsWith(root + "/")).toBe(true);
  const live = new Set<string>();
  const flags = { mode: false, rollback: false, write: false };
  const service = displayService({
    path,
    monitors: async () => [...live].map(name => ({ name })) as any,
    usesLua: async () => false,
    wait: async (name, present) => { if (live.has(name) !== present) throw Error("wait"); },
    command: async args => {
      await Promise.resolve();
      if (args[0] === "output") {
        if (args[1] === "create") live.add(args[3]!);
        else { if (flags.rollback) throw Error("rollback"); live.delete(args[2]!); }
      } else if (flags.mode) throw Error("mode");
    },
    write: (outputs, dest) => {
      expect(dest).toBe(path);
      if (flags.write) throw Error("write");
      writeFileSync(dest, JSON.stringify({ outputs }));
    },
  });
  try { await fn({ service, live, flags, owned: () => readOwned(path) }); }
  finally { rmSync(root, { recursive: true, force: true }); }
}
test("concurrent distinct creates retain both owners", () => fixture(async ({service, owned}) => {
  await Promise.all(["A", "B"].map(name => service.create({name, spec})));
  expect(owned().map((o: any) => o.name)).toEqual(["A", "B"]);
}));
test("concurrent generated names and overlapping removal serialize", () => fixture(async ({service, owned}) => {
  const results = await Promise.all([service.create({spec}), service.create({spec})]);
  expect(results.map(r => r.name)).toEqual(["LATS-1", "LATS-2"]);
  await Promise.all([service.remove("LATS-1"), service.create({name: "C", spec})]);
  expect(owned().map((o: any) => o.name)).toEqual(["LATS-2", "C"]);
}));
test("mode failure rolls back creation", () => fixture(async ({service, flags, live, owned}) => {
  flags.mode = true;
  await expect(service.create({name: "A", spec})).rejects.toThrow("mode");
  expect([...live]).toEqual([]);
  expect(owned()).toEqual([]);
}));
test("rollback failure retains durable removable ownership", () => fixture(async ({service, flags, live, owned}) => {
  flags.mode = flags.rollback = true;
  await expect(service.create({name: "A", spec})).rejects.toThrow("ownership retained");
  expect(owned()[0].name).toBe("A");
  flags.rollback = false;
  await service.remove("A");
  expect([...live]).toEqual([]);
}));
test("registry failure prevents creation; removal failure retains recovery record", () => fixture(async ({service, flags, live, owned}) => {
  flags.write = true;
  await expect(service.create({name: "A", spec})).rejects.toThrow("write");
  expect([...live]).toEqual([]);
  flags.write = false;
  await service.create({name: "A", spec});
  flags.write = true;
  await expect(service.remove("A")).rejects.toThrow("write");
  expect(owned()[0].name).toBe("A");
  flags.write = false;
  await service.remove("A");
  expect(owned()).toEqual([]);
}));
test("foreign output is rejected unless explicitly adopted", () => fixture(async ({service, live, owned}) => {
  live.add("FOREIGN");
  await expect(service.create({name: "FOREIGN", spec})).rejects.toThrow("adopt");
  await expect(service.remove("FOREIGN")).rejects.toThrow("refusing");
  expect(owned()).toEqual([]);
  await service.create({name: "FOREIGN", spec, adopt: true});
  expect(owned()[0].adopted).toBe(true);
}));
