import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { VirtualSpace } from "../src/virtual-space.ts";
import { Router } from "../src/router.ts";
import { serve } from "../src/server.ts";
import { daemonCallTo } from "../../../bin/daemon-client.ts";

async function fixture(action:(v:VirtualSpace,endpoint:{host:string;port:number})=>Promise<void>) {
  const root=mkdtempSync("/tmp/lats-caller-");
  const worker=join(root,"worker.ts");
  expect(resolve(worker).startsWith(root+"/")).toBe(true);
  writeFileSync(worker,`
    import { createWriteStream } from "node:fs";
    import { createInterface } from "node:readline";
    import { VirtualRequestQueue } from ${JSON.stringify(resolve(import.meta.dir,"../src/virtual-request-queue.ts"))};
    const out=createWriteStream("",{fd:3});
    const emit=(v:any)=>out.write(JSON.stringify(v)+"\\n");
    let inputs=0;
    const queue=new VirtualRequestQueue(async(method,params)=>{
      if(method==="status")return {windows:[],inputs};
      if(method==="computer.observe")await Bun.sleep(Number(params.delay));
      else { inputs++; if(params.slow)await Bun.sleep(500); }
      return {ok:true,inputs};
    },emit);
    const lines=createInterface({input:process.stdin});
    lines.on("line",line=>{const r=JSON.parse(line); if(r.cancel!==undefined)queue.cancel(r.cancel); else void queue.enqueue(r)});
    lines.on("close",()=>{queue.stop();process.exit(0)});
    emit({event:"ready"});
  `);
  const v=new VirtualSpace(()=>{},{runtimeRoot:root,workerArgs:[worker],available:()=>({available:true,reason:null})});
  const router=new Router(()=>new Set());
  for(const method of ["computer.observe","computer.click","computer.typeText"])router.register({method,access:method==="computer.observe"?"read":"mutate",description:"fixture",returns:"",handler:p=>v.perform(method,p) as any});
  router.register({method:"host.describe",access:"read",description:"fixture",returns:"",handler:()=>({hostname:"fixture",capabilities:[],methods:[],displays:[]})});
  const server=serve({hosts:["127.0.0.1"],port:0,policy:{allowUsers:[],allowTags:[]},router,pairing:null,log:()=>{}});
  try {await v.start({}); await action(v,{host:"127.0.0.1",port:server.ports[0]!});}
  finally {server.stop();await v.stop();rmSync(root,{recursive:true,force:true});}
}

test("actual app backend 5s caller deadline cancels queued click behind 6.2s observe; data-path type also cancels; retry once",()=>fixture(async(v,endpoint)=>{
  const backend=spawn(process.execPath,[resolve(import.meta.dir,"../../../apps/linux/backend.ts")],{env:{...process.env,LATTICES_LINUX_PORT:String(endpoint.port)},stdio:["pipe","pipe","pipe"]});
  const messages:any[]=[];
  const lines=createInterface({input:backend.stdout!});
  lines.on("line",line=>messages.push(JSON.parse(line)));
  const wait=async(predicate:()=>boolean,timeout=8000)=>{
    const start=Date.now();while(!predicate()){if(Date.now()-start>timeout)throw Error("backend receipt timeout: "+JSON.stringify(messages));await Bun.sleep(10);}
  };
  try {
    await wait(()=>messages.some(m=>m.type==="state"));
    const observing=daemonCallTo(endpoint,"computer.observe",{space:"virtual",delay:6200},20000);
    await Bun.sleep(50);
    const started=Date.now();
    backend.stdin!.write(JSON.stringify({method:"computer.click",params:{space:"virtual",x:10,y:10,treatment:"execute"}})+"\n");
    const typing=daemonCallTo(endpoint,"computer.typeText",{space:"virtual",text:"fixture-only",treatment:"execute"},5000).catch(e=>e);
    await wait(()=>messages.some(m=>m.type==="error"));
    expect(Date.now()-started).toBeGreaterThanOrEqual(4900);
    expect(messages.find(m=>m.type==="error").message).toContain("cancelled before starting");
    expect(((await typing) as Error).message).toContain("cancelled before starting");
    await observing;
    expect((await v.status() as any).inputs).toBe(0);
    backend.stdin!.write(JSON.stringify({method:"computer.click",params:{space:"virtual",x:10,y:10,treatment:"execute"}})+"\n");
    await wait(()=>messages.some(m=>m.type==="done"));
    expect(messages.find(m=>m.type==="done").result.inputs).toBe(1);
    expect((await v.status() as any).inputs).toBe(1);
  } finally {backend.kill("SIGTERM");await new Promise<void>(r=>{if(backend.exitCode!==null)r();else backend.once("exit",()=>r())});lines.close();}
}),12000);

test("started action deadline reports uncertain outcome, never safe cancellation",()=>fixture(async(v,endpoint)=>{
  await expect(daemonCallTo(endpoint,"computer.click",{space:"virtual",slow:true,treatment:"execute"},50)).rejects.toThrow("outcome uncertain");
  await Bun.sleep(550);
  expect((await v.status() as any).inputs).toBe(1);
}));

test("raw/data-path websocket disconnect cancels queued input before its longer wire deadline",()=>fixture(async(v,endpoint)=>{
  const observing=daemonCallTo(endpoint,"computer.observe",{space:"virtual",delay:400},2000);
  await Bun.sleep(20);
  const socket=new WebSocket("ws://127.0.0.1:"+endpoint.port);
  await new Promise<void>((r,j)=>{socket.onopen=()=>r();socket.onerror=()=>j(Error("connect"))});
  socket.send(JSON.stringify({id:"gone",method:"computer.click",deadline:Date.now()+2000,params:{space:"virtual",treatment:"execute"}}));
  await Bun.sleep(30);socket.close();
  await observing;
  expect((await v.status() as any).inputs).toBe(0);
}));

test("published SDK transport carries caller deadline to queued virtual input",()=>fixture(async(v,endpoint)=>{
  const path=resolve(import.meta.dir,"../../npm/sdk/cua.mjs");
  const source=readFileSync(path,"utf8");
  expect(source).toContain('const DAEMON_PORT = 9399;');
  // Redirect only the fixed SDK port to our ephemeral fixture; no real daemon.
  const isolated=source.replace('const DAEMON_PORT = 9399;','const DAEMON_PORT = '+endpoint.port+';');
  const sdk=await import("data:text/javascript;base64,"+Buffer.from(isolated).toString("base64"));
  const observing=daemonCallTo(endpoint,"computer.observe",{space:"virtual",delay:400},2000);
  await Bun.sleep(20);
  await expect(sdk.daemonCall("computer.click",{space:"virtual",treatment:"execute"},50)).rejects.toThrow("cancelled before starting");
  await observing;
  expect((await v.status() as any).inputs).toBe(0);
}));

test("unconfirmed client transport timeout and early close are uncertain, not retry-safe errors",async()=>{
  for(const earlyClose of [false,true]) {
    const server=Bun.serve({hostname:"127.0.0.1",port:0,fetch(req,server){if(server.upgrade(req))return;return new Response("no",{status:400})},
      websocket:{message(ws,raw){
        const request=JSON.parse(String(raw));
        expect(request.deadline).toBeNumber();
        if(earlyClose)ws.close();
      }}});
    try {
      await expect(daemonCallTo({host:"127.0.0.1",port:server.port!},"computer.click",{space:"virtual",treatment:"execute"},30)).rejects.toThrow("outcome uncertain");
    } finally {server.stop(true);}
  }
},4000);

test("raw clients without a caller deadline cannot queue virtual mutations",()=>fixture(async(v,endpoint)=>{
  const socket=new WebSocket("ws://127.0.0.1:"+endpoint.port);
  await new Promise<void>((r,j)=>{socket.onopen=()=>r();socket.onerror=()=>j(Error("connect"))});
  const response=new Promise<any>(r=>socket.onmessage=e=>r(JSON.parse(String(e.data))));
  socket.send(JSON.stringify({id:"unsafe",method:"computer.click",params:{space:"virtual",treatment:"execute"}}));
  try {expect((await response).error).toContain("require an absolute request deadline");}
  finally {socket.close();}
  expect((await v.status() as any).inputs).toBe(0);
}));
