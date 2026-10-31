"use client";

import { useMemo, useState, type CSSProperties } from "react";
import { ChevronDown, Code2, Globe, Hash, ListTodo, PenTool, Search, Settings, StickyNote, Terminal, type LucideIcon } from "lucide-react";
import { displays, layers, placements, windows, type Display, type DisplayID, type Win } from "./model";
import "./structured.css";

/* F · Structured. The windows stay the hero; what changes is that every piece
   of information has one home. A display is a card. Its desktops are tabs on
   that card. The map and the table under it show the same windows, in the same
   order. Layers drop to a quiet filter, and the selected window's actions sit
   in one inspector. */

const icons: Record<string, LucideIcon> = { Ghostty: Terminal, Zed: Code2, Chrome: Globe, Notes: StickyNote, Linear: ListTodo, Slack: Hash, Figma: PenTool, "System Settings": Settings };
const Icon = ({ app, size = 12 }: { app: string; size?: number }) => { const I = icons[app] ?? Globe; return <I size={size} strokeWidth={1.75} />; };

/** Windows without a recorded frame get a simple cascade so the map never lies empty. */
function frameOf(w: Win, i: number, n: number): [number, number, number, number] {
  if (w.frame) return w.frame;
  const width = 1 / Math.max(n, 1);
  return [i * width + 0.02, 0.06, width - 0.04, 0.88];
}

function where(w: Win) {
  const [x, , wd] = w.frame ?? [0, 0, 0];
  if (!w.frame) return "—";
  if (wd > 0.9) return "Full";
  if (x + wd / 2 < 0.4) return "Left";
  if (x + wd / 2 > 0.6) return "Right";
  return "Centre";
}

type Pick = { selected?: string; onSelect: (id: string) => void; loading: boolean };

function Tabs({ display, list, shown, setShown }: { display: Display; list: Win[]; shown: number; setShown: (n: number) => void }) {
  return <div className="wps-tabs" role="tablist">
    {Array.from({ length: display.desktops }, (_, i) => i + 1).map(n => {
      const count = list.filter(w => w.display === display.id && w.desktop === n).length;
      return <button key={n} type="button" role="tab" aria-selected={n === shown} data-empty={count === 0} onClick={() => setShown(n)}>
        {n === display.current && <i title="Showing now" />}{n}
      </button>;
    })}
  </div>;
}

function Head({ display }: { display: Display }) {
  return <header className="wps-card-head">
    <strong>{display.name}</strong>
    <span className="wps-mono">{display.resolution.replace(" × ", "×")}</span>
  </header>;
}

function MapWell({ display, here, shown, selected, onSelect, loading }: Pick & { display: Display; here: Win[]; shown: number }) {
  return <div className="wps-map" style={{ aspectRatio: display.ratio }}>
    {loading ? <div className="wps-map-ghost" />
      : here.length === 0 ? <span className="wps-map-empty">Desktop {shown} is empty</span>
      : here.map((w, i) => {
        const [x, y, wd, h] = frameOf(w, i, here.length);
        return <button key={w.id} type="button" className="wps-tile" data-selected={w.id === selected} onClick={() => onSelect(w.id)}
          style={{ left: `${x * 100}%`, top: `${y * 100}%`, width: `${wd * 100}%`, height: `${h * 100}%` }}>
          <span className="wps-tile-bar"><Icon app={w.app} size={10} />{w.app}</span>
          <span className="wps-tile-title">{w.title.replaceAll("/", "/\u200b")}</span>
        </button>;
      })}
  </div>;
}

function Row({ w, selected, onSelect, where: place }: { w: Win; selected?: string; onSelect: (id: string) => void; where: string }) {
  return <button type="button" role="row" className="wps-tr" data-selected={w.id === selected} onClick={() => onSelect(w.id)}>
    <span className="wps-td-app"><Icon app={w.app} />{w.app}</span>
    <span className="wps-td-title">{w.title}</span>
    <span className="wps-td-where">{place}</span>
  </button>;
}

function Table({ rows, selected, onSelect, loading }: Pick & { rows: Win[] }) {
  return <div className="wps-table" role="table">
    {loading ? Array.from({ length: 3 }, (_, i) => <div key={i} className="wps-tr wps-tr--ghost"><i /><i /></div>)
      : rows.map(w => <Row key={w.id} w={w} selected={selected} onSelect={onSelect} where={where(w)} />)}
  </div>;
}

/** Both displays drawn side by side on one desk, then one table for everything. */
function Desk({ list, shown, setShown, ...pick }: Pick & { list: Win[]; shown: Record<DisplayID, number>; setShown: (d: DisplayID, n: number) => void }) {
  const off = list.filter(w => w.display === null);
  return <section className="wps-card wps-desk">
    <div className="wps-desk-row">
      {displays.map(d => <div key={d.id} className="wps-desk-display" style={{ flexGrow: d.ratio } as CSSProperties}>
        <div className="wps-desk-head"><Head display={d} /><Tabs display={d} list={list} shown={shown[d.id]} setShown={n => setShown(d.id, n)} /></div>
        <MapWell display={d} here={list.filter(w => w.display === d.id && w.desktop === shown[d.id])} shown={shown[d.id]} {...pick} />
      </div>)}
    </div>
    <div className="wps-table wps-table--grouped" role="table">
      {displays.map(d => {
        const here = list.filter(w => w.display === d.id && w.desktop === shown[d.id]);
        return <div key={d.id} role="rowgroup">
          <h4>{d.name}<span>Desktop {shown[d.id]}</span></h4>
          {pick.loading ? <div className="wps-tr wps-tr--ghost"><i /><i /></div>
            : here.length ? here.map(w => <Row key={w.id} w={w} selected={pick.selected} onSelect={pick.onSelect} where={where(w)} />)
            : <p className="wps-none">Nothing on this desktop</p>}
        </div>;
      })}
      {off.length > 0 && <div role="rowgroup">
        <h4>Off screen</h4>
        {off.map(w => <Row key={w.id} w={w} selected={pick.selected} onSelect={pick.onSelect} where={w.state === "minimized" ? "Minimized" : "Hidden"} />)}
      </div>}
    </div>
  </section>;
}

function Inspector({ win }: { win?: Win }) {
  if (!win) return <aside className="wps-insp wps-insp--empty">Select a window</aside>;
  const display = displays.find(d => d.id === win.display);
  return <aside className="wps-insp">
    <div className="wps-insp-id">
      <span className="wps-insp-icon"><Icon app={win.app} size={15} /></span>
      <strong>{win.app}</strong>
      <p>{win.title}</p>
    </div>
    <dl>
      <dt>Display</dt><dd>{display?.name ?? "—"}</dd>
      <dt>Desktop</dt><dd>{win.desktop ?? (win.state === "minimized" ? "Minimized" : "Hidden")}</dd>
      <dt>Layer</dt><dd>{win.layer ?? "None"}</dd>
    </dl>
    <button type="button" className="wps-primary">{win.state === "minimized" ? "Restore" : "Focus"}<kbd>↵</kbd></button>
    <section>
      <h4>Place</h4>
      <div className="wps-place">{placements.map(p => <button key={p.id} type="button"><span className={`wp-glyph wp-glyph--${p.id}`}><i /></span>{p.label.replace(" half", "")}</button>)}</div>
    </section>
    {display && <section>
      <h4>Move to desktop</h4>
      <div className="wps-desks">{Array.from({ length: display.desktops }, (_, i) => i + 1).map(n => <button key={n} type="button" disabled={n === win.desktop}>{n}</button>)}</div>
    </section>}
  </aside>;
}

export function StructuredContent({ loading }: { loading: boolean; variant?: "desk" }) {
  const [layer, setLayer] = useState("All layers");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string | undefined>("w3");
  const [shown, setShown] = useState<Record<DisplayID, number>>(() => Object.fromEntries(displays.map(d => [d.id, d.current])) as Record<DisplayID, number>);
  const list = useMemo(() => windows.filter(w =>
    (layer === "All layers" || w.layer === layer) && `${w.app} ${w.title}`.toLowerCase().includes(query.toLowerCase())), [layer, query]);
  const select = (id: string) => setSelected(id === selected ? undefined : id);

  return <div className="wps" data-loading={loading} >
    <div className="wps-main">
      <div className="wps-bar">
        <span className="wps-count"><strong>{list.length}</strong> windows on {displays.length} displays</span>
        <div className="wps-grow" />
        <label className="wps-layer">
          <select value={layer} onChange={e => setLayer(e.target.value)} aria-label="Layer">
            <option>All layers</option>{layers.map(l => <option key={l}>{l}</option>)}
          </select><ChevronDown size={11} />
        </label>
        <label className="wps-filter"><Search size={12} /><input value={query} onChange={e => setQuery(e.target.value)} placeholder="Filter" aria-label="Filter windows" /><kbd>/</kbd></label>
      </div>
      <Desk list={list} shown={shown} setShown={(d, n) => setShown(s => ({ ...s, [d]: n }))} selected={selected} onSelect={select} loading={loading} />
    </div>
    <Inspector win={windows.find(w => w.id === selected)} />
  </div>;
}
