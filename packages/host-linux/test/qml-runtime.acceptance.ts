// Opt-in smoke on a fresh private Sway seat, never the physical desktop.
// Uses copied, unmodified UI components plus a navigation Timer and fixture backend.
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { VirtualSpace } from "../src/virtual-space.ts";
if (process.argv[2] === "__virtual-space-worker") {
  await (await import("../src/virtual-space-worker.ts")).runVirtualSpaceWorker();
} else {
  const root=mkdtempSync("/tmp/lats-qml-");
  const artifacts=process.env.LATTICES_ACCEPTANCE_ARTIFACTS;
  assert.ok(artifacts,"Set LATTICES_ACCEPTANCE_ARTIFACTS to an explicit temporary/evidence directory");
  const v=new VirtualSpace(()=>{},{runtimeRoot:root});
  const physical=async()=>{
    const get=async(c:string)=>{const p=Bun.spawn(["hyprctl","-j",c],{stdout:"pipe"});const s=await new Response(p.stdout).text();assert.equal(await p.exited,0);return JSON.parse(s)};
    return {cursor:await get("cursorpos"),focus:(await get("activewindow")).address};
  };
  const before=await physical();
  try {
    const ui=join(root,"ui"); cpSync(resolve(import.meta.dir,"../../../apps/linux"),ui,{recursive:true});
    const shell=join(ui,"shell.qml"); let qml=readFileSync(shell,"utf8");
    qml=qml.slice(0,qml.lastIndexOf("}"))+`
      Timer {
        interval: 1100; running: true; repeat: true
        property int step: 0
        onTriggered: {
          const pages=["Home","Overview","Layers","Activity","Settings","Overview"]
          if(step < pages.length) {
            root.page=pages[step]
            overview.virtualView=step===5
            console.log("ACCEPT_PAGE_"+step+"_"+root.page)
            step++
          }
        }
      }
    }\n`;
    writeFileSync(shell,qml);
    const display={displayIndex:0,displayId:"FIXTURE",name:"Disposable",frame:{x:0,y:0,w:1280,h:800},visibleFrame:{x:0,y:0,w:1280,h:800},currentSpaceId:1,spaces:[{id:1,index:1,name:"1",isCurrent:true}],scale:1};
    const window={wid:42,app:"foot",pid:99999,title:"Disposable fixture",frame:{x:20,y:20,w:500,h:400},spaceIds:[1],displayIndex:0,isFocused:true,isOnScreen:true};
    const state={type:"state",online:true,windows:[window],displays:[display],sessions:[],clients:[],pending:[],layers:[{id:"fixture",label:"Fixture layer",index:0,active:false,entries:[{index:0,name:"foot",windows:[window]}]}],active:-1,stage:{parked:[]},layersSupported:true,pairingSupported:true,describe:{hostname:"disposable",capabilities:[],capabilityHealth:{},methods:[]},virtual:{available:true,running:false}};
    const backend=join(root,"backend.ts");
    writeFileSync(backend,`console.log(${JSON.stringify(JSON.stringify(state))}); process.stdin.resume();\n`);
    const bun=join(root,"fixture-bun");
    writeFileSync(bun,`#!/bin/sh\nexec '${process.execPath}' '${backend}'\n`,{mode:0o700});
    const launch=join(root,"launch.sh");
    writeFileSync(launch,`#!/bin/sh
export LATTICES_LINUX_BUN='${bun}'
export XDG_CACHE_HOME='${root}/cache'
export XDG_CONFIG_HOME='${root}/config'
export XDG_STATE_HOME='${root}/state'
export QT_QUICK_BACKEND=software
exec quickshell --path '${ui}' --no-color > '${root}/qml.log' 2>&1
`,{mode:0o700});
    await v.start({width:1280,height:800});
    await v.launch({app:launch});
    for(let step=0;step<6;step++) {
      const marker="ACCEPT_PAGE_"+step+"_";
      let found=false;
      for(let i=0;i<60;i++) {
        const log=existsSync(join(root,"qml.log"))?readFileSync(join(root,"qml.log"),"utf8"):"";
        if(log.includes(marker)){found=true;break}
        if(/Failed to load|Type .* unavailable|SyntaxError|ReferenceError|TypeError/.test(log))throw Error(log);
        await Bun.sleep(100);
      }
      assert.ok(found,"UI page marker "+step);
      await Bun.sleep(150);
      const shot=await v.capture() as any;
      writeFileSync(join(artifacts,"qml-page-"+step+".png"),Buffer.from(shot.image,"base64"));
    }
    const log=readFileSync(join(root,"qml.log"),"utf8");
    writeFileSync(join(artifacts,"qml-runtime.log"),log);
    assert.ok(!/Failed to load|Type .* unavailable|SyntaxError|ReferenceError|TypeError|Binding loop|Cannot assign/.test(log),log);
    console.log("QML_PAGES",log.split("\n").filter(l=>l.includes("ACCEPT_PAGE")));
    await v.stop();
    assert.ok(!readdirSync(root).some(n=>n.startsWith("lattices-virtual-")));
    assert.deepEqual(await physical(),before);
    console.log("PHYSICAL_UNCHANGED",before);
  } finally { await v.stop(); rmSync(root,{recursive:true,force:true}); }
}
