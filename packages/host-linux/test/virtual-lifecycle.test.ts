import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { VirtualSpace } from "../src/virtual-space.ts";

async function fixture(mode: string, action: (v: VirtualSpace, root: string) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), "lats-lifecycle-"));
  const worker = join(root, "worker.ts");
  expect(resolve(worker).startsWith(root + "/")).toBe(true);
  writeFileSync(worker, `
    import { createWriteStream } from "node:fs";
    import { createInterface } from "node:readline";
    import { VirtualRequestQueue } from ${JSON.stringify(resolve(import.meta.dir,"../src/virtual-request-queue.ts"))};
    const out = createWriteStream("", {fd: 3});
    const emit = (v: any) => out.write(JSON.stringify(v) + "\\n");
    if (${JSON.stringify(mode)} === "fail") { emit({event:"failed", message:"fixture startup failure"}); setTimeout(() => process.exit(1), 10); }
    else if (${JSON.stringify(mode)} !== "startup-stop") emit({event:"ready"});
    let inputs = 0;
    const queue = new VirtualRequestQueue(async method => {
      if (method === "computer.observe") await Bun.sleep(100);
      else if (method === "computer.click") inputs++;
      return {executed:true,inputs};
    }, emit);
    const lines = createInterface({input:process.stdin});
    lines.on("close", () => process.exit(0));
    lines.on("line", line => {
      const r = JSON.parse(line);
      if (r.method === "status") emit({id:r.id,result:{windows:[]}});
      else if (${JSON.stringify(mode)} === "crash") process.exit(2);
      else if (${JSON.stringify(mode)} === "queue") {
        if (r.cancel !== undefined) queue.cancel(r.cancel);
        else void queue.enqueue(r);
      }
      else if (r.cancel) emit({id:r.cancel,error:"Virtual request cancelled before starting"});
      else if (${JSON.stringify(mode)} === "started") emit({id:r.id,event:"started"});
    });
  `);
  const v = new VirtualSpace(() => {}, {runtimeRoot: root, workerArgs: [worker], available: () => ({available:true, reason:null}), requestTimeoutMs: 30, startupTimeoutMs: 200});
  try { await action(v, root); }
  finally { await v.stop(); rmSync(root, {recursive:true,force:true}); }
}
test("startup failure cleans runtime", () => fixture("fail", async (v, root) => {
  await expect(v.start({})).rejects.toThrow("fixture startup failure");
  expect(readdirSync(root)).toEqual(["worker.ts"]);
}));
test("repeated start/stop removes runtime each time", () => fixture("normal", async (v, root) => {
  for (let i=0;i<3;i++) {
    await v.start({});
    await expect(v.perform("computer.click",{space:"wrong"})).rejects.toThrow("Unknown space");
    await v.stop(); expect(readdirSync(root)).toEqual(["worker.ts"]);
  }
}));
test("worker crash settles pending request with uncertain outcome", () => fixture("crash", async v => {
  await v.start({});
  await expect(v.perform("computer.click",{space:"virtual",treatment:"execute"})).rejects.toThrow("uncertain");
}));
test("startup/stop race does not leave running state", () => fixture("startup-stop", async (v, root) => {
  const starting = v.start({}).catch(e => e);
  await Bun.sleep(30); await v.stop();
  expect(await starting).toBeInstanceOf(Error);
  expect((await v.status()).running).toBe(false);
  expect(readdirSync(root)).toEqual(["worker.ts"]);
}));
test("stop settles already-started pending input as uncertain", () => fixture("started", async v => {
  await v.start({});
  const result = v.perform("computer.typeText",{space:"virtual",treatment:"execute"}).catch(e => e);
  await Bun.sleep(10); await v.stop();
  expect(((await result) as Error).message).toContain("uncertain");
}));

test("parent cancellation handshake prevents late queued input; retry executes once", () => fixture("queue", async v => {
  await v.start({});
  const observe = v.perform("computer.observe",{space:"virtual"}).catch(e=>e);
  await Bun.sleep(5);
  await expect(v.perform("computer.click",{space:"virtual",treatment:"execute"})).rejects.toThrow("cancelled before starting");
  expect(((await observe) as Error).message).toContain("uncertain");
  await Bun.sleep(100);
  expect((await v.perform("computer.click",{space:"virtual",treatment:"execute"}) as any).inputs).toBe(1);
}));
