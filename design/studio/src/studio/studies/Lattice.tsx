"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { ArrowDownLeft, ArrowUpRight, Check, ChevronDown, ChevronRight, Circle, Columns2, Computer, Eye, Grid2X2, Home, Laptop, Layers, Maximize2, Minus, Monitor, MousePointer2, Plus, Search, Server, Terminal, X } from "lucide-react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { DesktopPreview } from "./lattice/Preview";
import { PlanStudy } from "./lattice/Plan";
import { RefinedApp } from "./lattice/Refined";
import type { RefinedSurface } from "./lattice/refined-model";
import { hosts, treatments, windows, type Display, type Host, type HostID, type Surface, type Treatment } from "./lattice/model";
import "./lattice/lattice.css";

const deviceIcon = (host: Host) => host.id === "air" ? <Laptop /> : host.platform === "Linux" ? <Server /> : <Computer />;

function DisplayTile({ display, host, selected, offline, treatment, onSelect, onView }: { display: Display; host: Host; selected: boolean; offline: boolean; treatment: Treatment; onSelect: () => void; onView: () => void }) {
  return <div className={`lt-display${host.id === "air" ? " lt-display--laptop" : ""}`} style={{ "--display-ratio": display.ratio } as CSSProperties}>
    <button type="button" className="lt-monitor" data-selected={selected} onClick={onSelect} onDoubleClick={onView} aria-label={`Select ${display.name} on ${host.name}`} aria-pressed={selected}>
      <div className="lt-monitor-screen"><DesktopPreview scene={display.scene} wireframe={treatment === "instrument"} />
        {offline && <span className="lt-offline-cover"><Monitor /><strong>Preview unavailable</strong><span>Last connected a moment ago</span></span>}
      </div>
      <span className="lt-monitor-chin"><i /></span>
      {selected && <span className="lt-display-selected"><Check size={9} /></span>}
    </button>
    <span className="lt-monitor-stand" />
    <div className="lt-display-caption"><strong>{display.name}</strong><span>{display.resolution}</span><small className="lt-display-input">{display.id === "mini-side" ? <><i className="lt-input-dot lt-input-dot--active" />Desk: This Mac · HDMI 1</> : display.input ?? "Built-in"}</small></div>
  </div>;
}

function CodexLattice({ treatment }: { treatment: Treatment }) {
  const [surface, setSurface] = useState<Surface>("Machines");
  const [canvas, setCanvas] = useState<"Hosts" | "Desk">("Hosts");
  const [selected, setSelected] = useState<HostID>("arts-mini");
  const [selectedDisplay, setSelectedDisplay] = useState("mini-main");
  const [offline, setOffline] = useState(false);
  const [query, setQuery] = useState("");
  const [zoom, setZoom] = useState(100);
  const [viewMenu, setViewMenu] = useState(false);
  const [preview, setPreview] = useState<{ title: string; scene: Display["scene"] } | null>(null);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const previewTrigger = useRef<HTMLElement | null>(null);
  const [layer, setLayer] = useState("All windows");
  const [selectedWindow, setSelectedWindow] = useState<number | null>(1);
  const [desktops, setDesktops] = useState<Record<string, number>>({ "DELL S3422DWG": 1, U32J59x: 1 });
  const [notice, setNotice] = useState("");
  const current = treatments.find(t => t.id === treatment)!;
  const host = hosts.find(h => h.id === selected)!;
  const hostOffline = offline && selected === "arts-mini";
  const selectHost = (h: Host, display = h.displays[0].id) => { setSelected(h.id); setSelectedDisplay(display); setViewMenu(false); setNotice(""); };
  const showPreview = (name: string, scene: Display["scene"] = host.displays.find(d => d.id === selectedDisplay)?.scene ?? "code") => { previewTrigger.current = document.activeElement as HTMLElement; setPreview({ title: name, scene }); setViewMenu(false); };
  const closePreview = () => { dialogRef.current?.close(); setPreview(null); previewTrigger.current?.focus(); };
  useEffect(() => { if (preview && !dialogRef.current?.open) dialogRef.current?.showModal(); }, [preview]);
  const selectedPhysicalName = hosts.flatMap(h => h.displays).find(d => d.id === selectedDisplay)?.name;
  const selectPhysicalHost = (h: Host, name: string) => selectHost(h, h.displays.find(d => d.name === name)?.id ?? h.displays[0].id);
  const filteredHosts = hosts.filter(h => `${h.name} ${h.platform} ${h.model}`.toLowerCase().includes(query.toLowerCase()));
  const filteredWindows = windows.filter(w => (layer === "All windows" || w.layer === layer) && `${w.app} ${w.title}`.toLowerCase().includes(query.toLowerCase()));
  const changeSurface = (next: Surface) => { setSurface(next); setQuery(""); setViewMenu(false); setNotice(""); };

  return <>
    <section className="lt-app" data-treatment={treatment} aria-label={`${current.name} interactive Lattices prototype`}>
      <aside className="lt-sidebar"><div className="lt-traffic" aria-hidden="true"><i /><i /><i /></div><div className="lt-brand"><span className="lt-mark">{Array.from({ length: 9 }, (_, i) => <i key={i} />)}</span><strong>Lattices</strong></div><span className="lt-nav-label">Workspace</span><div className="lt-inactive-nav"><Home />Home</div>{(["Overview", "Layers", "Machines"] as Surface[]).map(name => <button key={name} type="button" onClick={() => changeSurface(name)} aria-current={surface === name ? "page" : undefined}>{name === "Machines" ? <Computer /> : name === "Layers" ? <Layers /> : <Columns2 />}{name}</button>)}<div className="lt-sidebar-bottom"><span className="lt-status-dot" />This Mac<span>Connected</span></div></aside>
      <div className="lt-app-content">
        <header className="lt-app-toolbar"><div><h2>{surface}</h2><span>{surface === "Machines" ? "Your connected workspace" : surface === "Overview" ? "A place for every window" : "Work, kept together"}</span></div><label className="lt-search"><Search /><input aria-label={surface === "Machines" ? "Filter machines" : "Filter windows"} placeholder={surface === "Machines" ? "Find a machine…" : "Find a window…"} value={query} onChange={e => setQuery(e.target.value)} /></label></header>
        {surface === "Machines" ? <>
          <div className="lt-canvas-heading"><div><span className="lt-status-dot" /><strong>{canvas === "Hosts" ? "Connected computers" : "Your physical desk"}</strong><span>{canvas === "Hosts" ? `This Mac + 3 hosts · ${offline ? "2 reachable" : "3 reachable"}` : "Each monitor, once · input ownership below"}</span></div><div className="lt-segment" role="group" aria-label="Canvas organization">{(["Desk", "Hosts"] as const).map(mode => <button key={mode} type="button" aria-pressed={canvas === mode} onClick={() => { setCanvas(mode); setZoom(100); }}>{mode}</button>)}</div></div>
          <div className={`lt-canvas lt-canvas--${canvas.toLowerCase()}`}>
            <div className="lt-canvas-local"><button type="button" aria-pressed={selected === "local"} onClick={() => selectHost(hosts[0])}><Computer size={13} /><strong>This Mac</strong><span>Local · 2 displays</span>{selected === "local" && <Check size={12} />}</button><span>{canvas === "Hosts" ? "Remote hosts" : "Physical monitors and their connected inputs"}</span></div><div className="lt-canvas-objects" style={{ zoom: zoom / 100 }}>
              {canvas === "Hosts" ? hosts.filter(h => h.id !== "local").map((h, idx) => <section className={`lt-host-group lt-host-group--${h.id}`} data-selected={selected === h.id} data-offline={offline && h.id === "arts-mini"} key={h.id}>
                <button type="button" className="lt-host-heading" onClick={() => selectHost(h)} aria-pressed={selected === h.id}><span className="lt-device-icon">{deviceIcon(h)}</span><span><strong>{h.name}</strong><small>{h.model}</small></span><span className="lt-host-availability"><i className="lt-status-dot" data-offline={offline && h.id === "arts-mini"} />{offline && h.id === "arts-mini" ? "Offline" : "Reachable"}</span>{treatment === "instrument" && <span className="lt-host-index">H{idx + 1}</span>}</button>
                <div className="lt-host-displays">{h.displays.map(d => <DisplayTile key={d.id} display={d} host={h} selected={selectedDisplay === d.id} offline={offline && h.id === "arts-mini"} treatment={treatment} onSelect={() => selectHost(h, d.id)} onView={() => !(offline && h.id === "arts-mini") && showPreview(`${h.name} · ${d.name}`)} />)}</div>
                <div className="lt-host-foot"><span><Monitor size={12} />{h.displays.length} {h.displays.length === 1 ? "display" : "displays"}</span><span>{h.id === "archie" ? <><span className="lt-input-tick" />HDMI 2 · on desk</> : "Nearby · macOS"}</span></div>
              </section>) : <div className="lt-physical-desk">{[hosts[0].displays[1], hosts[0].displays[0], hosts[3].displays[0]].map((d, i) => <div className="lt-desk-display" key={d.id} style={{ flex: d.ratio }}><DisplayTile display={d} host={i === 2 ? hosts[3] : hosts[0]} selected={selectedPhysicalName === d.name} offline={offline && i === 2} treatment={treatment} onSelect={() => selectHost(i === 2 ? hosts[3] : hosts[0], d.id)} onView={() => !(offline && i === 2) && showPreview(d.name, d.scene)} /><div className="lt-inputs"><span>Inputs</span>{(i === 2 ? [hosts[3]] : i === 0 ? [hosts[0], hosts[3]] : [hosts[0], hosts[2]]).map((h, hi) => <button type="button" key={h.id} aria-pressed={selected === h.id} onClick={() => { selectPhysicalHost(h, d.name); setNotice(`${h.name} selected. Input switching is illustrative in this study.`); }}><i className={`lt-input-dot${hi === 0 ? " lt-input-dot--active" : ""}`} />{h.name}<small>{hi === 0 ? "Showing" : "Connected"}</small></button>)}</div></div>)}</div>}
            </div>
            <footer className="lt-canvas-footer"><span><MousePointer2 size={11} />Select a host or display to inspect it below</span><div><button type="button" aria-label="Zoom out" disabled={zoom <= 75} onClick={() => setZoom(v => Math.max(75, v - 25))}><Minus /></button><button type="button" aria-label="Reset canvas zoom" onClick={() => setZoom(100)}>{zoom}%</button><button type="button" aria-label="Zoom in" disabled={zoom >= 150} onClick={() => setZoom(v => Math.min(150, v + 25))}><Plus /></button></div></footer>
          </div>
          <div className="lt-machines-detail"><section className="lt-inventory" aria-label="Machine inventory"><div className="lt-section-heading"><h3>Machines <span>{filteredHosts.length}</span></h3><span>Select to explore</span></div><div className="lt-table-scroll"><table><thead><tr><th>Machine</th><th>Connection</th><th>Displays</th><th><span className="lt-sr-only">Selection</span></th></tr></thead><tbody>{filteredHosts.map(h => <tr key={h.id} data-selected={selected === h.id}><td><button type="button" className="lt-machine-select" aria-pressed={selected === h.id} onClick={() => selectHost(h)}><span className="lt-row-device">{deviceIcon(h)}</span><span><strong>{h.name}{h.id === "local" && <em>Local</em>}</strong><small>{h.model} · {h.platform}</small></span></button></td><td><span className="lt-connection"><i className="lt-status-dot" data-offline={offline && h.id === "arts-mini"} />{h.id === "local" ? "This computer" : offline && h.id === "arts-mini" ? "Unavailable" : "Reachable"}</span></td><td><span className="lt-display-count"><span className="lt-display-miniatures" aria-hidden="true">{h.displays.map(d => <i key={d.id} data-selected={selectedDisplay === d.id} style={{ aspectRatio: d.ratio }} />)}</span><span>{h.displays.length}</span></span></td><td><button type="button" className="lt-row-inspect" aria-label={`Inspect ${h.name}`} onClick={() => selectHost(h)}>{selected === h.id ? <Check size={14} /> : <ChevronRight size={14} />}</button></td></tr>)}</tbody></table>{filteredHosts.length === 0 && <div className="lt-empty"><Search /><strong>No matching machines</strong><span>Try a host name or platform.</span><button type="button" onClick={() => setQuery("")}>Clear search</button></div>}</div></section>
          <section className="lt-inspector" aria-label="Selected machine"><div className="lt-inspector-title"><span className="lt-device-icon">{deviceIcon(host)}</span><div><h3>{host.name}<span>{hostOffline ? "Unavailable" : host.id === "local" ? "This computer" : "Selected host"}</span></h3><p>{hostOffline ? "Last-known displays are kept in place." : `${host.displays.length} ${host.displays.length === 1 ? "display" : "displays"} · ${host.platform} · ${host.connection}`}</p></div><div className="lt-inspector-actions">{host.id === "archie" && <button type="button" className="lt-secondary-button" onClick={() => setNotice("Visit would route keyboard and pointer to archie. This is a design preview.")}><MousePointer2 size={13} />Visit</button>}<div className="lt-view-wrap"><button type="button" className="lt-primary-button" disabled={host.id === "local"} aria-expanded={viewMenu} onClick={() => setViewMenu(v => !v)}><Eye size={14} />View<ChevronDown size={12} /></button>{viewMenu && <div className="lt-view-menu"><button type="button" disabled={hostOffline} onClick={() => showPreview(`${host.name} · Lattices viewer`)}>Lattices viewer<ArrowUpRight size={12} /></button><button type="button" onClick={() => { setViewMenu(false); setNotice("VNC in Screen Sharing would open here. This study does not connect to a machine."); }}>VNC in Screen Sharing…<ArrowUpRight size={12} /></button></div>}</div></div></div><div className="lt-inspector-detail"><Monitor size={14} /><span>{host.displays.map(d => d.name).join(" · ")}</span></div>{host.id !== "local" && <div className="lt-host-windows"><div className="lt-host-window-heading"><strong>Windows on {host.name}</strong><span>{hostOffline ? "Last-known windows" : "2 windows"}</span></div>{(host.id === "air" ? [{ app: "Safari", title: "Lattices · documentation", scene: "browser" as const }, { app: "Ghostty", title: "lattices · shell", scene: "terminal" as const }] : [{ app: "Ghostty", title: `${host.name}: fab · desk`, scene: "terminal" as const }, { app: "Code", title: "RemoteSession.swift", scene: "code" as const }]).map(w => <button type="button" key={w.title} disabled={hostOffline} onClick={() => showPreview(w.title, w.scene)}><span className={`lt-app-icon lt-app-icon--${w.scene === "terminal" ? "terminal" : "code"}`}>{w.app === "Ghostty" ? <Terminal size={15} /> : <Columns2 size={15} />}</span><span className="lt-host-window-label"><strong>{w.title}</strong><small>{w.app}</small></span><ArrowUpRight size={12} /></button>)}</div>}<div className="lt-inspector-build"><span className="lt-build">Lattices 0.15.1 <small>{host.build}</small></span>{host.id === "arts-mini" && <span className="lt-build-note">Different build</span>}</div></section></div>
        </> : <div className="lt-workspace"><aside className="lt-layer-list"><h3>Layers <span>2</span></h3>{["All windows", "Lattices", "fab"].map(l => <button type="button" key={l} aria-pressed={layer === l} onClick={() => setLayer(l)}>{l === "All windows" ? <Grid2X2 size={13} /> : <Circle size={9} />}<span>{l}</span><small>{l === "All windows" ? 4 : 2}</small></button>)}<div className="lt-layer-note"><Layers size={15} />A layer keeps related windows together.</div></aside><div className="lt-overview-main"><div className="lt-overview-heading"><div><h3>{layer}</h3><p>{filteredWindows.length} windows across {new Set(filteredWindows.map(w => w.display)).size} {new Set(filteredWindows.map(w => w.display)).size === 1 ? "display" : "displays"}</p></div><span className="lt-workspace-state"><i className="lt-status-dot" />{Object.values(desktops).every(n => n === 1) ? "Desktop 1" : "Per-display desktops"}</span></div><div className={`lt-overview-canvas ${surface === "Layers" ? "lt-overview-canvas--layers" : ""}`}>{hosts[0].displays.map((d, i) => <section key={d.id} className="lt-overview-display"><div className="lt-overview-display-name"><Monitor size={13} /><strong>{d.name}</strong><span>{d.resolution}</span></div><div className="lt-window-map" style={{ aspectRatio: d.ratio }}>{filteredWindows.filter(w => w.display === d.name && w.space === (desktops[d.name] ?? 1)).map(w => <button key={w.id} type="button" data-selected={selectedWindow === w.id} onClick={() => setSelectedWindow(w.id)} onDoubleClick={() => showPreview(w.title, w.kind === "terminal" ? "terminal" : w.kind === "browser" ? "browser" : "code")}><span>{w.kind === "terminal" ? <Terminal size={12} /> : w.kind === "code" ? <Columns2 size={12} /> : <Circle size={12} />}{w.app}</span><strong>{w.title}</strong><small>{w.layer}</small>{selectedWindow === w.id && <Check size={12} />}</button>)}{filteredWindows.filter(w => w.display === d.name && w.space === (desktops[d.name] ?? 1)).length === 0 && <span className="lt-map-empty">No windows on this desktop</span>}</div><div className="lt-space-strip">{Array.from({ length: i === 0 ? 5 : 3 }, (_, n) => <button type="button" key={n} aria-label={`${d.name} desktop ${n + 1}`} aria-pressed={(desktops[d.name] ?? 1) === n + 1} onClick={() => setDesktops(prev => ({ ...prev, [d.name]: n + 1 }))}><span>{windows.filter(w => w.display === d.name && w.space === n + 1 && (layer === "All windows" || w.layer === layer)).map(w => <i key={w.id} />)}</span><small>{n + 1}</small></button>)}</div></section>)}</div><section className="lt-window-inventory"><div className="lt-section-heading"><h3>Windows <span>{filteredWindows.length}</span></h3><span>Select on the map or in the list</span></div><div className="lt-table-scroll"><table><thead><tr><th>Window</th><th>Layer</th><th>Display / Desktop</th><th /></tr></thead><tbody>{filteredWindows.map(w => <tr key={w.id} data-selected={selectedWindow === w.id}><td><button type="button" className="lt-window-select" onClick={() => { setSelectedWindow(w.id); setDesktops(prev => ({ ...prev, [w.display]: w.space })); }}><span className={`lt-app-icon lt-app-icon--${w.kind}`}>{w.kind === "terminal" ? <Terminal size={15} /> : w.kind === "code" ? <Columns2 size={15} /> : <Circle size={15} />}</span><span><strong>{w.title}</strong><small>{w.app}</small></span></button></td><td>{w.layer}</td><td><span className="lt-list-display">{w.display}<small>Desktop {w.space}</small></span></td><td><button type="button" className="lt-row-inspect" onClick={() => showPreview(w.title, w.kind === "terminal" ? "terminal" : w.kind === "browser" ? "browser" : "code")} aria-label={`Preview ${w.title}`}><ArrowUpRight size={13} /></button></td></tr>)}</tbody></table>{filteredWindows.length === 0 && <div className="lt-empty"><Search /><strong>No matching windows</strong><button type="button" onClick={() => { setQuery(""); setLayer("All windows"); }}>Show all windows</button></div>}</div></section>{surface === "Layers" && <div className="lt-layer-summary"><Layers size={17} /><div><strong>{layer === "All windows" ? "Everything has a place." : `${layer}, in context.`}</strong><span>The same monitor and list language carries into Layers.</span></div><button type="button" onClick={() => changeSurface("Overview")}>Open workspace<ArrowUpRight size={13} /></button></div>}</div></div>}
        {notice && <div className="lt-notice" role="status"><span>{notice}</span><button type="button" aria-label="Dismiss notice" onClick={() => setNotice("")}><X size={13} /></button></div>}
        <footer className="lt-app-status"><span><span className="lt-status-dot" />{surface === "Machines" ? "4 computers · 6 display attachments" : "4 windows · 2 displays"}</span><span>Illustrative data · no live connection</span></footer>
      </div>
      {preview && <dialog ref={dialogRef} className="lt-preview-overlay" aria-label="Illustrative viewer" onCancel={e => { e.preventDefault(); closePreview(); }}><header><span><Eye size={15} />{preview.title}</span><button type="button" autoFocus onClick={closePreview} aria-label="Close illustrative viewer"><X size={18} /></button></header><DesktopPreview scene={preview.scene} /><footer>Viewer design preview · no connection to a real machine</footer></dialog>}
    </section>
    <footer className="lt-study-footer"><div><strong>{current.strength}</strong><p>{current.description}</p><span>{current.tradeoff}</span></div><label className="lt-scenario"><input type="checkbox" checked={offline} onChange={e => setOffline(e.target.checked)} /><span>Show arts-mini offline<small>Compare the unavailable state</small></span></label></footer>
  </>;
}

type Archived = "plan" | Treatment;
type Compare = "Refined" | "Current" | "Both";

const SURFACES: RefinedSurface[] = ["Overview", "Layers", "Machines"];

function CurrentShot({ surface }: { surface: RefinedSurface }) {
  return <figure className="rf-current">
    <img src={`/study-assets/lattice/current-${surface.toLowerCase()}.png`} alt={`Current native Lattices ${surface}, unchanged screenshot`} />
  </figure>;
}

/** Refined is the review candidate: the current native app, tightened. Earlier experiments are rejected history. */
export function LatticeStudy({ page, standalone = false }: { page?: LatticesPage; standalone?: boolean }) {
  const [compare, setCompare] = useState<Compare>("Refined");
  const [surface, setSurface] = useState<RefinedSurface>("Machines");
  const [offline, setOffline] = useState(false);
  const [unknownInput, setUnknownInput] = useState(false);
  const [contentCheck, setContentCheck] = useState(false);
  const [archived, setArchived] = useState<Archived | null>(null);
  const archiveRef = useRef<HTMLDetailsElement>(null);
  const openArchived = (a: Archived) => { setArchived(a); if (archiveRef.current) archiveRef.current.open = false; };
  const archivedName = archived === "plan" ? "Plan — Opus" : treatments.find(t => t.id === archived)?.name;
  const refined = <RefinedApp surface={surface} onSurface={setSurface} offline={offline} unknownInput={unknownInput} contentCheck={contentCheck} />;

  return <main className={`lt-study rf-study${standalone ? " lt-study--standalone" : ""}`}>
    <header className="rf-review">
      <h1>{page?.label ?? "Lattice"}</h1>
      {!archived && <>
        <div className="rf-review-seg" role="group" aria-label="Compare">{(["Refined", "Current", "Both"] as const).map(c => <button key={c} type="button" aria-pressed={compare === c} onClick={() => setCompare(c)}>{c}</button>)}</div>
        <div className="rf-review-seg" role="group" aria-label="Surface">{SURFACES.map(s => <button key={s} type="button" aria-pressed={surface === s} onClick={() => setSurface(s)}>{s}</button>)}</div>
        {surface === "Machines" && compare !== "Current" && <>
          <label className="rf-review-check"><input type="checkbox" checked={offline} onChange={e => setOffline(e.target.checked)} />archie offline</label>
          <label className="rf-review-check"><input type="checkbox" checked={unknownInput} onChange={e => setUnknownInput(e.target.checked)} />AW input unknown</label>
          <label className="rf-review-check" title="Long illustrative window titles and screen previews from the supplied October 24 capture"><input type="checkbox" checked={contentCheck} onChange={e => setContentCheck(e.target.checked)} />Captured previews + long titles</label>
        </>}
      </>}
      <details className="rf-archive" ref={archiveRef}>
        <summary>Archive</summary>
        <div className="rf-archive-list">
          <span>Rejected history</span>
          <button type="button" aria-pressed={archived === "plan"} onClick={() => openArchived("plan")}>Plan<small>Opus · rejected</small></button>
          {treatments.map(t => <button key={t.id} type="button" aria-pressed={archived === t.id} onClick={() => openArchived(t.id)}>{t.name}<small>Codex · rejected</small></button>)}
        </div>
      </details>
      {standalone ? <a href="/studio/studies/lattice"><ArrowDownLeft size={13} />Back to Studio</a> : <a href="/embed/lattice" target="_blank" rel="noreferrer"><Maximize2 size={13} />Open full size</a>}
    </header>
    {archived ? <>
      <div className="rf-banner"><strong>Rejected history</strong>{archivedName} · kept for reference, not a candidate<button type="button" onClick={() => setArchived(null)}>Back to Refined</button></div>
      {archived === "plan" ? <PlanStudy /> : <CodexLattice treatment={archived} />}
    </> : compare === "Refined" ? refined
      : compare === "Current" ? <><p className="rf-compare-label"><strong>Current</strong>Native screenshot · Oct 24 · unchanged</p><CurrentShot surface={surface} /></>
        : <div className="rf-compare">
          <div><p className="rf-compare-label"><strong>Current</strong>Native screenshot · Oct 24 · unchanged</p><CurrentShot surface={surface} /></div>
          <div><p className="rf-compare-label"><strong>Refined</strong>Interactive · illustrative data, no live connection</p>{refined}</div>
        </div>}
  </main>;
}
