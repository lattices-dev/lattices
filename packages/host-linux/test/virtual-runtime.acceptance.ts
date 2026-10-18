// Opt-in only: bun packages/host-linux/test/virtual-runtime.acceptance.ts
// Owns only temporary files, private headless Sway, and disposable foot windows.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readdirSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { VirtualSpace } from "../src/virtual-space.ts";
import { scopeFor } from "../src/pairing.ts";

if (process.argv[2] === "__virtual-space-worker") {
  const { runVirtualSpaceWorker } = await import("../src/virtual-space-worker.ts");
  await runVirtualSpaceWorker();
} else {
  const root = mkdtempSync(join(tmpdir(), "lats-sway-acceptance-"));
  const virtual = new VirtualSpace(() => {}, {runtimeRoot: root});
  const physical = async () => {
    const query = async (name: string) => {
      const child = Bun.spawn(["hyprctl","-j",name],{stdout:"pipe",stderr:"pipe"});
      const text = await new Response(child.stdout).text();
      assert.equal(await child.exited,0);
      return JSON.parse(text);
    };
    return { cursor: await query("cursorpos"), focused: (await query("activewindow")).address };
  };
  const before = await physical();
  const groups = new Set<number>();
  const pids = new Set<number>();
  function collect() {
    for (const name of readdirSync("/proc").filter(n=>/^\d+$/.test(n))) {
      try {
        const env = readFileSync("/proc/"+name+"/environ","utf8");
        if (!env.includes("XDG_RUNTIME_DIR="+root+"/")) continue;
        const fields = readFileSync("/proc/"+name+"/stat","utf8").split(") ").at(-1)!.split(" ");
        groups.add(Number(fields[2])); pids.add(Number(name));
      } catch {}
    }
  }
  async function cleanupEvidence() {
    assert.deepEqual(readdirSync(root),[]);
    const survivors: number[] = [];
    for (const name of readdirSync("/proc").filter(n=>/^\d+$/.test(n))) {
      try {
        const fields = readFileSync("/proc/"+name+"/stat","utf8").split(") ").at(-1)!.split(" ");
        if (fields[0] !== "Z" && (pids.has(Number(name)) || groups.has(Number(fields[2])))) survivors.push(Number(name));
      } catch {}
    }
    assert.deepEqual(survivors,[]);
    console.log("CLEANUP", {ownedPids:[...pids],ownedGroups:[...groups],survivors,runtimeEntries:readdirSync(root)});
  }
  try {
    for (let cycle=0;cycle<3;cycle++) {
      const status = await virtual.start({width:800,height:600});
      assert.equal(status.running,true);
      assert.equal(scopeFor({method:"computer.virtual.launch",access:"mutate"}),"drive");
      const output = join(root,"typed.txt");
      await virtual.launch({app:"foot",args:["--title=Lattices disposable acceptance","-e","sh","-c",`cat > '${output}'; sleep 120 & wait`]});
      let windows: any[]=[];
      for (let i=0;i<60;i++) {
        windows = (await virtual.status() as any).windows;
        if (windows.length) break;
        await Bun.sleep(50);
      }
      assert.equal(windows.length,1);
      const wid=windows[0].wid;
      const perform = (method:string, params: any) => virtual.perform(method,{space:"virtual",wid,...params});
      await assert.rejects(perform("computer.click",{wid:999999,x:10,y:10,treatment:"execute"}),/No matching/);
      await assert.rejects(perform("computer.typeText",{session:"host-session",text:"forbidden",treatment:"execute"}),/host tmux/);
      assert.equal((await perform("computer.typeText",{text:"STAGED",treatment:"stage"}) as any).status,"staged");
      assert.ok(!existsSync(output) || readFileSync(output,"utf8")==="");
      await perform("computer.click",{xRatio:0.5,yRatio:0.5,treatment:"execute"});
      await perform("computer.typeText",{text:"private-runtime-only",enter:true,treatment:"execute"});
      await perform("computer.hotkey",{shortcut:"ctrl+d",treatment:"execute"});
      for (let i=0;i<40 && (!existsSync(output) || !readFileSync(output,"utf8"));i++) await Bun.sleep(50);
      assert.equal(readFileSync(output,"utf8"),"private-runtime-only\n");
      const shot = await virtual.capture() as any;
      assert.equal(shot.width,800); assert.equal(shot.height,600); assert.ok(shot.image.length>100);
      collect();
      console.log("RUNTIME", {cycle,wid,captureBytes:Buffer.from(shot.image,"base64").length,typed:readFileSync(output,"utf8").trim()});
      if (cycle === 2) {
        const worker = [...pids].find(pid => {
          try {
            const args = readFileSync("/proc/" + pid + "/cmdline", "utf8").split("\0");
            return args[0] === process.execPath && args.includes("__virtual-space-worker");
          } catch { return false; }
        });
        assert.ok(worker, "private worker PID discovered from its runtime environment");
        process.kill(worker, "SIGKILL");
        for (let i=0;i<60;i++) {
          const state = await virtual.status().catch(() => ({running:true}));
          if (!state.running) break;
          await Bun.sleep(50);
        }
        console.log("CRASH", {worker, running:(await virtual.status()).running});
      }
      await virtual.stop();
      rmSync(output,{force:true});
      await cleanupEvidence();
    }
    assert.deepEqual(await physical(),before);
    console.log("PHYSICAL_UNCHANGED",before);
  } finally {
    await virtual.stop();
    rmSync(root,{recursive:true,force:true});
  }
}
