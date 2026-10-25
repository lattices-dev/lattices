"use client";

import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { Activity, AppWindow, ArrowUp, Bot, ChevronDown, ChevronRight, Code, Columns2, Computer, Eye, Globe, Grid2X2, Home, Laptop, Layers, ListChecks, Minus, MousePointer2, Plus, RefreshCw, Search, Server, Settings, Terminal, X } from "lucide-react";
import {
  ALL, UNASSIGNED, hostGroups, hostWindows, layerNames, localDisplays, localWindows, pictureOn, rHosts, rMonitors,
  type HostId, type LocalDisplay, type LocalWindow, type MonitorId, type PhysicalMonitor, type Picture, type RefinedSurface, type WindowKind,
} from "./refined-model";
import "./refined.css";

type Notify = (text: string) => void;

const hostName = (id: HostId | null) => id === null ? "unknown" : rHosts.find(h => h.id === id)!.name;
const monitor = (id: MonitorId) => rMonitors.find(m => m.id === id)!;
const monitorAspect: Record<MonitorId, number> = { aw: 3440 / 1440, dell: 3440 / 1440, u32: 3840 / 2160, air: 2560 / 1664 };
const hostIcon = (id: HostId, size = 14) => id === "air" ? <Laptop size={size} /> : id === "archie" ? <Server size={size} /> : <Computer size={size} />;
const kindIcon = (kind: WindowKind, size = 11) => kind === "terminal" ? <Terminal size={size} /> : kind === "editor" ? <Code size={size} /> : kind === "browser" ? <Globe size={size} /> : <AppWindow size={size} />;
const activateRow = (e: KeyboardEvent<HTMLDivElement>, select: () => void) => {
  if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); select(); }
};

// MARK: Schematic pictures and captured references (review only).

const LINE_W = [62, 38, 76, 28, 54, 70, 44, 22, 66, 50];
function Lines({ n, indent = false }: { n: number; indent?: boolean }) {
  return <>{Array.from({ length: n }, (_, i) => <i key={i} style={{ width: `${LINE_W[i % 10]}%`, marginLeft: indent ? `${(i % 3) * 7}%` : 0 }} />)}</>;
}

// Review-only crops of the supplied October 24 screenshot. Insets exclude its
// baked-in host, monitor, input and viewer labels; the original PNG stays intact.
const CAPTURE_RECTS: Partial<Record<Picture, [number, number, number, number]>> = {
  hypr: [426, 160, 257, 80],
  "term-mix": [357, 296, 255, 61],
  code: [621, 311, 285, 123],
  photo: [694, 160, 190, 94],
};
const LONG_HOST_TITLES: Record<string, string> = {
  "arts-mini: fab · desk": "arts-mini: fab · streaming transcription and clipboard regression checks",
  "Session.swift": "Session.swift — Fab — capture-to-workspace error recovery",
  "nvim · hyprland.conf": "nvim · hyprland.conf — monitor layout and workspace bindings",
  "Calendar": "Calendar — product reviews and release planning for October 24",
};

function Pic({ kind, captured = false }: { kind: Picture; captured?: boolean }) {
  if (kind === "blank") return null;
  const crop = captured ? CAPTURE_RECTS[kind] : undefined;
  if (crop) {
    return <svg className="rf-pic rf-pic--captured" aria-hidden="true" viewBox={crop.join(" ")} preserveAspectRatio="xMidYMid slice">
      <image href="/study-assets/lattice/current-machines.png" width="1760" height="760" />
    </svg>;
  }
  return <div className={`rf-pic rf-pic--${kind}`} aria-hidden="true">
    {kind === "hypr" && <><div className="rf-pane rf-pane--tall"><Lines n={9} /></div><div className="rf-pane"><Lines n={4} /></div><div className="rf-pane"><Lines n={4} /></div></>}
    {kind === "term-mix" && <><div className="rf-pane"><Lines n={8} /></div><div className="rf-pane rf-pane--dim"><Lines n={5} /></div></>}
    {kind === "code" && <><div className="rf-side" /><div className="rf-pane rf-pane--code"><Lines n={11} indent /></div></>}
    {kind === "photo" && <div className="rf-photo" />}
  </div>;
}

// MARK: Shell

const NAV: { name: string; icon: ReactNode; surface?: RefinedSurface; group: string }[] = [
  { name: "Home", icon: <Home size={14} />, group: "Workspace" },
  { name: "Overview", icon: <Columns2 size={14} />, surface: "Overview", group: "Workspace" },
  { name: "Layers", icon: <Layers size={14} />, surface: "Layers", group: "Workspace" },
  { name: "Machines", icon: <Computer size={14} />, surface: "Machines", group: "Workspace" },
  { name: "Assistant", icon: <Bot size={14} />, group: "Agents" },
  { name: "Runs", icon: <ListChecks size={14} />, group: "Agents" },
  { name: "Activity", icon: <Activity size={14} />, group: "System" },
];

function Sidebar({ surface, onSurface }: { surface: RefinedSurface; onSurface: (s: RefinedSurface) => void }) {
  return <aside className="rf-sidebar">
    <div className="rf-traffic" aria-hidden="true"><i /><i /><i /></div>
    <div className="rf-brand"><span className="rf-mark" aria-hidden="true">{Array.from({ length: 9 }, (_, i) => <i key={i} />)}</span>Lattices</div>
    <nav aria-label="Lattices">
      {["Workspace", "Agents", "System"].map(group => <div key={group} className="rf-nav-group">
        <span className="rf-nav-label">{group}</span>
        {NAV.filter(n => n.group === group).map(n => n.surface
          ? <button key={n.name} type="button" className="rf-nav" aria-current={surface === n.surface ? "page" : undefined} onClick={() => onSurface(n.surface!)}>{n.icon}{n.name}</button>
          : <span key={n.name} className="rf-nav rf-nav--inert" title="Outside this study">{n.icon}{n.name}</span>)}
      </div>)}
    </nav>
    <span className="rf-nav rf-nav--inert rf-nav--bottom" title="Outside this study"><Settings size={14} />Settings</span>
  </aside>;
}

function Toolbar({ title, children }: { title: string; children?: ReactNode }) {
  return <header className="rf-toolbar"><h2>{title}</h2><div className="rf-toolbar-actions">{children}</div></header>;
}

function SearchButton({ notify }: { notify: Notify }) {
  return <button type="button" className="rf-btn" onClick={() => notify("Search opens the command palette. It isn't part of this study.")}><Search size={12} />Search<kbd>⌘K</kbd></button>;
}

function StatusBar({ left, right = "Screen text off" }: { left: ReactNode; right?: ReactNode }) {
  return <footer className="rf-status"><span>{left}</span><span>{right}</span></footer>;
}

// MARK: Machines

function useSize<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => setSize({ w: entry.contentRect.width, h: entry.contentRect.height }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, size] as const;
}

type Chip = { kind: "on" | "away" | "unknown" | "offline" | "none"; text: string };

function inputChip(host: HostId, m: PhysicalMonitor, offline: boolean, unknownInput: boolean): Chip {
  if (offline) return { kind: "offline", text: "Offline" };
  if (m.builtin) return { kind: "none", text: "" };
  if (unknownInput && m.id === "aw") return { kind: "unknown", text: "Input unknown" };
  if (m.owner === host) return { kind: "on", text: m.inputs.find(i => i.host === host)?.port ?? "" };
  return { kind: "away", text: `Showing ${hostName(m.owner)}` };
}

function ZoomPill({ zoom, setZoom, reset }: { zoom: number; setZoom: (z: number) => void; reset: () => void }) {
  return <div className="rf-zoom" role="group" aria-label="Canvas zoom">
    <button type="button" aria-label="Zoom out" disabled={zoom <= 0.5} onClick={() => setZoom(Math.max(0.5, zoom - 0.25))}><Minus size={11} /></button>
    <button type="button" aria-label="Fit canvas" title="Fit" onClick={reset}>{Math.round(zoom * 100)}%</button>
    <button type="button" aria-label="Zoom in" disabled={zoom >= 2} onClick={() => setZoom(Math.min(2, zoom + 0.25))}><Plus size={11} /></button>
  </div>;
}

interface MachinesProps { offline: boolean; unknownInput: boolean; contentCheck: boolean; notify: Notify; onSurface: (s: RefinedSurface) => void }

function Machines({ offline, unknownInput, contentCheck, notify, onSurface }: MachinesProps) {
  const [mode, setMode] = useState<"Hosts" | "Desk">("Hosts");
  const [selected, setSelected] = useState<HostId>("arts-mini");
  const [hover, setHover] = useState<HostId | null>(null);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [menu, setMenu] = useState<HostId | null>(null);
  const [armed, setArmed] = useState(true);
  const [visiting, setVisiting] = useState<HostId | null>(null);
  const [main, setMain] = useState<MonitorId>("dell");
  const [viewer, setViewer] = useState<{ host: HostId; monitor: MonitorId; window?: { app: string; title: string } } | null>(null);
  const [canvasRef, size] = useSize<HTMLDivElement>();
  const drag = useRef<{ x: number; y: number; px: number; py: number } | null>(null);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const viewerCloseRef = useRef<HTMLButtonElement>(null);

  const isOffline = (id: HostId) => offline && id === "archie";
  useEffect(() => { if (offline && visiting === "archie") setVisiting(null); }, [offline, visiting]);
  useEffect(() => {
    if (viewer && !dialogRef.current?.open) {
      dialogRef.current?.showModal();
      viewerCloseRef.current?.focus();
    }
  }, [viewer]);
  useEffect(() => {
    if (!menu) return;
    const close = (e: PointerEvent) => { if (!(e.target as HTMLElement).closest(".rf-menu-wrap")) setMenu(null); };
    const esc = (e: globalThis.KeyboardEvent) => { if (e.key === "Escape") setMenu(null); };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("pointerdown", close); document.removeEventListener("keydown", esc); };
  }, [menu]);

  const openViewer = (host: HostId, m: MonitorId, window?: { app: string; title: string }) => { if (host === "local" || isOffline(host)) return; setMenu(null); setViewer({ host, monitor: m, window }); };
  const closeViewer = () => { dialogRef.current?.close(); setViewer(null); };
  const resetView = () => { setZoom(1); setPan({ x: 0, y: 0 }); };
  const startVisit = (id: HostId) => {
    if (!armed) { notify("Visiting is disarmed. Arm it in the toolbar first."); return; }
    setVisiting(id);
    notify(`Visiting ${hostName(id)}: keyboard and pointer go to ${hostName(id)}. Monitor inputs don't change.`);
  };
  const endVisit = () => { if (visiting) notify(`Visit ended. Keyboard and pointer are back on This Mac.`); setVisiting(null); };

  // World bounds: host canvas in points, desk in millimetres. Legend row is outside the fit area.
  const world = mode === "Hosts" ? { w: 1212, h: 335 } : { w: 2641, h: 395 };
  const fitH = Math.max(0, size.h - (mode === "Desk" ? 30 : 0));
  const pad = 36;
  const fit = size.w ? Math.min((size.w - pad * 2) / world.w, (fitH - pad * 2) / world.h) : 0.3;
  const s = Math.max(0.05, fit * zoom);
  const ox = (size.w - world.w * s) / 2 + pan.x;
  const oy = (fitH - world.h * s) / 2 + pan.y;
  const step = Math.min(48, Math.max(12, 16 * zoom));
  const focusHost = hover ?? selected;

  const onDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if ((e.target as HTMLElement).closest("button,.rf-legend")) return;
    drag.current = { x: e.clientX, y: e.clientY, px: pan.x, py: pan.y };
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (d) setPan({ x: d.px + e.clientX - d.x, y: d.py + e.clientY - d.y });
  };

  const status = (id: HostId) => isOffline(id) ? "Unreachable" : visiting === id ? "Visiting" : "Reachable";
  const reachable = rHosts.filter(h => h.id !== "local" && !isOffline(h.id)).length;
  const viewerIsVisiting = viewer !== null && visiting === viewer.host;
  const viewerTitle = viewer ? viewer.window ? `${viewer.window.app} · ${viewer.window.title}` : monitor(viewer.monitor).model : "";

  return <>
    <Toolbar title="Machines">
      {visiting && <button type="button" className="rf-btn rf-btn--visit" onClick={endVisit}><MousePointer2 size={12} />End visit</button>}
      <button type="button" className="rf-btn" onClick={() => notify("Add machine pairs a host over the LAN. Not wired in this study.")}><Plus size={12} />Add machine</button>
      <button type="button" className="rf-btn" aria-pressed={!armed} onClick={() => { if (armed) setVisiting(null); setArmed(!armed); }}>{armed ? "Disarm visiting" : "Arm visiting"}</button>
      <button type="button" className="rf-btn" aria-label="Refresh" onClick={() => notify("Refreshed illustrative data. Nothing was contacted.")}><RefreshCw size={12} /></button>
      <SearchButton notify={notify} />
    </Toolbar>
    <div className="rf-body rf-body--machines">
      <div className="rf-canvas" ref={canvasRef} data-mode={mode} onPointerDown={onDown} onPointerMove={onMove} onPointerUp={() => { drag.current = null; }}
        style={{ "--step": `${step}px`, "--major": `${step * 5}px`, backgroundPosition: `${pan.x}px ${pan.y}px, ${pan.x}px ${pan.y}px` } as CSSProperties}>
        {mode === "Hosts" ? <>
          {hostGroups.map(g => {
            const off = isOffline(g.host);
            const right = Math.max(...g.tiles.map(t => t.x + t.w));
            const bottom = Math.max(...g.tiles.map(t => t.y + t.h));
            return <div key={g.host} className="rf-group" data-selected={selected === g.host} data-hover={hover === g.host} data-offline={off} data-local={g.host === "local"}
              style={{ left: ox + g.x * s, top: oy + g.y * s, width: right * s, height: bottom * s }}
              onPointerEnter={() => setHover(g.host)} onPointerLeave={() => setHover(null)}>
              {g.tiles.map(t => {
                const m = monitor(t.monitor);
                const chip = inputChip(g.host, m, off, unknownInput);
                const away = chip.kind === "away";
                const port = m.inputs.find(i => i.host === g.host)?.port ?? "Input unknown";
                const description = `${hostName(g.host)} · ${m.model} · ${m.resolution} · ${port}${chip.kind === "on" || chip.kind === "none" ? "" : ` · ${chip.text}`}${off ? " · Last seen 4 min ago" : ""}`;
                return <div key={t.monitor} className="rf-tile" data-away={away} data-unknown={chip.kind === "unknown"} style={{ left: t.x * s, top: t.y * s, width: t.w * s, height: t.h * s }}>
                  <button type="button" className="rf-tile-hit" aria-label={`${hostName(g.host)} · ${m.model}`} aria-description={description} title={description} aria-pressed={selected === g.host}
                    onClick={() => setSelected(g.host)} onDoubleClick={() => openViewer(g.host, t.monitor)}>
                    {off ? <span className="rf-tile-note">Last seen 4 min ago</span> : g.host === "local" ? <span className="rf-tile-label">{m.model}</span> : <Pic kind={t.picture} captured={contentCheck} />}
                  </button>
                  {chip.kind !== "none" && <span className="rf-chip rf-chip--input" data-kind={chip.kind}>{chip.kind === "on" && <i className="rf-dot rf-dot--live" />}{chip.text}</span>}
                  <span className="rf-chip rf-chip--monitor" data-reveal={g.tiles.length === 1}>
                    <span>{m.model}{g.host === "local" && main === t.monitor ? " · main" : ""}</span>
                    {g.tiles.length === 1 && !m.builtin && <small>{port}</small>}
                  </span>
                  {g.host !== "local" && !off && <button type="button" className="rf-eye" aria-label={`View ${hostName(g.host)} ${m.model}`} onClick={() => openViewer(g.host, t.monitor)}><Eye size={11} /></button>}
                </div>;
              })}
              <span className="rf-chip rf-chip--host">{hostName(g.host)}</span>
            </div>;
          })}
          <span className="rf-chip rf-chip--virtual" style={{ left: ox + 948 * s, top: oy + 186 * s }}><Plus size={9} />Action Agent Layer</span>
        </> : <>
          {rMonitors.map(m => {
            const unknown = unknownInput && m.id === "aw";
            const owner = unknown ? null : m.owner;
            const lit = m.inputs.some(i => i.host === focusHost);
            const pic = owner && owner !== "local" ? pictureOn[owner]?.[m.id] ?? "blank" : "blank";
            return <div key={m.id} className="rf-tile rf-tile--desk" data-lit={lit} data-unknown={unknown} data-offline={owner ? isOffline(owner) : false}
              style={{ left: ox + m.desk.x * s, top: oy + m.desk.y * s, width: m.desk.w * s, height: m.desk.h * s }}>
              <button type="button" className="rf-tile-hit" aria-label={`${m.model}, ${unknown ? "input unknown" : `showing ${hostName(owner)}`}`}
                onClick={() => owner && setSelected(owner)} onDoubleClick={() => owner && openViewer(owner, m.id)}>
                {owner === "local" ? <span className="rf-tile-label">This Mac</span> : unknown ? <span className="rf-tile-note">Input not read</span> : <Pic kind={pic} captured={contentCheck} />}
              </button>
              {!m.builtin && <span className="rf-inputs" aria-label="Cabled inputs">{m.inputs.map(i => <span key={i.host} data-on={!unknown && m.owner === i.host}><i />{hostName(i.host)}</span>)}{unknown && <em>?</em>}</span>}
              <span className="rf-chip rf-chip--monitor">{m.model}</span>
            </div>;
          })}
          <div className="rf-legend">
            {rHosts.map(h => <button key={h.id} type="button" aria-pressed={selected === h.id} onPointerEnter={() => setHover(h.id)} onPointerLeave={() => setHover(null)} onClick={() => setSelected(h.id)}>{h.name}</button>)}
            <span>Arrangement differs from each host&rsquo;s own layout</span>
          </div>
        </>}
        <div className="rf-segment rf-segment--canvas" role="group" aria-label="Canvas">
          {(["Desk", "Hosts"] as const).map(m => <button key={m} type="button" aria-pressed={mode === m} onClick={() => { setMode(m); resetView(); }}>{m}</button>)}
        </div>
        <ZoomPill zoom={zoom} setZoom={setZoom} reset={resetView} />
      </div>

      <div className="rf-table" role="table" aria-label="Machines">
        <div className="rf-tr rf-th" role="row"><span role="columnheader">Machine</span><span role="columnheader">Status</span><span role="columnheader">Build</span><span role="columnheader" className="rf-num">Displays</span><span role="columnheader"><span className="rf-sr">Actions</span></span></div>
        {rHosts.filter(h => h.id !== "local").map(h => {
          const off = isOffline(h.id);
          const st = status(h.id);
          const group = hostGroups.find(g => g.host === h.id)!;
          return <div key={h.id} role="row" className="rf-tr" tabIndex={0} aria-selected={selected === h.id} onKeyDown={e => activateRow(e, () => setSelected(h.id))} data-selected={selected === h.id} data-hover={hover === h.id} data-offline={off}
            onClick={() => setSelected(h.id)} onPointerEnter={() => setHover(h.id)} onPointerLeave={() => setHover(null)}>
            <span role="cell" className="rf-machine"><span className="rf-machine-icon">{hostIcon(h.id)}</span><span><strong>{h.name}</strong><small>{h.platform}{h.address ? ` · ${h.address}` : ""}</small></span></span>
            <span role="cell" className="rf-state" data-state={st}><i className="rf-dot" />{st}</span>
            <span role="cell" className="rf-build"><span>{h.build}</span>{h.drift && <small>{h.drift}</small>}</span>
            <span role="cell" className="rf-num rf-silhouettes">
              <span aria-hidden="true">{group.tiles.map(t => {
                const m = monitor(t.monitor);
                const showing = m.builtin || (m.owner === h.id && !(unknownInput && m.id === "aw"));
                return <i key={t.monitor} data-showing={showing} style={{ width: (t.w / t.h) * 10 }} />;
              })}</span>{group.tiles.length}
            </span>
            <span role="cell" className="rf-actions" onClick={e => e.stopPropagation()}>
              <span className="rf-visit-slot">{h.visit && (visiting === h.id
                ? <button type="button" className="rf-btn rf-btn--visit" onClick={endVisit}>End</button>
                : <button type="button" className="rf-btn" disabled={off || !armed} title={!armed ? "Visiting is disarmed" : undefined} onClick={() => startVisit(h.id)}>Visit</button>)}</span>
              <span className="rf-menu-wrap">
                <button type="button" className="rf-btn" aria-expanded={menu === h.id} aria-haspopup="menu" onClick={() => setMenu(menu === h.id ? null : h.id)}>View<ChevronDown size={10} /></button>
                {menu === h.id && <span className="rf-menu" role="menu">
                  <button type="button" role="menuitem" disabled={off} onClick={() => openViewer(h.id, group.tiles[0].monitor)}>Lattices viewer{off && <small>Unreachable</small>}</button>
                  <button type="button" role="menuitem" onClick={() => { setMenu(null); notify(`Screen Sharing would open a VNC session to ${h.name}. Nothing was opened.`); }}>VNC in Screen Sharing…</button>
                </span>}
              </span>
            </span>
          </div>;
        })}
      </div>

      <div className="rf-detail">
        <section aria-label={`Windows on ${hostName(selected)}`}>
          <h3>{selected === "local" ? "This Mac" : `Windows on ${hostName(selected)}`}<span>{selected === "local" ? `${localWindows.length} windows` : isOffline(selected) ? "Last known" : `${hostWindows[selected].length} windows`}</span></h3>
          {selected === "local"
            ? <button type="button" className="rf-row" onClick={() => onSurface("Overview")}><Columns2 size={12} /><span>Open in Overview</span><ChevronRight size={11} /></button>
            : hostWindows[selected].map(w => {
              const title = contentCheck ? LONG_HOST_TITLES[w.title] ?? w.title : w.title;
              return <div key={w.title} className="rf-row rf-row--window" data-offline={isOffline(selected)}>
                <span className="rf-row-app">{w.app}</span><span className="rf-row-title" title={title}>{title}</span><span className="rf-row-meta" title={monitor(w.monitor).model}>{monitor(w.monitor).model}</span>
                <button type="button" className="rf-icon-btn" aria-label={`View ${title}`} disabled={isOffline(selected)} onClick={() => openViewer(selected, w.monitor, { ...w, title })}><Eye size={11} /></button>
              </div>;
            })}
        </section>
        <section aria-label="This Mac screens">
          <h3>This Mac<span>2 screens · 1 virtual</span></h3>
          {(["u32", "dell"] as const).map(id => {
            const m = monitor(id);
            const chip = inputChip("local", m, false, unknownInput);
            return <div key={id} className="rf-row">
              <span className="rf-row-title">{m.model}{main === id && <em>main</em>}</span><span className="rf-row-meta">{m.resolution}</span>
              <span className="rf-chip rf-chip--inline" data-kind={chip.kind}>{chip.kind === "on" ? <><i className="rf-dot rf-dot--live" />Showing This Mac</> : chip.text}</span>
              <button type="button" className="rf-btn" onClick={() => notify(`Would gather This Mac's windows onto ${m.model}. Illustrative.`)}>Bring everything here</button>
              <button type="button" className="rf-btn" disabled={main === id} onClick={() => setMain(id)}>Make main</button>
            </div>;
          })}
          <div className="rf-row rf-row--muted"><span className="rf-row-title">Action Agent Layer</span><span className="rf-row-meta">Virtual · 1,920×1,200</span></div>
        </section>
      </div>
    </div>
    <StatusBar left={<>0 sessions running · {reachable} of 3 hosts reachable{visiting && <span className="rf-status-visit"><i className="rf-dot" />Visiting {hostName(visiting)}</span>}</>} />
    {viewer && <dialog ref={dialogRef} className="rf-viewer" aria-label="Lattices viewer" data-window={!!viewer.window} data-visiting={viewerIsVisiting}
      style={{ "--screen-ratio": viewer.window ? 16 / 10 : monitorAspect[viewer.monitor] } as CSSProperties}
      onCancel={e => { e.preventDefault(); closeViewer(); }} onClick={e => { if (e.target === e.currentTarget) closeViewer(); }}>
      <header>
        <div className="rf-viewer-identity"><strong>{hostName(viewer.host)}</strong><span title={viewerTitle}>{viewerTitle}</span></div>
        <span className="rf-viewer-mode">{viewerIsVisiting ? <MousePointer2 size={12} /> : <Eye size={12} />}{viewerIsVisiting ? "Visiting" : "Viewing only"}</span>
        {viewerIsVisiting && <button type="button" className="rf-btn rf-btn--visit" onClick={() => { viewerCloseRef.current?.focus(); endVisit(); }}>End visit</button>}
        <button ref={viewerCloseRef} type="button" className="rf-icon-btn" aria-label="Close viewer" onClick={closeViewer}><X size={15} /></button>
      </header>
      <div className="rf-monitor-frame">
        <div className="rf-viewer-screen">{viewer.window ? <div className="rf-window-preview"><strong>{viewer.window.title}</strong><span>{viewer.window.app} · {monitor(viewer.monitor).model}</span><small>Individual window preview</small></div> : <Pic kind={pictureOn[viewer.host]?.[viewer.monitor] ?? "blank"} captured={contentCheck} />}</div>
        {!viewer.window && <div className="rf-monitor-chin" aria-hidden="true"><span /> <i /></div>}
      </div>
      <footer>
        <span>{visiting ? `Keyboard and pointer are with ${hostName(visiting)}.` : "Keyboard and pointer stay on This Mac."}</span>
        <span>{contentCheck && !viewer.window ? "Captured reference · Oct 24" : "Illustrative preview"} · No connection</span>
      </footer>
    </dialog>}
  </>;
}

// MARK: Overview + Layers shared

interface WorkspaceState {
  layer: string;
  setLayer: (l: string) => void;
  wins: LocalWindow[];
  setWins: (w: LocalWindow[]) => void;
  desktops: Record<LocalDisplay, number>;
  setDesktops: (d: Record<LocalDisplay, number>) => void;
  selection: number[];
  setSelection: (s: number[]) => void;
}

const inLayer = (w: LocalWindow, layer: string) => layer === ALL || (layer === UNASSIGNED ? w.layer === null : w.layer === layer);
const named = (layer: string) => layer !== ALL && layer !== UNASSIGNED;

function LayerRail({ ws }: { ws: WorkspaceState }) {
  const count = (l: string) => ws.wins.filter(w => inLayer(w, l)).length;
  const Item = ({ name, icon }: { name: string; icon: ReactNode }) => {
    const n = count(name);
    return <button type="button" className="rf-rail-item" aria-pressed={ws.layer === name} onClick={() => { ws.setLayer(name); ws.setSelection([]); }}>{icon}<span>{name}</span>{n > 0 && <small>{n}</small>}</button>;
  };
  return <aside className="rf-rail" aria-label="Layers">
    <span className="rf-caption">Layers <b>{layerNames.length}</b></span>
    <Item name={ALL} icon={<Grid2X2 size={12} />} />
    {layerNames.map(l => <Item key={l} name={l} icon={<i className="rf-layer-dot" data-filled={count(l) > 0} />} />)}
    <span className="rf-rail-rule" />
    <Item name={UNASSIGNED} icon={<i className="rf-layer-dot rf-layer-dot--hollow" />} />
    <span className="rf-rail-foot">workspace.json · Read 73s ago</span>
  </aside>;
}

/** Same-scale display widths; the smallest gets the native 1.12 boost when under 0.7 of the widest. */
const displayWeight = (w: number) => w / Math.max(...localDisplays.map(d => d.w)) < 0.7 ? w * 1.12 : w;

const KINDS = ["Terminals", "Editors", "Browsers", "Lattices", "Current Space"] as const;
type KindFilter = typeof KINDS[number] | null;
const kindMatch = (w: LocalWindow, k: KindFilter) => !k || k === "Current Space" || (k === "Terminals" ? w.kind === "terminal" : k === "Editors" ? w.kind === "editor" : k === "Browsers" ? w.kind === "browser" : `${w.app} ${w.title}`.toLowerCase().includes("lattices"));

function Overview({ ws, notify }: { ws: WorkspaceState; notify: Notify }) {
  const [displaysRef, displaysSize] = useSize<HTMLDivElement>();
  const displayScale = Math.max(0, Math.min(
    (displaysSize.w - 16 * (localDisplays.length - 1)) / localDisplays.reduce((sum, d) => sum + displayWeight(d.w), 0),
    (displaysSize.h - 104) / Math.max(...localDisplays.map(d => d.h * displayWeight(d.w) / d.w)),
  ));
  const [kind, setKind] = useState<KindFilter>(null);
  const [query, setQuery] = useState("");
  const [focused, setFocused] = useState<LocalDisplay>("dell");
  const [moveOpen, setMoveOpen] = useState(false);
  const q = query.trim().toLowerCase();
  const visible = (w: LocalWindow) => ws.desktops[w.display] === w.desktop;
  const scoped = ws.wins.filter(w => inLayer(w, ws.layer) && kindMatch(w, kind) && (!q || `${w.app} ${w.title}`.toLowerCase().includes(q)) && (kind !== "Current Space" || visible(w)));
  const inScope = new Set(scoped.map(w => w.id));
  const canArrange = scoped.filter(visible).length;
  const elsewhere = scoped.length - canArrange;
  const selected = ws.wins.filter(w => ws.selection.includes(w.id));
  const one = selected.length === 1 ? selected[0] : null;
  const focusedInfo = localDisplays.find(d => d.id === focused)!;

  const pick = (w: LocalWindow, add: boolean) => {
    setFocused(w.display);
    setMoveOpen(false);
    ws.setSelection(add ? (ws.selection.includes(w.id) ? ws.selection.filter(id => id !== w.id) : [...ws.selection, w.id]) : [w.id]);
  };
  const arrange = (verb: "Tile" | "Distribute") => {
    if (selected.length < 2) return;
    notify(`${verb} ${selected.length} windows — illustrative; no windows moved.`);
  };
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if ((e.target as HTMLElement).tagName === "INPUT") return;
    if (e.key === "t" || e.key === "T") arrange("Tile");
    if (e.key === "d" || e.key === "D") arrange("Distribute");
    if (e.key === "/") { e.preventDefault(); document.getElementById("rf-filter")?.focus(); }
    if (e.key === "Escape") ws.setSelection([]);
  };

  return <>
    <Toolbar title="Overview">
      <button type="button" className="rf-btn" aria-label="Refresh" onClick={() => notify("Reread windows. Illustrative data, nothing changed.")}><RefreshCw size={12} /></button>
      <SearchButton notify={notify} />
    </Toolbar>
    <div className="rf-body rf-body--split" onKeyDown={onKey}>
      <LayerRail ws={ws} />
      <div className="rf-overview">
        <div className="rf-filterbar">
          <strong>{ws.layer}</strong><span className="rf-meta">{scoped.length} on {new Set(scoped.map(w => w.display)).size} displays</span>
          <div className="rf-chips" role="group" aria-label="Filter by kind">{KINDS.map(k => <button key={k} type="button" className="rf-btn rf-btn--chip" aria-pressed={kind === k} onClick={() => setKind(kind === k ? null : k)}>{k}</button>)}</div>
          <label className="rf-filter"><Search size={11} /><input id="rf-filter" placeholder="Filter windows" value={query} onChange={e => setQuery(e.target.value)} /><kbd>/</kbd></label>
        </div>
        <div className="rf-displays" ref={displaysRef}>
          {localDisplays.map(d => {
            const here = ws.wins.filter(w => w.display === d.id && w.desktop === ws.desktops[d.id]);
            const scopedHere = here.filter(w => inScope.has(w.id));
            return <section key={d.id} className="rf-display" style={{ flex: `0 0 ${displayWeight(d.w) * displayScale}px` }} data-focused={focused === d.id}>
              <div className="rf-display-head"><strong>{d.name}</strong><span>{d.size}</span>{d.virtual && <span>virtual</span>}<em>live · Desktop {ws.desktops[d.id]}</em></div>
              <div className="rf-map" style={{ aspectRatio: `${d.w} / ${d.h}` }} onClick={e => { if (e.target === e.currentTarget) { setFocused(d.id); ws.setSelection([]); } }}>
                {here.map(w => {
                  const on = inScope.has(w.id);
                  return <button key={w.id} type="button" className="rf-win" data-scope={on} data-selected={ws.selection.includes(w.id)} data-member={on && named(ws.layer) && w.layer === ws.layer} tabIndex={on ? 0 : -1}
                    style={{ left: `${w.frame[0] * 100}%`, top: `${w.frame[1] * 100}%`, width: `${w.frame[2] * 100}%`, height: `${w.frame[3] * 100}%` }}
                    onClick={e => on && pick(w, e.metaKey || e.ctrlKey)} onDoubleClick={() => on && notify(`Focus ${w.app} · ${w.title}. Illustrative.`)} aria-label={`${w.app} ${w.title}`}>
                    {on && <span>{kindIcon(w.kind, 9)}{w.app}<b>{w.title}</b></span>}
                  </button>;
                })}
                {scopedHere.length === 0 && <span className="rf-map-empty">Nothing in scope here</span>}
              </div>
              <div className="rf-desktops" role="group" aria-label={`${d.name} desktops`}>
                {Array.from({ length: d.desktops }, (_, i) => i + 1).map(n => <button key={n} type="button" aria-pressed={ws.desktops[d.id] === n} aria-label={`Desktop ${n}`}
                  onClick={() => { ws.setDesktops({ ...ws.desktops, [d.id]: n }); setFocused(d.id); }}>
                  <span style={{ aspectRatio: `${d.w} / ${d.h}` }}>{ws.wins.filter(w => w.display === d.id && w.desktop === n).map(w => <i key={w.id} data-scope={inScope.has(w.id)} style={{ left: `${w.frame[0] * 100}%`, top: `${w.frame[1] * 100}%`, width: `${w.frame[2] * 100}%`, height: `${w.frame[3] * 100}%` }} />)}</span>
                  <small>{n}</small>
                </button>)}
              </div>
            </section>;
          })}
        </div>
        <div className="rf-hint"><span>Click to select · ⌘-click to add · double-click to focus · <kbd>esc</kbd> clears</span><span className="rf-meta">{scoped.length} in scope · {canArrange} can arrange · {elsewhere} elsewhere</span></div>
        <div className="rf-panes">
          <section aria-label="Focused desktop">
            <h3>Desktop {ws.desktops[focused]} · {focusedInfo.name}</h3>
            <div className="rf-pane-scroll">
              {ws.wins.filter(w => w.display === focused && w.desktop === ws.desktops[focused]).map(w => <button key={w.id} type="button" className="rf-row" data-selected={ws.selection.includes(w.id)} disabled={!inScope.has(w.id)} onClick={e => pick(w, e.metaKey || e.ctrlKey)}>
                {kindIcon(w.kind)}<span className="rf-row-app">{w.app}</span><span className="rf-row-title" title={w.title}>{w.title}</span>{w.rule && <em className="rf-tag">rule</em>}
              </button>)}
              {ws.wins.filter(w => w.display === focused && w.desktop === ws.desktops[focused]).length === 0 && <span className="rf-empty">No windows on this desktop</span>}
            </div>
          </section>
          <section aria-label="Selection">
            <h3>Selection{selected.length > 0 && <span>{selected.length}</span>}</h3>
            {one ? <div className="rf-selection">
              <strong>{one.title}</strong>
              <span className="rf-meta">{one.app} · {one.layer ?? UNASSIGNED} · {localDisplays.find(d => d.id === one.display)!.name} · Desktop {one.desktop}</span>
              <div className="rf-btn-row">
                <button type="button" className="rf-btn" onClick={() => notify(`Focus ${one.title}. Illustrative.`)}>Focus</button>
                <span className="rf-menu-wrap"><button type="button" className="rf-btn" aria-expanded={moveOpen} onClick={() => setMoveOpen(!moveOpen)}>Move to Desktop<ChevronDown size={10} /></button>
                  {moveOpen && <span className="rf-menu" role="menu">{Array.from({ length: localDisplays.find(d => d.id === one.display)!.desktops }, (_, i) => i + 1).map(n => <button key={n} type="button" role="menuitem" disabled={n === one.desktop} onClick={() => { ws.setWins(ws.wins.map(w => w.id === one.id ? { ...w, desktop: n } : w)); setMoveOpen(false); }}>Desktop {n}</button>)}</span>}
                </span>
              </div>
            </div> : selected.length > 1 ? <div className="rf-selection"><strong>{selected.length} windows</strong><span className="rf-meta">{selected.map(w => w.app).join(" · ")}</span></div>
              : <span className="rf-empty">Select a window on a map</span>}
          </section>
          <section aria-label="Arrange selection">
            <h3>Arrange selection</h3>
            <div className="rf-btn-row">
              <button type="button" className="rf-btn" disabled={selected.length < 2} onClick={() => arrange("Tile")}>Tile<kbd>T</kbd></button>
              <button type="button" className="rf-btn" disabled={selected.length < 2} onClick={() => arrange("Distribute")}>Distribute<kbd>D</kbd></button>
            </div>
            <span className="rf-empty">{selected.length < 2 ? "Select two or more windows" : `${selected.length} windows ready`}</span>
          </section>
        </div>
      </div>
    </div>
    <StatusBar left={`0 sessions running · ${ws.wins.length} windows · ${localDisplays.length} displays`} />
  </>;
}

function LayersSurface({ ws, notify, onSurface }: { ws: WorkspaceState; notify: Notify; onSurface: (s: RefinedSurface) => void }) {
  const [mode, setMode] = useState<"Overview" | "Workspace">("Overview");
  const members = ws.wins.filter(w => inLayer(w, ws.layer));
  const ruleCount = members.filter(w => w.rule).length;
  const displaysUsed = new Set(members.map(w => w.display));
  const placed = members.filter(w => ws.desktops[w.display] === w.desktop);
  const subtitle = ws.layer === ALL ? `${members.length} open windows across all layers and ${UNASSIGNED}.` : ws.layer === UNASSIGNED ? `${members.length} windows without a layer.` : `${members.length} ${members.length === 1 ? "window" : "windows"} kept together in ${ws.layer}.`;
  const toggle = (id: number) => ws.setSelection(ws.selection.includes(id) ? ws.selection.filter(x => x !== id) : [id]);

  const table = <div className="rf-table rf-table--layers" role="table" aria-label={`${ws.layer} windows`} data-full={mode === "Workspace"}>
    <div className="rf-tr rf-th" role="row"><span role="columnheader">Window</span><span role="columnheader">App</span><span role="columnheader">Placed here on</span><span role="columnheader">Rule</span></div>
    {members.map(w => <div key={w.id} role="row" className="rf-tr" tabIndex={0} aria-selected={ws.selection.includes(w.id)} onKeyDown={e => activateRow(e, () => toggle(w.id))} data-selected={ws.selection.includes(w.id)} onClick={() => toggle(w.id)}>
      <span role="cell" className="rf-machine"><span className="rf-machine-icon">{kindIcon(w.kind, 12)}</span><strong title={w.title}>{w.title}</strong></span>
      <span role="cell">{w.app}</span>
      <span role="cell" className="rf-meta" title={`${localDisplays.find(d => d.id === w.display)!.name} · Desktop ${w.desktop}`}>{localDisplays.find(d => d.id === w.display)!.name} · Desktop {w.desktop}</span>
      <span role="cell" className="rf-meta">{w.rule ? `${w.layer} rule` : "—"}</span>
    </div>)}
    {members.length === 0 && <span className="rf-empty">No windows open in this layer</span>}
  </div>;

  return <>
    <Toolbar title="Layers">
      <div className="rf-segment" role="group" aria-label="Layers view">{(["Overview", "Workspace"] as const).map(m => <button key={m} type="button" aria-pressed={mode === m} onClick={() => setMode(m)}>{m}</button>)}</div>
      <button type="button" className="rf-btn" onClick={() => onSurface("Overview")}>Exit Layers</button>
      <SearchButton notify={notify} />
    </Toolbar>
    <div className="rf-body rf-body--split">
      <LayerRail ws={ws} />
      <div className="rf-layers">
        <div className="rf-layers-col">
          <span className="rf-caption">{ws.layer}</span>
          <h3 className="rf-layers-title">{ws.layer}</h3>
          <p className="rf-layers-sub">{subtitle}</p>
          <span className="rf-layers-state" data-live={members.length > 0}><i className="rf-dot" />{members.length > 0 ? "Windows open" : "No windows open"} · {members.length} windows{ws.layer !== UNASSIGNED && <> · {ruleCount} {ruleCount === 1 ? "rule" : "rules"}</>} · {displaysUsed.size} {displaysUsed.size === 1 ? "display" : "displays"}</span>
          {mode === "Overview" && <>
            <div className="rf-well">
              {localDisplays.map(d => {
                const here = placed.filter(w => w.display === d.id);
                return <figure key={d.id} style={{ flexGrow: displayWeight(d.w) }}>
                  <div className="rf-map rf-map--layer" data-holds={here.length > 0 && ws.layer !== UNASSIGNED} style={{ aspectRatio: `${d.w} / ${d.h}` }}>
                    {here.map(w => <button key={w.id} type="button" className="rf-win" data-scope="true" data-member={ws.layer !== UNASSIGNED ? "true" : "false"} data-selected={ws.selection.includes(w.id)} aria-label={`${w.app} ${w.title}`}
                      style={{ left: `${w.frame[0] * 100}%`, top: `${w.frame[1] * 100}%`, width: `${w.frame[2] * 100}%`, height: `${w.frame[3] * 100}%` }} onClick={() => toggle(w.id)} />)}
                  </div>
                  <figcaption>{d.name}{d.main ? " · main" : ""}</figcaption>
                </figure>;
              })}
            </div>
            <span className="rf-footnote">Displays to scale · {localDisplays.length} displays · {members.length - placed.length} without live positions</span>
          </>}
          {table}
          <div className="rf-chat">
            <div className="rf-chat-head"><span className="rf-caption">Chat about these windows</span><button type="button" className="rf-link" onClick={() => setMode("Workspace")}>Open workspace<ChevronRight size={10} /></button></div>
            <div className="rf-chat-row">
              <span className="rf-scope-chip">{ws.layer} · {members.length} windows</span>
              <input aria-label="Ask about this layer" placeholder="Ask about this layer…" />
              <button type="button" className="rf-icon-btn" disabled aria-label="Send"><ArrowUp size={12} /></button>
            </div>
            <span className="rf-footnote">Answers arrive in a later version</span>
          </div>
        </div>
      </div>
    </div>
    <StatusBar left={`0 sessions running · ${ws.wins.length} windows · ${localDisplays.length} displays`} />
  </>;
}

// MARK: Root

export interface RefinedProps {
  surface: RefinedSurface;
  onSurface: (s: RefinedSurface) => void;
  offline: boolean;
  unknownInput: boolean;
  contentCheck: boolean;
}

export function RefinedApp({ surface, onSurface, offline, unknownInput, contentCheck }: RefinedProps) {
  const [layer, setLayer] = useState(ALL);
  const [wins, setWins] = useState(localWindows);
  const [desktops, setDesktops] = useState<Record<LocalDisplay, number>>({ u32: 1, dell: 1, agent: 1 });
  const [selection, setSelection] = useState<number[]>([1]);
  const [notice, setNotice] = useState("");
  const ws = useMemo<WorkspaceState>(() => ({ layer, setLayer, wins, setWins, desktops, setDesktops, selection, setSelection }), [layer, wins, desktops, selection]);
  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(""), 4200); return () => clearTimeout(t); }, [notice]);

  return <section className="rf-app" aria-label={`Refined Lattices · ${surface}`}>
    <Sidebar surface={surface} onSurface={onSurface} />
    <div className="rf-panel">
      {surface === "Machines" ? <Machines offline={offline} unknownInput={unknownInput} contentCheck={contentCheck} notify={setNotice} onSurface={onSurface} />
        : surface === "Overview" ? <Overview ws={ws} notify={setNotice} />
          : <LayersSurface ws={ws} notify={setNotice} onSurface={onSurface} />}
      {notice && <div className="rf-notice" role="status"><span>{notice}</span><button type="button" className="rf-icon-btn" aria-label="Dismiss" onClick={() => setNotice("")}><X size={11} /></button></div>}
    </div>
  </section>;
}
