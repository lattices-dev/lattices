"""Render Lattices' four vector product specification sheets and source catalog.
Run with the Codex bundled Python runtime (reportlab + pypdf).
"""
from pathlib import Path
import json, re, csv, subprocess, hashlib
from xml.sax.saxutils import escape
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor, Color
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph
from pypdf import PdfReader, PdfWriter

ROOT = Path(__file__).resolve().parent
REPO = Path('/Users/arach/dev/lattices')
OUT = ROOT / 'output' / 'pdf'
OUT.mkdir(parents=True, exist_ok=True)
FONTS = ROOT / 'source/fonts'
pdfmetrics.registerFont(TTFont('Plex', str(FONTS/'ibm-plex-mono-400.ttf')))
pdfmetrics.registerFont(TTFont('PlexB', str(FONTS/'ibm-plex-mono-700.ttf')))
W,H = 595.2756,841.8898
INK = HexColor('#242722')
MUTED = HexColor('#61675e')
LINE = HexColor('#b9beb2')
PAPER = HexColor('#f6f5ef')
LIGHT = HexColor('#e8ebe2')
ORANGE = HexColor('#c64c2b')
FAINT = HexColor('#dfE2d8')
WHITE = HexColor('#fffefa')
M = 34
CW = W-2*M
C=None
WARN=[]

def rect(x,y,w,h,fill=None,stroke=LINE,lw=.65):
    C.setLineWidth(lw)
    if fill: C.setFillColor(fill)
    if stroke: C.setStrokeColor(stroke)
    C.rect(x,H-y-h,w,h,stroke=int(stroke is not None),fill=int(fill is not None))

def line(x,y,x2,y2,color=LINE,lw=.65,dash=None):
    C.setStrokeColor(color); C.setLineWidth(lw)
    C.setDash(dash or [])
    C.line(x,H-y,x2,H-y2)
    C.setDash([])

def poly(points,fill=None,stroke=LINE,lw=.65):
    C.setLineWidth(lw); C.setStrokeColor(stroke)
    if fill:C.setFillColor(fill)
    p=C.beginPath();p.moveTo(points[0][0],H-points[0][1])
    for x,y in points[1:]:p.lineTo(x,H-y)
    p.close();C.drawPath(p,stroke=1,fill=int(fill is not None))

def text(x,y,s,size=9,font='Helvetica',color=INK):
    C.setFillColor(color); C.setFont(font,size)
    C.drawString(x,H-y-size*.82,s)

def right(x,y,s,size=8,font='Plex',color=MUTED):
    C.setFillColor(color); C.setFont(font,size)
    C.drawRightString(x,H-y-size*.82,s)

def para(x,y,w,s,size=9,leading=12.2,color=INK,font='Helvetica',maxh=None):
    st=ParagraphStyle('p',fontName=font,fontSize=size,leading=leading,textColor=color,spaceAfter=0)
    p=Paragraph(s,st); aw,ah=p.wrap(w,1000)
    if maxh is not None and ah>maxh+.1:WARN.append(f'Text overflow {ah}>{maxh}: {s[:75]}')
    p.drawOn(C,x,H-y-ah)
    return ah

def label(x,y,s,color=MUTED,size=7.2):text(x,y,s,size,'Plex',color)

def badge(x,y,n):
    rect(x,y,19,16,ORANGE,None)
    text(x+3.2,y+3.6,n,8,'PlexB',WHITE)

def arrow(x,y,x2,y2,color=INK):
    line(x,y,x2,y2,color,.75)
    import math
    a=math.atan2(y2-y,x2-x)
    for da in [-.55,.55]:
        line(x2,y2,x2-4*math.cos(a+da),y2-4*math.sin(a+da),color,.75)

def tick(x,y,n=3):
    line(x-n,y,x+n,y,LINE,.5);line(x,y-n,x,y+n,LINE,.5)

def dim(x,y,x2,y2,s):
    line(x,y,x2,y2,MUTED,.5)
    if y==y2:
        line(x,y-3,x,y+3,MUTED,.5);line(x2,y-3,x2,y+3,MUTED,.5)
        sw=pdfmetrics.stringWidth(s,'Plex',6.5);rect((x+x2-sw)/2-4,y-4,sw+8,9,PAPER,None)
        label((x+x2-sw)/2,y-3,s,size=6.5)
    else:
        line(x-3,y,x+3,y,MUTED,.5);line(x2-3,y2,x2+3,y2,MUTED,.5)

def logo(x,y,sz=3.7):
    for r in range(3):
        for q in range(3):rect(x+q*(sz+1.5),y+r*(sz+1.5),sz,sz,INK if q==0 or r==2 else None,INK,.5)

def start(filename,num,kicker,title,subtitle):
    global C
    C=canvas.Canvas(str(OUT/filename),pagesize=(W,H),pageCompression=1)
    C.setTitle(f'Lattices / {title} / {num}')
    C.setAuthor('Lattices')
    C.setSubject('Functionality specification; current working-source audit dated 2026-10-02')
    rect(0,0,W,H,PAPER,None)
    logo(M,27)
    label(M+23,30,'LATTICES / PRODUCT SYSTEM',INK,7.4)
    right(W-M,30,f'FUNCTIONAL SPECIFICATION  /  {num}',7)
    line(M,52,W-M,52,INK,.85)
    label(M,67,kicker,ORANGE,8)
    text(M,87,title,38,'Helvetica-Bold')
    para(M,135,CW-15,subtitle,11,14.4,MUTED,maxh=32)

def figbox(name,tag='SCHEMATIC / NOT TO SCALE'):
    rect(M,181,CW,218,None,LINE,.65)
    label(M+12,192,name,INK,7)
    right(W-M-12,192,tag,6.5)
    for x in [M,W-M]:
        for y in [181,399]:tick(x,y,3)

def footer(num,title,refs):
    line(M,761,W-M,761,INK,.8)
    label(M,770,'DRAWING',size=6.3);text(M,782,'LAT-FS-'+num,9,'PlexB')
    line(130,766,130,806,LINE,.5)
    label(140,770,'ISSUE / BASIS',size=6.3);text(140,783,'A / Working source',8.8)
    line(290,766,290,806,LINE,.5)
    label(300,770,'SOURCE SNAPSHOT',size=6.3);text(300,783,'02 Oct 2026',8.8)
    line(423,766,423,806,LINE,.5)
    label(434,770,'SHEET / SERIES',size=6.3);text(434,783,f'{int(num)+1:02d} / 04',9,'PlexB')
    label(M,817,'lattices.dev',size=6.6)
    right(W-M,817,'SOURCE INDEX  /  '+refs,6.3)
    C.showPage();C.save()

def blocks(items,y=433,h=66):
    gap=24;col=(CW-gap)/2
    for i,(code,title,body) in enumerate(items):
        x=M+(i%2)*(col+gap); yy=y+(i//2)*h
        line(x,yy,x+col,yy,LINE,.6)
        label(x,yy+9,code,ORANGE,7)
        text(x+25,yy+8,title,11.3,'Helvetica-Bold')
        para(x,yy+26,col,body,9.15,12.0,INK,maxh=h-28)

def strip(y,title,body):
    rect(M,y,CW,42,LIGHT,None)
    label(M+10,y+9,title,INK,6.8)
    para(M+123,y+8,CW-134,body,8.3,10.9,INK,maxh=30)

def plate(x,y,w,h,depth=33,fill=WHITE):
    # A consistent oblique projection; decorative depth is not a measured quantity.
    p=[(x,y),(x+w,y),(x+w+depth,y-22),(x+depth,y-22)]
    poly(p,fill,INK,.75)
    poly([(x,y),(x+w,y),(x+w,y+h),(x,y+h)],PAPER,INK,.65)
    poly([(x+w,y),(x+w+depth,y-22),(x+w+depth,y+h-22),(x+w,y+h)],LIGHT,INK,.65)
    return p

def overview():
    start('00-lattices-overall.pdf','00','SYSTEM OVERVIEW','lattices','A programmable workspace for macOS. Arrange windows, keep project sessions,\nfind context, and give agents a local control surface.')
    figbox('FIG. A / FUNCTIONAL ASSEMBLY')
    # Exploded layered chassis.
    for x in [75,257]:line(x,232,x+30,351,LINE,.6,[2,3])
    plate(68,343,195,10,42,LIGHT)
    for xx in [86,137,188]:
        poly([(xx,336),(xx+42,336),(xx+64,324),(xx+22,324)],WHITE,INK,.6)
        line(xx+8,332,xx+41,332,LINE,.5)
    plate(83,291,178,9,42,WHITE)
    poly([(100,284),(167,284),(193,270),(126,270)],LIGHT,INK,.6)
    poly([(173,284),(244,284),(269,270),(198,270)],WHITE,INK,.6)
    line(106,280,163,280,ORANGE,.9)
    plate(99,238,161,8,42,WHITE)
    for xx in [113,158,203]:poly([(xx,232),(xx+35,232),(xx+50,224),(xx+15,224)],LIGHT,INK,.5)
    for no,y,title,detail in [('01',231,'Workspace system','Projects / sessions / layers'),('02',286,'Desktop control','Windows / displays / input'),('03',342,'Agent system','Observe / act / capture')]:
        line(307,y,329,y,LINE,.6)
        badge(335,y-7,no);text(364,y-7,title,11,'Helvetica-Bold');label(364,y+8,detail,size=6.8)
    label(48,378,'ONE DESKTOP / SHARED CONTEXT / MULTIPLE INTERFACES',size=6.8)
    label(M,419,'CAPABILITY MAP',INK,7)
    # Three full-width readable subsystem rows.
    rows=[('01','Workspace system','Project discovery; declarative tmux panes; launch, attach and repair; configured tab groups; live tab stacks; layers; Overview; search and terminal maps.','SEE SHEET 02'),
          ('02','Desktop control','Focus and place windows; tile and distribute; move between displays and Spaces; arrange in place; use gestures, hotkeys, command bar, OCR and voice input.','SEE SHEET 03'),
          ('03','Agent system','Local API and SDK; browser MCP; computer actions; screenshots and recordings; run artifacts; overlay HUDs; workspace assistant; paired mobile controls.','SEE SHEET 04')]
    for i,(n,t,b,ref) in enumerate(rows):
        yy=438+i*69
        line(M,yy,W-M,yy,LINE,.6);label(M,yy+12,n,ORANGE,8)
        text(M+28,yy+10,t,12,'Helvetica-Bold');label(M+28,yy+30,ref,size=6.3)
        para(M+186,yy+11,CW-186,b,9.1,12.1,maxh=49)
    line(M,645,W-M,645,LINE,.6)
    label(M,661,'COMPANION PRODUCTS',ORANGE,7)
    para(M,680,162,'<b>Action</b><br/>Computer use, browser work,<br/>guided capture and recording.',9.2,12.3)
    para(M+181,680,155,'<b>Blink</b><br/>Floating notes, named desks<br/>and offline mobile reading.',9.2,12.3)
    para(M+359,680,168,'<b>Voice / Speech</b><br/>Queued readouts, voice selection<br/>and a playback HUD.',9.2,12.3)
    label(M,730,'macOS 26+ / NATIVE APP + CLI / tmux OPTIONAL / COMPANIONS INSTALL SEPARATELY',size=6.7)
    footer('00','Overall','W / D / A')

def workspace():
    start('01-workspace-system.pdf','01','SUBSYSTEM 01 / ORGANIZE','Workspace system','Keep a project\'s working context in named sessions, tab groups and layers.\nInspect the desktop without losing the distinction between saved and live state.')
    figbox('FIG. B / CONTEXT ASSEMBLY')
    # Definition -> runtime -> view, with actual implementation concepts.
    ys=[224,277,330]
    values=[('PROJECT DECLARATION','.lattices.json','shell  60%','server  40%'),('PERSISTENT SESSION','project-<hash>','pane 0','pane 1'),('WORKSPACE LAYER','workspace.json','editor','terminal')]
    for i,(tt,file,a,b) in enumerate(values):
        yy=ys[i];rect(53,yy,270,42,WHITE,INK,.65)
        rect(53,yy,4,42,ORANGE if i==2 else LIGHT,None)
        label(65,yy+7,tt,INK,6.3);label(65,yy+23,file,MUTED,7)
        rect(204,yy+8,49,25,LIGHT,LINE,.5);rect(257,yy+8,54,25,None,LINE,.5)
        text(209,yy+17,a,5.8,'Plex');text(261,yy+17,b,5.8,'Plex')
        if i<2:arrow(180,yy+43,180,yy+51,ORANGE)
    for n,y,title,desc in [('01',226,'Declare','Panes, commands, placement'),('02',279,'Resume','Attach, sync, restart'),('03',332,'Compose','Match, focus, tile, reveal')]:
        badge(344,y,n);text(372,y,title,10.8,'Helvetica-Bold');label(344,y+23,desc,size=6.6)
    label(53,383,'CONFIGURATION -> SESSION STATE -> DESKTOP MEMBERSHIP',size=6.6)
    label(M,419,'FUNCTIONAL SPECIFICATION',INK,7)
    blocks([
        ('01','Projects & development','Discover configs, choose among six terminals and launch sessions. Detect dev/build commands for Node, Swift, Rust, Go and Make.'),
        ('02','Session lifecycle','Declare named panes and sizes. List, detach or kill sessions; sync missing panes; restart commands; ensure or prefill on reattach.'),
        ('03','Tab groups','Launch configured project groups and cycle tabs. Build temporary stacks from live windows, then dissolve them when finished.'),
        ('04','Layer rules','Match projects, apps or specific windows. Create, rename, delete, capture and edit layers; add or remove membership.'),
        ('05','Layer switching','Activate, launch and arrange a layer. Park or hide other windows; Show All restores them. Eight direct slots surround a center status key.'),
        ('06','Workspace views','Overview, Studio and HUD maps expose windows and layers. Inspect saved, last-known and live positions; preview, focus and arrange.'),
        ('07','Find context','Search titles, apps, session tags and OCR. Deep search adds live terminal titles, working directories, commands and tmux context.'),
        ('08','Maps & inventory','Read the desktop as an ASCII map or JSON. Inspect managed sessions, terminal instances, processes, display frames and window IDs.')
    ],433,66)
    strip(707,'STATE CONTRACT','Project config defines panes. workspace.json defines layers and groups. Live membership resolves against current windows; CLI map reads do not move them.')
    footer('01','Workspace system','W / '+str(len(json.loads((ROOT/'source/workspaces.json').read_text())))+' RECORDS')

def desktop():
    start('02-desktop-control.pdf','02','SUBSYSTEM 02 / ARRANGE','Desktop control','Shape the workspace through direct manipulation, keyboard chords, gestures\nand commands, with previews and explicit restore paths where supported.')
    figbox('FIG. C / DISPLAY PLAN + WINDOW PLACEMENT')
    # Technical orthographic drawing: dual displays, inset tiled geometry.
    rect(53,236,292,129,WHITE,INK,.85)
    rect(60,243,278,115,None,LINE,.65)
    # virtual grid
    for xx in [129.5,199,268.5]:line(xx,243,xx,358,FAINT,.6,[2,2])
    for yy in [271.75,300.5,329.25]:line(60,yy,338,yy,FAINT,.6,[2,2])
    rect(66,250,127,100,LIGHT,INK,.8);line(66,263,193,263,INK,.6)
    rect(201,250,128,46,None,INK,.75);line(201,261,329,261,INK,.5)
    rect(201,304,128,46,None,ORANGE,.9)
    line(204,309,325,309,ORANGE,.5,[2,2])
    badge(70,331,'01');badge(206,276,'02');badge(206,330,'03')
    # fill indication
    line(256,316,270,338,ORANGE,.9);line(270,338,268,332,ORANGE,.9)
    rect(379,255,146,91,LIGHT,INK,.85);rect(385,261,134,79,WHITE,LINE,.6)
    rect(392,269,61,64,None,INK,.65);rect(458,269,52,30,None,LINE,.65)
    arrow(346,306,376,306,ORANGE)
    line(197,366,197,375,INK,.8);line(170,375,225,375,INK,.8)
    line(451,347,451,359,INK,.8);line(431,359,471,359,INK,.8)
    dim(60,225,338,225,'HALVES / THIRDS / C x R GRIDS')
    dim(379,242,525,242,'DISPLAY 02')
    label(59,384,'01 FOCUS     02 TILE     03 STAGE / APPLY',size=6.6)
    label(381,375,'MOVE / KEEP PROPORTIONS',size=6.3)
    label(M,419,'FUNCTIONAL SPECIFICATION',INK,7)
    blocks([
        ('01','Place & distribute','Halves, quarters, thirds, corners, maximize and custom grids. Fill open cells, distribute selected windows or tile an app family.'),
        ('02','Displays & Spaces','Focus a target window, move it to another monitor or Space, preserve relative geometry, and switch desktops with instant transitions.'),
        ('03','In-place tools','Select real windows; Fill, Grid and Swap act live. Place stages a change. Keep accepts it; Restore returns captured frames and stacking order.'),
        ('04','Navigation surfaces','Command bar, Omni search, window hints, Hyperspace survey, spatial lens, screen map, layer bezel and configurable HUD presets.'),
        ('05','Keyboard & pointer','Edit shortcuts, Caps Lock Hyper/Escape remaps and per-device gesture rules. Use the aim HUD, drag snap, cursor finder and center summon.'),
        ('06','Screen text','AX-first quick scans, deeper Vision OCR, indexed search, recent scans and per-window history. Retention and scan cadence are configurable.'),
        ('07','Voice & hands-off','Push-to-talk and spoken workspace intents; natural-language command preview and advisor. Hands-off mode accepts continued spoken turns.'),
        ('08','Focus & preferences','Spotlight and restore a window with Focus Mode. Configure launch, input, AI and companions; inspect diagnostics, update and relaunch the app.')
    ],433,66)
    strip(707,'OPERATING CONDITIONS','Accessibility enables window and input control. Screen Recording enables screen capture/OCR. Voice input depends on a voice-enabled build and configured services.')
    footer('02','Desktop control','D01-D40')

def agents():
    start('03-agent-system.pdf','03','SUBSYSTEM 03 / AUTOMATE','Agent system','Expose workspace state, actions and evidence to scripts, agents and paired\ndevices. Keep browser tools and companion products explicit in the topology.')
    figbox('FIG. D / CONTROL + EVIDENCE TOPOLOGY')
    # Distinct paths preserve actual current interface boundaries.
    for xx,ww,title,sub in [(53,145,'CLI / SDK / AGENTS','JSON RPC + EVENTS'),(217,146,'BROWSER MCP','14 BROWSER TOOLS'),(383,144,'iPHONE / iPAD','PAIRING + GRANTS')]:
        rect(xx,220,ww,40,WHITE,INK,.7)
        text(xx+9,xx*0+230,title,8.7,'Helvetica-Bold');label(xx+9,246,sub,size=6.1)
    arrow(125,261,125,277,ORANGE)
    arrow(290,261,290,277,ORANGE)
    arrow(455,261,455,277,ORANGE)
    rect(53,280,145,48,LIGHT,INK,.7)
    text(63,290,'Lattices daemon',10.2,'Helvetica-Bold');label(63,308,'127.0.0.1 : 9399',size=6.5)
    rect(217,280,146,48,LIGHT,INK,.7)
    text(228,290,'Chrome automation',10.2,'Helvetica-Bold');label(228,308,'CDP + MANAGED TABS',size=6.3)
    rect(383,280,144,48,LIGHT,INK,.7)
    text(393,290,'Companion bridge',10.2,'Helvetica-Bold');label(393,308,'SEPARATE TRUST BOUNDARY',size=5.8)
    line(126,329,126,342,INK,.65);line(455,329,455,342,INK,.65);line(126,342,455,342,INK,.65)
    arrow(290,342,290,353,ORANGE)
    rect(53,356,474,25,None,INK,.7)
    label(64,365,'WINDOWS / SESSIONS / INPUT / OVERLAYS / RUNS + ARTIFACTS',INK,7)
    label(M,419,'FUNCTIONAL SPECIFICATION',INK,7)
    blocks([
        ('01','Native API & SDK','Local WebSocket RPC, a runtime schema, event subscriptions and TypeScript facades expose workspace, desktop, input and system operations.'),
        ('02','Observe & inspect','Read windows, Spaces, layers, sessions, terminal output and process trees. Resolve targets; inspect AX elements, OCR and screenshots.'),
        ('03','Computer actions','Launch, focus, click, type, set values, press keys, scroll and drag. Stage actions, inspect receipts, verify outcomes and undo eligible placements.'),
        ('04','Capture & runs','Capture windows, regions or displays; record a target or command. Save runs, steps, logs and artifacts; crop/zoom images and apply verification.'),
        ('05','Browser interface','Browser MCP controls isolated Chrome identities: navigate, inspect, click, fill, resize, capture and read console logs. Native browser RPC is separate.'),
        ('06','Assistant & overlays','Workspace chat selects an available agent backend. Publish transient overlays, interactive actors and web HUDs; move them or control visibility.'),
        ('07','Paired mobile control','A separate bridge pairs iPhone/iPad devices with grants and revocation. Deck controls, desktop previews, keyboard and trackpad are capability-gated.'),
        ('08','Product extensions','Separate apps: Action for computer use; Blink for notes and offline mobile reading; Voice for speech queues, voice selection and playback controls.')
    ],433,66)
    strip(707,'INTERFACE CONTRACT','The native daemon is loopback-only with no auth by design. Browser MCP is a distinct toolset. Companion access requires pairing; voice input is hosted on :9398.')
    footer('03','Agent system','A01-A40')


def export_catalog():
    records=[]
    for name in ['workspaces','desktop','integrations']:
        p=ROOT/'source'/f'{name}.json'
        if p.exists():records.extend(json.loads(p.read_text()))
    # Preserve full native API breadth as an independently searchable index.
    api=REPO/'apps/mac/Sources/Core/Daemon/LatticesApi.swift'
    endpoints=[]
    for ap in [api, REPO/'apps/mac/Sources/Core/Daemon/VoiceHelperRouting.swift']:
        api_txt=ap.read_text()
        for m in re.finditer(r'\bmethod:\s*"([\w.]+)"',api_txt):
            endpoints.append({'method':m.group(1),'path':str(ap.relative_to(REPO)),'line':api_txt[:m.start()].count('\n')+1})
    with (ROOT/'output'/'native-api-index.csv').open('w') as f:
        wr=csv.DictWriter(f,fieldnames=['method','path','line']);wr.writeheader();wr.writerows(endpoints)
    browser_path=REPO/'bin/mcp/toolsets/browser/index.ts'
    browser_txt=browser_path.read_text()
    browser_tools=[{'tool':m.group(1),'path':str(browser_path.relative_to(REPO)),'line':browser_txt[:m.start()].count('\n')+1} for m in re.finditer(r'\bname:\s*"(browser_[a-z_]+)"',browser_txt)]
    with (ROOT/'output'/'browser-mcp-index.csv').open('w') as f:
        wr=csv.DictWriter(f,fieldnames=['tool','path','line']);wr.writeheader();wr.writerows(browser_tools)
    with (ROOT/'output'/'functionality-map.csv').open('w') as f:
        wr=csv.writer(f);wr.writerow(['ID','Group','Capability','Details','Status','Caveat','Source evidence'])
        for r in records:
            ev='; '.join(f"{e['path']}:{e.get('lines',e.get('line',''))}" for e in r['evidence'])
            wr.writerow([r['id'],r['group'],r['capability'],r['details'],r['status'],r.get('caveat',''),ev])
    paths={str(api.relative_to(REPO)), 'apps/mac/Sources/Core/Daemon/VoiceHelperRouting.swift'}
    for r in records:
        for e in r['evidence']:paths.add(e['path'])
    fingerprints=[]
    for path in sorted(paths):
        p=REPO/path
        if p.is_file():fingerprints.append({'path':path,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    rev=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
    snapshot={'date':'2026-10-02','basis':'Current native working tree including pre-existing local changes; no runtime or release validation','source_root':str(REPO),'source_branch':subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip(),'source_head':rev,'source_fingerprints':fingerprints,'inventory_rows':len(records),'browser_tool_names':len(browser_tools),'native_endpoint_names':len({e['method'] for e in endpoints}),'notes':['Read current source ahead of docs when they disagree.','Inventories group related operations; native-api-index.csv preserves endpoint-level names.','Figures are conceptual schematics, not screenshots or engineering dimensions.','Draft/proposal features are excluded from the one-pagers.']}
    (ROOT/'source'/'audit-manifest.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    return records,endpoints

if __name__=='__main__':
    records,endpoints=export_catalog()
    overview();workspace();desktop();agents()
    names=['00-lattices-overall.pdf','01-workspace-system.pdf','02-desktop-control.pdf','03-agent-system.pdf']
    writer=PdfWriter()
    for name in names:
        rr=PdfReader(OUT/name)
        assert len(rr.pages)==1, name
        writer.add_page(rr.pages[0])
    writer.add_metadata({'/Title':'Lattices / Functionality specification / Four-sheet set','/Author':'Lattices','/Subject':'Current-source functional map, 02 Oct 2026'})
    with (OUT/'lattices-specification-set.pdf').open('wb') as f:writer.write(f)
    if WARN:raise ValueError('\n'.join(WARN))
    print(json.dumps({'pdfs':5,'pages':[1,1,1,1,4],'inventory_rows':len(records),'endpoint_rows':len(endpoints)}))
