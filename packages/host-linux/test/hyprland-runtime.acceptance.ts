// Opt-in live acceptance: only NEW owned outputs and disposable foot windows.
// No config edits, user-window placement, assignment changes, or typing.
// Restores baseline focus/cursor and asserts preexisting window geometry/workspaces.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import * as hypr from "../src/hyprland.ts";
import * as desktop from "../src/desktop.ts";
import { displayService, readOwned } from "../src/displays.ts";
import { run } from "../src/exec.ts";
import { request } from "../src/hyprland-command.ts";
import { Router } from "../src/router.ts";
import { registerEndpoints } from "../src/endpoints.ts";
import { Layers } from "../src/layers.ts";

assert.equal(process.env.LATTICES_ACCEPT_LIVE_OWNED_OUTPUTS,"1","Explicit live disposable-output opt-in required");
const root=mkdtempSync("/tmp/lats-live-");
const name="LATS-T"+process.pid;
const names=[name+"A",name+"B"];
const apps: ChildProcess[]=[];
const owned=new Set<string>();
const baseline=await desktop.snapshot();
const cursor=await hypr.cursorPos();
const userState=(snap:Awaited<ReturnType<typeof desktop.snapshot>>)=>snap.clients.filter(c=>baseline.clients.some(b=>b.address===c.address)).map(c=>({address:c.address,pid:c.pid,at:c.at,size:c.size,workspace:c.workspace.id,monitor:c.monitor,floating:c.floating})).sort((a,b)=>a.address.localeCompare(b.address));
const before=userState(baseline);
assert.ok(baseline.focused,"Baseline focused window required for exact restore");
assert.ok(!baseline.monitors.some(m=>names.includes(m.name)));
const wait=async(test:()=>Promise<boolean>,label:string)=>{
 for(let i=0;i<100;i++){if(await test())return;await Bun.sleep(50)}
 throw Error("Timed out: "+label);
};
const displays=displayService({
 path:join(root,"owned.json"),monitors:hypr.monitors,usesLua:hypr.usesLua,
 command:async args=>assert.equal((await run("hyprctl",args)).trim(),"ok"),
 wait:(name,present)=>wait(async()=>(await hypr.monitors()).some(m=>m.name===name)===present,"output "+name),
});
async function ownWindow(address:string) {
 assert.ok(owned.has(address),"Mutation must target test-owned window");
 const c=(await hypr.clients()).find(c=>c.address===address)!;
 assert.ok(c && c.class.startsWith(name),"Owned identity must still match");
 return c;
}
const safeApply:typeof hypr.apply=async ops=>{
 for(const op of ops)if("address" in op)await ownWindow(op.address);
 return hypr.apply(ops);
};
let resources:ReturnType<typeof registerEndpoints>|undefined;
let originalError:unknown;
try {
 for(const output of names)await displays.create({name:output,spec:{width:1000,height:800,refresh:60,scale:1}});
 const monitors=await hypr.monitors();
 const a=monitors.find(m=>m.name===names[0])!,b=monitors.find(m=>m.name===names[1])!;
 assert.ok(a&&b&&a.activeWorkspace.id>0&&b.activeWorkspace.id>0);
 console.log("OWNED_OUTPUTS",[{name:a.name,workspace:a.activeWorkspace.id},{name:b.name,workspace:b.activeWorkspace.id}]);
 await hypr.apply([{op:"focusMonitor",monitor:a.name}]);
 async function launch(suffix:string,workspace:number) {
   const child=spawn("foot",["--app-id="+name+suffix,"--title="+name+suffix,"-e","sleep","120"],{detached:true,stdio:"ignore",env:{...process.env,XDG_CONFIG_HOME:join(root,"config"),XDG_CACHE_HOME:join(root,"cache")}});
   apps.push(child);
   await new Promise<void>((resolve,reject)=>{child.once("spawn",resolve);child.once("error",reject)});
   let found:hypr.HyprClient|undefined;
   await wait(async()=>{found=(await hypr.clients()).find(c=>c.pid===child.pid&&c.class===name+suffix);return !!found},"owned foot "+suffix);
   owned.add(found!.address);
   await safeApply([{op:"toWorkspace",address:found!.address,workspace}]);
   await wait(async()=> (await ownWindow(found!.address)).workspace.id===workspace,"workspace move");
   return found!.address;
 }
 const wa=await launch("selected",a.activeWorkspace.id);
 const wb=await launch("other",a.activeWorkspace.id);
 const wc=await launch("display2",b.activeWorkspace.id);
 await safeApply([{op:"float",address:wa},{op:"resize",address:wa,w:400,h:300},{op:"move",address:wa,x:a.x+50,y:a.y+50}]);
 await Bun.sleep(350);
 const initial=await ownWindow(wa);
 const router=new Router(()=>new Set(["windows.place"]));
 resources=registerEndpoints(router,{bindHost:"127.0.0.1",startedAt:Date.now(),clientCount:()=>0},undefined,{apply:safeApply});
 const wid=desktop.widFor(initial);
 await router.dispatch("windows.move",{wid,spaceId:b.activeWorkspace.id});
 await wait(async()=>(await ownWindow(wa)).workspace.id===b.activeWorkspace.id,"move endpoint");
 await router.dispatch("windows.move",{wid,spaceId:a.activeWorkspace.id,dryRun:true});
 assert.equal((await ownWindow(wa)).workspace.id,b.activeWorkspace.id);
 await safeApply([{op:"resize",address:wa,w:500,h:400},{op:"move",address:wa,x:b.x+70,y:b.y+70}]);
 await router.dispatch("windows.moveBack",{wid});
 await wait(async()=>{const c=await ownWindow(wa);return c.workspace.id===initial.workspace.id&&JSON.stringify(c.at)===JSON.stringify(initial.at)&&JSON.stringify(c.size)===JSON.stringify(initial.size)},"exact floating moveBack");
 console.log("FLOATING_MOVEBACK",{wid,at:initial.at,size:initial.size});
 await safeApply([{op:"tile",address:wa}]);
 await wait(async()=>!(await ownWindow(wa)).floating,"tile");
 await router.dispatch("windows.move",{wid,spaceId:b.activeWorkspace.id});
 await safeApply([{op:"float",address:wa}]);
 await router.dispatch("windows.moveBack",{wid});
 await wait(async()=>{const c=await ownWindow(wa);return !c.floating&&c.workspace.id===a.activeWorkspace.id},"tiled moveBack");
 console.log("TILED_MOVEBACK",{wid});
 await hypr.apply([{op:"focusMonitor",monitor:a.name}]);
 const config={name:"Disposable",unrelated:{preserve:true},layers:[]};
 writeFileSync(join(root,"workspace.json"),JSON.stringify(config));
 const deps={snapshot:desktop.snapshot,apply:safeApply,place:desktop.place};
 let layers=new Layers(()=>{},root,deps);
 await layers.serialize(()=>layers.edit("layers.create",{name:"Owned selected",windowIds:[wid],visible:false}));
 assert.deepEqual(JSON.parse(readFileSync(join(root,"workspace.json"),"utf8")).unrelated,config.unrelated);
 assert.deepEqual(JSON.parse(readFileSync(join(root,"workspace.json.bak"),"utf8")),config);
 await layers.serialize(()=>layers.activate({index:0}));
 await wait(async()=>(await ownWindow(wb)).workspace.name==="special:lattices","layer parked");
 assert.equal((await ownWindow(wc)).workspace.id,b.activeWorkspace.id);
 layers=new Layers(()=>{},root,deps);
 await layers.serialize(()=>layers.reveal());
 await wait(async()=>(await ownWindow(wb)).workspace.id===a.activeWorkspace.id,"restart reveal");
 let injected=false;
 layers=new Layers(()=>{},root,{...deps,apply:async ops=>{
   const result=await safeApply(ops);
   if(!injected&&ops.some(op=>op.op==="toWorkspace"&&op.workspace==="special:lattices")){injected=true;throw Error("Injected lost acknowledgement after actual park")}
   return result;
 }});
 await assert.rejects(layers.serialize(()=>layers.activate({index:0})),/Injected lost acknowledgement/);
 assert.ok(JSON.parse(readFileSync(join(root,"layers-stage-linux.json"),"utf8")).parked.length);
 layers=new Layers(()=>{},root,deps);
 await layers.serialize(()=>layers.reveal());
 await wait(async()=>(await ownWindow(wb)).workspace.id===a.activeWorkspace.id,"partial-failure restart reveal");
 console.log("LAYERS",{backup:true,unrelatedPreserved:true,restartRestore:true,partialParkRecovery:true,otherDisplayUntouched:true});
} catch(error) { originalError=error; console.error("ACCEPTANCE_FAILURE",error); }
finally {
 await resources?.virtualSpace.stop();
 for(const child of apps) {
   try{if(child.pid)process.kill(-child.pid,"SIGKILL")}catch(error){if((error as NodeJS.ErrnoException).code!=="ESRCH")throw error}
 }
 await wait(async()=>!(await hypr.clients()).some(c=>owned.has(c.address)),"owned windows closed");
 for(const output of names)if(readOwned(join(root,"owned.json")).some(o=>o.name===output))await displays.remove(output);
 await hypr.apply([{op:"focus",address:baseline.focused!}]);
 assert.equal((await request("/dispatch hl.dsp.cursor.move({ x = "+cursor.x+", y = "+cursor.y+" })")).trim(),"ok");
 await Bun.sleep(350);
 const after=await desktop.snapshot();
 assert.deepEqual(userState(after),before,"Preexisting windows unchanged");
 assert.deepEqual(after.monitors.map(m=>({id:m.id,name:m.name,x:m.x,y:m.y,space:m.activeWorkspace.id})),baseline.monitors.map(m=>({id:m.id,name:m.name,x:m.x,y:m.y,space:m.activeWorkspace.id})),"Baseline output/workspace assignments restored");
 assert.equal(after.focused,baseline.focused);
 assert.deepEqual(await hypr.cursorPos(),cursor);
 assert.ok(!after.monitors.some(m=>names.includes(m.name)));
 console.log("BASELINE_RESTORED",{focus:after.focused,cursor,ownedOutputsAbsent:true,ownedWindowsAbsent:true,preexistingWindowsUnchanged:true});
 rmSync(root,{recursive:true,force:true});
}
if(originalError)throw originalError;
