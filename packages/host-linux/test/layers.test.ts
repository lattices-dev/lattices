import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Layers } from "../src/layers.ts";
async function fixture(action: (f: any) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), "lats-layers-"));
  const path = join(root, "workspace.json");
  expect(resolve(path).startsWith(root + "/")).toBe(true);
  const original = { name: "Disposable", unrelated: {keep: true}, layers: [{id:"a",label:"A",projects:[{app:"selected"}]}] };
  writeFileSync(path, JSON.stringify(original));
  const clients = [
    {address:"0x1", class:"selected", title:"Selected", pid:101, monitor:0, workspace:{id:1,name:"1"}},
    {address:"0x2", class:"other", title:"Other", pid:102, monitor:0, workspace:{id:1,name:"1"}},
    {address:"0x3", class:"elsewhere", title:"Other desktop", pid:103, monitor:0, workspace:{id:2,name:"2"}},
    {address:"0x4", class:"display2", title:"Other display", pid:104, monitor:1, workspace:{id:3,name:"3"}},
  ].map(c => ({...c, at:[0,0],size:[300,200],mapped:true,hidden:false,pinned:false,floating:true,fullscreen:0,focusHistoryID:0}));
  const monitors = [{id:0,name:"D0",focused:true,activeWorkspace:{id:1}}, {id:1,name:"D1",focused:false,activeWorkspace:{id:3}}];
  const displays = monitors.map((m,i) => ({displayId:m.name,displayIndex:i,currentSpaceId:m.activeWorkspace.id,visibleFrame:{x:0,y:0,w:800,h:600}}));
  const ops: any[] = []; let fail = false;
  const deps = {
    snapshot: async () => ({clients,monitors,displays,focused:"0x1"}) as any,
    apply: async (operations: any[]) => {
      ops.push(...operations);
      if (fail) throw Error("park failure");
      for (const op of operations) if (op.op === "toWorkspace") {
        const c = clients.find(c => c.address === op.address)!;
        c.workspace = op.workspace === "special:lattices" ? {id:-99,name:"special:lattices"} : {id:op.workspace,name:String(op.workspace)};
      }
      return operations.map(o => o.op);
    },
    place: async () => ({commands: []}) as any,
  };
  const make = () => new Layers(() => {},root,deps);
  try { await action({root,path,original,clients,ops,make,fail:()=>fail=true,recover:()=>fail=false}); }
  finally { rmSync(root,{recursive:true,force:true}); }
}
test("serialized edits preserve unrelated fields and first backup", () => fixture(async ({make,path,original,root}) => {
  const layers = make();
  await Promise.all(["B","C"].map(name=>layers.serialize(()=>layers.edit("layers.create",{name,visible:false}))));
  const saved = JSON.parse(readFileSync(path,"utf8"));
  expect(saved.unrelated).toEqual({keep:true});
  expect(saved.layers.map((l:any)=>l.label)).toEqual(["A","B","C"]);
  expect(JSON.parse(readFileSync(path+".bak","utf8"))).toEqual(original);
  expect(readdirSync(root).sort()).toEqual(["workspace.json","workspace.json.bak"]);
}));
test("park is scoped to focused display/workspace; restart restores exact floating frame", () => fixture(async ({make,ops,clients}) => {
  let layers = make();
  const planned = await layers.activate({layer:"A",dryRun:true});
  expect(planned.parked).toHaveLength(1); expect(ops).toEqual([]);
  await layers.serialize(()=>layers.activate({layer:"A"}));
  expect(ops.filter((o:any)=>o.workspace==="special:lattices").map((o:any)=>o.address)).toEqual(["0x2"]);
  expect(clients[2].workspace.id).toBe(2); expect(clients[3].workspace.id).toBe(3);
  layers = make(); ops.length=0;
  await layers.serialize(()=>layers.reveal());
  expect(ops.map((o:any)=>o.op)).toEqual(["toWorkspace","float","resize","move"]);
  expect(clients[1].workspace.id).toBe(1);
}));
test("partial park failure keeps recovery intent; identity mismatch prevents restore", () => fixture(async ({make,fail,recover,root,clients,ops}) => {
  let layers = make(); fail();
  await expect(layers.serialize(()=>layers.activate({layer:"A"}))).rejects.toThrow("park failure");
  const state = JSON.parse(readFileSync(join(root,"layers-stage-linux.json"),"utf8"));
  expect(state.parked).toHaveLength(1);
  recover();
  // Model an uncertain command that reached the compositor before transport failure.
  clients[1].workspace={id:-99,name:"special:lattices"};
  clients[1].pid=999;
  layers=make(); ops.length=0;
  await layers.serialize(()=>layers.reveal());
  expect(ops).toEqual([]);
}));
