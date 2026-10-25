"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { ArrowUpRight, ChevronDown, Code, Globe, Minus, Plus, Search, StickyNote, Terminal, X } from "lucide-react";
import { desktopCount, mmSize, monitors, planHosts, planLayers, planWindows, type Monitor, type MonitorID, type PlanHost, type PlanHostID, type PlanWindow } from "./plan-model";
import "./plan.css";

type Mode = "Hosts" | "Desk";
type Surface = "Overview" | "Layers" | "Machines";
type Sel = { kind: "host"; host: PlanHostID } | { kind: "monitor"; monitor: MonitorID; host: PlanHostID | null };

const monitorBy = (id: MonitorID) => monitors.find(m => m.id === id)!;
const hostBy = (id: PlanHostID) => planHosts.find(h => h.id === id)!;
const SCALES = [6, 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.75];
const PAD = 18, LABEL = 30, CAPTION = 30;

function layoutHosts(scale: number, singleRow: boolean) {
  const cell = 100 / scale;
  const snap = (v: number) => Math.ceil(v / cell) * cell;
  const rows: PlanHostID[][] = singleRow
    ? [["local", "arts-mini", "archie", "air"]]
    : [["local", "arts-mini"], ["archie", "air"]];
  const boxes: { host: PlanHost; x: number; y: number; w: number; h: number; ox: number; oy: number; arrH: number }[] = [];
  let y = cell * 0.6;
  for (const row of rows) {
    let x = cell * 0.6, bottom = 0;
    for (const id of row) {
      const host = hostBy(id);
      const ext = host.arrangement.reduce((a, d) => { const s = mmSize(monitorBy(d.monitor)); return { w: Math.max(a.w, d.x + s.w), h: Math.max(a.h, d.y + s.h) }; }, { w: 0, h: 0 });
      const arrW = ext.w / scale, arrH = ext.h / scale;
      const ox = snap(x + PAD), oy = snap(y + LABEL + PAD);
      const bodyH = host.body ? host.body.h / scale + 10 : host.id === "air" ? 6 : 0;
      const box = { host, ox, oy, arrH, x: ox - PAD, y: oy - PAD, w: arrW + PAD * 2, h: arrH + CAPTION + bodyH + PAD * 2 };
      boxes.push(box);
      x = box.x + box.w + 52; bottom = Math.max(bottom, box.y + box.h);
    }
    y = bottom + 24;
  }
  const width = Math.max(...boxes.map(b => b.x + b.w)) + cell * 0.6;
  return { boxes, width, height: y + cell * 0.4 };
}

function layoutDesk(scale: number) {
  const cell = 100 / scale;
  const snap = (v: number) => Math.ceil(v / cell) * cell;
  const left = snap(cell * 0.8);
  const top = cell * 0.6;
  const stack = Math.max(...monitors.map(m => m.desk.lift + mmSize(m).h));
  const deskY = snap(top + stack / scale);
  const right = Math.max(...monitors.map(m => m.desk.x + mmSize(m).w)) / scale + left;
  return { left, deskY, width: right + Math.max(cell * 1.2, 150), height: deskY + 86 };
}

const WindowIcon = ({ kind, size = 12 }: { kind: PlanWindow["kind"]; size?: number }) =>
  kind === "terminal" ? <Terminal size={size} /> : kind === "code" ? <Code size={size} /> : kind === "browser" ? <Globe size={size} /> : <StickyNote size={size} />;

function inputState(m: Monitor, host: PlanHostID, unknown: boolean) {
  if (m.inputs.length < 2) return null;
  if (unknown || m.owner === null) return "input unknown";
  return m.owner === host ? "on screen" : "elsewhere";
}

/** A display drawn at physical size, holding flat window geometry from the fixtures. */
function Screen({ m, host, scale, desktop, mark, dim, hatch, empty, onSelect, onOpen, label }: {
  m: Monitor; host: PlanHostID | null; scale: number; desktop: number; mark?: "selected" | "twin"; dim?: boolean; hatch?: string; empty?: string;
  onSelect: () => void; onOpen?: () => void; label: string;
}) {
  const { w, h } = mmSize(m);
  const pw = w / scale, ph = h / scale;
  const wins = host && !hatch && !empty ? planWindows.filter(x => x.host === host && x.monitor === m.id && x.desktop === desktop) : [];
  return <button type="button" className="pl-screen" data-mark={mark} data-dim={dim || undefined} data-hatch={hatch ? true : undefined}
    style={{ width: pw, height: ph }} onClick={onSelect} onDoubleClick={onOpen} aria-label={label} aria-pressed={mark === "selected"}>
    {wins.map(x => {
      const ww = x.frame[2] * pw;
      return <span key={x.id} className="pl-win" style={{ left: `${x.frame[0] * 100}%`, top: `${x.frame[1] * 100}%`, width: `${x.frame[2] * 100}%`, height: `${x.frame[3] * 100}%` }}>
        <WindowIcon kind={x.kind} size={ww > 40 ? 11 : 9} />{ww > 96 && <em>{x.title}</em>}
      </span>;
    })}
    {(hatch || empty) && <span className="pl-screen-note">{hatch ?? empty}</span>}
  </button>;
}

function Silhouette({ m, scale = 14 }: { m: Monitor; scale?: number }) {
  const { w, h } = mmSize(m);
  return <i className="pl-sil" style={{ width: Math.round(w / scale), height: Math.round(h / scale) }} />;
}

export function PlanStudy() {
  const [surface, setSurface] = useState<Surface>("Machines");
  const [mode, setMode] = useState<Mode>("Hosts");
  const [sel, setSel] = useState<Sel>({ kind: "monitor", monitor: "u32", host: "arts-mini" });
  const [offline, setOffline] = useState(false);
  const [unknown, setUnknown] = useState(false);
  const [query, setQuery] = useState("");
  const [scale, setScale] = useState(2.5);
  const [autoScale, setAutoScale] = useState(true);
  const [singleHostRow, setSingleHostRow] = useState(false);
  const [viewMenu, setViewMenu] = useState(false);
  const [visiting, setVisiting] = useState<PlanHostID | null>(null);
  const [notice, setNotice] = useState("");
  const [viewer, setViewer] = useState<{ host: PlanHostID; monitor: MonitorID } | null>(null);
  const [desktops, setDesktops] = useState<Partial<Record<MonitorID, number>>>({ u32: 1, dell: 1 });
  const [layer, setLayer] = useState("All windows");
  const [win, setWin] = useState<number | null>(3);
  const canvasRef = useRef<HTMLDivElement>(null);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const viewerTrigger = useRef<HTMLElement | null>(null);

  const isOff = (h: PlanHostID) => offline && h === "arts-mini";
  // Unknown input applies to the DELL in the second scenario; elsewhere the fixture's owner stands.
  const ownerOf = (m: Monitor) => unknown && m.id === "dell" ? null : m.owner;
  const stateOf = (m: Monitor, h: PlanHostID) => inputState({ ...m, owner: ownerOf(m) }, h, false);

  // Fit both axes, reserving room for the outline. Reflow host groups without
  // changing the geometry inside them; one grid square is always 100 mm.
  useLayoutEffect(() => {
    if (!autoScale || surface !== "Machines") return;
    const el = canvasRef.current; if (!el) return;
    const fit = () => {
      const width = el.clientWidth;
      const top = el.getBoundingClientRect().top + window.scrollY;
      const height = Math.max(280, window.innerHeight - top - 280);
      for (const candidate of SCALES.slice().reverse()) {
        for (const row of mode === "Hosts" ? [false, true] : [false]) {
          const layout = mode === "Hosts" ? layoutHosts(candidate, row) : layoutDesk(candidate);
          if (layout.width <= width && layout.height <= height) {
            setScale(candidate); setSingleHostRow(row); return;
          }
        }
      }
      setScale(SCALES[0]); setSingleHostRow(false);
    };
    fit();
    const ro = new ResizeObserver(fit); ro.observe(el);
    window.addEventListener("resize", fit);
    return () => { ro.disconnect(); window.removeEventListener("resize", fit); };
  }, [autoScale, mode, surface]);

  const zoom = (dir: 1 | -1) => {
    const i = SCALES.indexOf(scale);
    const next = SCALES[Math.min(SCALES.length - 1, Math.max(0, i + dir))];
    setAutoScale(false); setScale(next);
  };

  const q = query.trim().toLowerCase();
  const hostMatches = (h: PlanHost) => !q || `${h.name} ${h.model} ${h.platform}`.toLowerCase().includes(q);
  const monitorMatches = (m: Monitor) => !q || m.name.toLowerCase().includes(q);
  const hostVisible = (h: PlanHost) => hostMatches(h) || h.arrangement.some(a => monitorMatches(monitorBy(a.monitor)));

  const select = (next: Sel) => { setSel(next); setViewMenu(false); setNotice(""); };
  const openViewer = (host: PlanHostID, monitor: MonitorID) => {
    if (host === "local" || isOff(host)) return;
    viewerTrigger.current = document.activeElement as HTMLElement; setViewMenu(false); setViewer({ host, monitor });
  };
  const closeViewer = () => { dialogRef.current?.close(); setViewer(null); viewerTrigger.current?.focus(); };
  useEffect(() => { if (viewer && !dialogRef.current?.open) dialogRef.current?.showModal(); }, [viewer]);
  const changeSurface = (s: Surface) => { setSurface(s); setQuery(""); setNotice(""); setViewMenu(false); };

  const cell = 100 / scale;

  // ---- Hosts plan: each machine keeps its own arrangement inside a hull ----
  const hostsLayout = useMemo(() => layoutHosts(scale, singleHostRow), [scale, singleHostRow]);

  // ---- Desk elevation: every physical monitor once, on one desk line ----
  const deskLayout = useMemo(() => layoutDesk(scale), [scale]);

  const selectedHost = sel.kind === "host" ? hostBy(sel.host) : null;
  const selectedMonitor = sel.kind === "monitor" ? monitorBy(sel.monitor) : null;

  const markFor = (monitor: MonitorID, host: PlanHostID | null): "selected" | "twin" | undefined => {
    if (sel.kind !== "monitor" || sel.monitor !== monitor) return undefined;
    if (mode === "Desk" || sel.host === null || sel.host === host) return "selected";
    return "twin";
  };

  const hostsCanvas = <div className="pl-plane" style={{ width: hostsLayout.width, height: hostsLayout.height, "--cell": `${cell}px` } as CSSProperties}>
    {hostsLayout.boxes.map(({ host, x, y, w, h, ox, oy, arrH }) => {
      const off = isOff(host.id);
      const dim = !hostVisible(host);
      return <section key={host.id} className="pl-hull" data-local={host.id === "local" || undefined} data-selected={sel.kind === "host" && sel.host === host.id || undefined}
        data-off={off || undefined} data-dim={dim || undefined} style={{ left: x, top: y, width: w, height: h }} aria-label={host.name}>
        <button type="button" className="pl-hull-label" onClick={() => select({ kind: "host", host: host.id })} aria-pressed={sel.kind === "host" && sel.host === host.id}>
          <strong>{host.name}</strong><span>{host.model}</span>{off && <em>offline</em>}{visiting === host.id && <em className="pl-visiting">visiting</em>}
        </button>
        {host.arrangement.map(a => {
          const m = monitorBy(a.monitor);
          const { w: mw, h: mh } = mmSize(m);
          const st = stateOf(m, host.id);
          return <div key={a.monitor} className="pl-placed" style={{ left: ox - x + a.x / scale, top: oy - y + a.y / scale }}>
            <Screen m={m} host={host.id} scale={scale} desktop={host.id === "local" ? desktops[m.id] ?? 1 : 1} mark={markFor(m.id, host.id)} dim={dim}
              hatch={off ? "last-known arrangement" : undefined} label={`${m.name} on ${host.name}`}
              onSelect={() => select({ kind: "monitor", monitor: m.id, host: host.id })} onOpen={() => openViewer(host.id, m.id)} />
            <div className="pl-caption" style={{ width: mw / scale }}>
              <span title={m.name}>{m.name}</span>{st && <b data-state={st}>{st}</b>}
            </div>
            {m.builtin && <i className="pl-deck" style={{ width: 304 / scale, marginLeft: -(304 - mw) / 2 / scale, top: mh / scale }} />}
          </div>;
        })}
        {host.body && <button type="button" className="pl-body" title={`${host.model} · ${host.body.w} × ${host.body.h} mm`} aria-label={`${host.name}, ${host.model}`}
          onClick={() => select({ kind: "host", host: host.id })}
          style={{ left: PAD, top: oy - y + arrH + CAPTION, width: host.body.w / scale, height: host.body.h / scale }} />}
      </section>;
    })}
  </div>;

  const deskCanvas = <div className="pl-plane" style={{ width: deskLayout.width, height: deskLayout.height, "--cell": `${cell}px` } as CSSProperties}>
    <i className="pl-desk-line" style={{ top: deskLayout.deskY, left: deskLayout.left - cell * 0.4, width: deskLayout.width - deskLayout.left }} />
    {monitors.map(m => {
      const { w, h } = mmSize(m);
      const owner = ownerOf(m);
      const x = deskLayout.left + m.desk.x / scale;
      const top = deskLayout.deskY - (m.desk.lift + h) / scale;
      const ownerOff = owner ? isOff(owner) : false;
      const dim = !(monitorMatches(m) || m.inputs.some(i => hostMatches(hostBy(i.host))));
      return <div key={m.id}>
        <div className="pl-placed" style={{ left: x, top }}>
          <Screen m={m} host={owner} scale={scale} desktop={owner === "local" ? desktops[m.id] ?? 1 : 1} mark={markFor(m.id, null)} dim={dim}
            hatch={ownerOff ? "arts-mini offline" : undefined} empty={owner === null ? "input unknown" : undefined} label={`${m.name}, physical monitor`}
            onSelect={() => select({ kind: "monitor", monitor: m.id, host: null })} onOpen={() => owner && openViewer(owner, m.id)} />
          {m.builtin && <i className="pl-deck" style={{ width: 304 / scale, marginLeft: -(304 - w) / 2 / scale, top: h / scale }} />}
        </div>
        <div className="pl-rail" style={{ left: x, top: deskLayout.deskY + 10, width: Math.max(w / scale, 120) }} data-dim={dim || undefined}>
          <span className="pl-rail-name">{m.name}<small>{m.diagonalIn}″</small></span>
          <div>{m.inputs.map(i => <button type="button" key={i.host} className="pl-tab" data-owner={m.inputs.length > 1 && owner === i.host || undefined}
            data-selected={sel.kind === "host" && sel.host === i.host || undefined} data-off={isOff(i.host) || undefined}
            onClick={() => select({ kind: "host", host: i.host })} aria-label={`${hostBy(i.host).name} on ${i.port}${owner === i.host ? ", on screen" : ""}`}>
            {hostBy(i.host).name}</button>)}
            {m.inputs.length > 1 && owner === null && <span className="pl-unknown">input unknown</span>}</div>
        </div>
      </div>;
    })}
  </div>;

  // ---- Outline ----
  const hostsOutline = planHosts.filter(hostVisible).map(h => {
    const off = isOff(h.id);
    return <div key={h.id} className="pl-group" data-off={off || undefined}>
      <button type="button" className="pl-row pl-row--host" aria-pressed={sel.kind === "host" && sel.host === h.id} onClick={() => select({ kind: "host", host: h.id })}>
        <strong>{h.name}</strong>{off ? <em>offline</em> : visiting === h.id ? <em>visiting</em> : null}
      </button>
      {h.arrangement.filter(a => hostMatches(h) || monitorMatches(monitorBy(a.monitor))).map(a => {
        const m = monitorBy(a.monitor); const st = stateOf(m, h.id);
        return <button type="button" key={a.monitor} className="pl-row pl-row--display" aria-pressed={sel.kind === "monitor" && sel.monitor === m.id && sel.host === h.id}
          data-twin={sel.kind === "monitor" && sel.monitor === m.id && sel.host !== h.id || undefined} onClick={() => select({ kind: "monitor", monitor: m.id, host: h.id })}>
          <span className="pl-sil-cell"><Silhouette m={m} /></span><span>{m.name}</span><small>{m.diagonalIn}″</small>{st && <b data-state={st}>{st}</b>}
        </button>;
      })}
    </div>;
  });

  const deskOutline = monitors.filter(m => monitorMatches(m) || m.inputs.some(i => hostMatches(hostBy(i.host)))).map(m => {
    const owner = ownerOf(m);
    return <button type="button" key={m.id} className="pl-row pl-row--monitor" aria-pressed={sel.kind === "monitor" && sel.monitor === m.id} onClick={() => select({ kind: "monitor", monitor: m.id, host: null })}>
      <span className="pl-sil-cell"><Silhouette m={m} /></span><strong>{m.name}</strong><small>{m.diagonalIn}″</small>
      <span className="pl-attached">{m.inputs.map(i => <span key={i.host} data-owner={m.inputs.length > 1 && owner === i.host || undefined}>{hostBy(i.host).name}</span>)}{m.inputs.length > 1 && owner === null && <span className="pl-unknown">unknown</span>}</span>
    </button>;
  });

  const outlineEmpty = mode === "Hosts" ? hostsOutline.length === 0 : deskOutline.length === 0;

  // ---- Inspector ----
  const fact = (k: string, v: ReactNode) => <><dt>{k}</dt><dd>{v}</dd></>;
  let inspector: ReactNode;
  if (selectedHost) {
    const h = selectedHost; const off = isOff(h.id); const local = h.id === "local";
    const wins = planWindows.filter(w => w.host === h.id && (local ? w.desktop === (desktops[w.monitor] ?? 1) : w.desktop === 1));
    inspector = <>
      <header className="pl-ins-head"><div><h3>{h.name}</h3><p>{h.model} · {h.platform}</p></div>
        {!local && <div className="pl-actions">
          <div className="pl-menu-wrap"><button type="button" className="pl-btn" aria-expanded={viewMenu} aria-haspopup="menu" onClick={() => setViewMenu(v => !v)}>View<ChevronDown size={12} /></button>
            {viewMenu && <div className="pl-menu" role="menu">
              <button type="button" role="menuitem" disabled={off} onClick={() => openViewer(h.id, h.arrangement[0].monitor)}>Lattices viewer{off && <small>capture unavailable</small>}</button>
              {h.vnc && <button type="button" role="menuitem" onClick={() => { setViewMenu(false); setNotice(`Screen Sharing (VNC) would open ${h.name}. Illustrative; nothing connects.`); }}>Screen Sharing (VNC)…<ArrowUpRight size={12} /></button>}
            </div>}</div>
          {h.visit && <button type="button" className="pl-btn" onClick={() => { const v = visiting === h.id ? null : h.id; setVisiting(v); setNotice(v ? `Visiting ${h.name} would route this keyboard and pointer there. Illustrative; no input moves.` : ""); }}>{visiting === h.id ? "End visit" : "Visit"}</button>}
        </div>}
      </header>
      <dl className="pl-facts">
        {fact("Connection", local ? "This computer" : off ? "Offline · last seen 13:04" : "Reachable")}
        {!local && fact("Capture", off ? "Unavailable while offline" : "Available")}
        {!local && fact("Screen Sharing", h.vnc ? "VNC route set up" : "Not set up")}
        {!local && fact("Visit", !h.visit ? "Not available" : visiting === h.id ? "Visiting" : "Ready")}
        {fact("Lattices", <><code>0.15.1 · {h.build}</code>{h.build !== hostBy("local").build && <span className="pl-note"> differs from This Mac</span>}</>)}
      </dl>
      <h4>Displays</h4>
      <div className="pl-ins-list">{h.arrangement.map(a => { const m = monitorBy(a.monitor); const st = stateOf(m, h.id); return <button type="button" key={m.id} onClick={() => select({ kind: "monitor", monitor: m.id, host: h.id })}><span className="pl-sil-cell"><Silhouette m={m} /></span><span>{m.name}</span>{st && <b data-state={st}>{st}</b>}</button>; })}</div>
      <h4>{off ? "Last-known windows" : "Windows"}</h4>
      <div className="pl-ins-list">{wins.map(w => <button type="button" key={w.id} disabled={off} onClick={() => local ? (changeSurface("Overview"), setWin(w.id)) : openViewer(h.id, w.monitor)}><span className="pl-glyph"><WindowIcon kind={w.kind} size={13} /></span><span>{w.title}</span><small>{w.app}</small></button>)}</div>
    </>;
  } else if (selectedMonitor) {
    const m = selectedMonitor; const { w, h } = mmSize(m); const owner = ownerOf(m);
    const context = sel.kind === "monitor" && sel.host && mode === "Hosts" ? hostBy(sel.host) : null;
    inspector = <>
      <header className="pl-ins-head"><div><h3>{m.name}</h3><p><code>{m.diagonalIn}″ · {Math.round(w)} × {Math.round(h)} mm · {m.px[0]} × {m.px[1]}</code></p></div></header>
      {context && <p className="pl-context">Selected in {context.name}’s arrangement{m.inputs.length > 1 ? " · same panel appears under " + m.inputs.filter(i => i.host !== context.id).map(i => hostBy(i.host).name).join(", ") : ""}</p>}
      <h4>{m.builtin ? "Screen" : "Inputs"}</h4>
      <div className="pl-inputs">{m.inputs.map(i => {
        const host = hostBy(i.host); const off = isOff(i.host); const on = owner === i.host;
        return <div key={i.host} className="pl-input" data-owner={on || undefined}>
          <button type="button" className="pl-input-host" onClick={() => select({ kind: "host", host: i.host })}>{host.name}</button>
          <code>{i.port}</code>
          <span className="pl-input-state">{m.builtin ? "Built in" : on ? "On screen" : owner === null ? "Unknown" : "Attached"}{off && " · offline"}</span>
          <span className="pl-input-actions">
            {i.host !== "local" && <button type="button" className="pl-btn pl-btn--small" disabled={off} onClick={() => openViewer(i.host, m.id)}>View</button>}
            {m.inputs.length > 1 && !on && <button type="button" className="pl-btn pl-btn--small" onClick={() => setNotice(`Switching ${m.name} to ${host.name} (${i.port}) is illustrative here.`)}>Show here</button>}
          </span>
        </div>;
      })}</div>
      {m.inputs.length > 1 && owner === null && <p className="pl-note-block">Lattices hasn’t read this monitor’s current input, so none is marked.</p>}
      <p className="pl-note-block">View streams a host’s capture. Show here switches the panel’s input. Visit, which moves your keyboard and pointer, belongs to a host.</p>
    </>;
  }

  // ---- Overview / Layers ----
  const localMonitors: MonitorID[] = ["u32", "dell"];
  const inLayer = (w: PlanWindow) => layer === "All windows" || w.layer === layer;
  const localWins = planWindows.filter(w => w.host === "local");
  const listed = localWins.filter(w => inLayer(w) && (!q || `${w.title} ${w.app}`.toLowerCase().includes(q)));
  const wsScale = 2.2;
  const workspace = <div className="pl-ws">
    <nav className="pl-layers" aria-label="Layers">
      {["All windows", ...planLayers].map(l => <button type="button" key={l} aria-pressed={layer === l} onClick={() => setLayer(l)}><span>{l}</span><small>{l === "All windows" ? localWins.length : localWins.filter(w => w.layer === l).length}</small></button>)}
    </nav>
    <div className="pl-ws-main">
      <header className="pl-ws-head"><h3>{layer}</h3><p>{listed.length} {listed.length === 1 ? "window" : "windows"} on This Mac{surface === "Layers" ? ", across desktops" : ""}</p></header>
      <div className="pl-ws-map" style={{ "--cell": `${100 / wsScale}px` } as CSSProperties}>{localMonitors.map(id => {
        const m = monitorBy(id); const { w, h } = mmSize(m); const d = desktops[id] ?? 1;
        const shown = localWins.filter(x => x.monitor === id && (surface === "Layers" ? inLayer(x) : x.desktop === d));
        return <section key={id} className="pl-ws-display">
          <div className="pl-ws-screen" style={{ width: w / wsScale, height: h / wsScale }}>
            {shown.map(x => <button type="button" key={x.id} className="pl-ws-win" data-ghost={!inLayer(x) || undefined} data-selected={win === x.id || undefined}
              style={{ left: `${x.frame[0] * 100}%`, top: `${x.frame[1] * 100}%`, width: `${x.frame[2] * 100}%`, height: `${x.frame[3] * 100}%` }}
              onClick={() => setWin(x.id)} aria-pressed={win === x.id}><WindowIcon kind={x.kind} /><em>{x.title}</em>{surface === "Layers" && <small>Desktop {x.desktop}</small>}</button>)}
            {shown.length === 0 && <span className="pl-screen-note">{surface === "Layers" ? `No ${layer === "All windows" ? "" : layer + " "}windows on this display` : "No windows on this desktop"}</span>}
          </div>
          <div className="pl-ws-caption"><span>{m.name}{ownerOf(m) !== "local" && <small>{ownerOf(m) === null ? "input unknown" : `showing ${hostBy(ownerOf(m)!).name}`}</small>}</span>
            {surface === "Overview" && <span className="pl-desktops" role="group" aria-label={`${m.name} desktops`}>{Array.from({ length: desktopCount[id] ?? 1 }, (_, n) => <button type="button" key={n} aria-pressed={d === n + 1} aria-label={`${m.name} desktop ${n + 1}`} onClick={() => setDesktops(p => ({ ...p, [id]: n + 1 }))}>{n + 1}</button>)}</span>}
          </div>
        </section>;
      })}</div>
      <div className="pl-wlist" role="list">
        {listed.map(w => <button type="button" role="listitem" key={w.id} className="pl-wrow" aria-pressed={win === w.id} onClick={() => { setWin(w.id); setDesktops(p => ({ ...p, [w.monitor]: w.desktop })); }}>
          <span className="pl-glyph"><WindowIcon kind={w.kind} size={13} /></span><strong>{w.title}</strong><span>{w.app}</span><span>{w.layer}</span><span>{monitorBy(w.monitor).name} · Desktop {w.desktop}</span>
        </button>)}
        {listed.length === 0 && <div className="pl-empty">No windows match. <button type="button" onClick={() => { setQuery(""); setLayer("All windows"); }}>Show all windows</button></div>}
      </div>
    </div>
  </div>;

  const viewerMonitor = viewer ? monitorBy(viewer.monitor) : null;

  return <div className="pl-wrap">
    <section className="pl-app" aria-label="Plan: interactive Lattices prototype">
      <aside className="pl-side">
        <div className="pl-traffic" aria-hidden="true"><i /><i /><i /></div>
        <div className="pl-brand"><span className="pl-mark" aria-hidden="true">{Array.from({ length: 9 }, (_, i) => <i key={i} />)}</span>Lattices</div>
        {(["Overview", "Layers", "Machines"] as Surface[]).map(s => <button type="button" key={s} aria-current={surface === s ? "page" : undefined} onClick={() => changeSurface(s)}>{s}</button>)}
      </aside>
      <div className="pl-main">
        <header className="pl-toolbar">
          <h2>{surface}</h2>
          {surface === "Machines" && <div className="pl-modes" role="group" aria-label="Canvas">{(["Desk", "Hosts"] as Mode[]).map(m => <button type="button" key={m} aria-pressed={mode === m} onClick={() => { setMode(m); setAutoScale(true); }}>{m}</button>)}</div>}
          <label className="pl-search"><Search size={13} /><input value={query} onChange={e => setQuery(e.target.value)} placeholder={surface === "Machines" ? "Filter machines and monitors" : "Filter windows"} aria-label="Filter" /></label>
        </header>
        {surface === "Machines" ? <>
          <div className="pl-canvas" ref={canvasRef}>{mode === "Hosts" ? hostsCanvas : deskCanvas}</div>
          <div className="pl-scalebar">
            <span className="pl-ruler" style={{ width: cell }} aria-hidden="true" /><span>10 cm</span>
            <span className="pl-scale-note">Sizes from panel specs · {mode === "Desk" ? "desk positions" : "arrangements"} illustrative</span>
            <span className="pl-zoom"><button type="button" aria-label="Zoom out" disabled={scale === SCALES[0]} onClick={() => zoom(-1)}><Minus size={12} /></button>
              <button type="button" onClick={() => setAutoScale(true)} aria-pressed={autoScale}>Fit</button>
              <button type="button" aria-label="Zoom in" disabled={scale === SCALES[SCALES.length - 1]} onClick={() => zoom(1)}><Plus size={12} /></button></span>
          </div>
          <div className="pl-lower">
            <div className="pl-outline" aria-label={mode === "Hosts" ? "Machines and their displays" : "Physical monitors"}>
              {mode === "Hosts" ? hostsOutline : deskOutline}
              {outlineEmpty && <div className="pl-empty">Nothing matches “{query}”. <button type="button" onClick={() => setQuery("")}>Clear filter</button></div>}
            </div>
            <aside className="pl-inspector" aria-label="Selection">{inspector}</aside>
          </div>
        </> : workspace}
        {notice && <div className="pl-notice" role="status"><span>{notice}</span><button type="button" aria-label="Dismiss" onClick={() => setNotice("")}><X size={13} /></button></div>}
        <footer className="pl-status">Illustrative fixtures · no live connection</footer>
      </div>
      {viewer && viewerMonitor && <dialog ref={dialogRef} className="pl-viewer" onCancel={e => { e.preventDefault(); closeViewer(); }} aria-label="Illustrative viewer">
        <header><span><strong>{hostBy(viewer.host).name}</strong> · {viewerMonitor.name}</span><small>Lattices viewer · illustrative capture</small><button type="button" autoFocus onClick={closeViewer} aria-label="Close viewer"><X size={16} /></button></header>
        <Screen m={viewerMonitor} host={viewer.host} scale={mmSize(viewerMonitor).w / (viewerMonitor.builtin ? 640 : 900)} desktop={1} label={`${viewerMonitor.name} capture`} onSelect={() => {}} />
      </dialog>}
    </section>
    <div className="pl-scenarios" role="group" aria-label="Review scenarios">
      <label><input type="checkbox" checked={offline} onChange={e => setOffline(e.target.checked)} />arts-mini offline</label>
      <label><input type="checkbox" checked={unknown} onChange={e => setUnknown(e.target.checked)} />DELL input not read</label>
    </div>
  </div>;
}
