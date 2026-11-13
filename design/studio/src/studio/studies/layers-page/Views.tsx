"use client";

import { useMemo, useState } from "react";
import { AppWindow, Calendar, ChevronDown, Code2, FileText, Globe, Hash, ListTodo, Music, PenTool, Pin, Plus, StickyNote, Terminal, type LucideIcon } from "lucide-react";
import { claim, describe, held, layers as initial, unassigned, windows, type Layer, type Rule, type Win } from "./model";
import "./layers-page.css";

/* Three ways to read the Layers page as a mapping, not a map: which apps and
   windows go to which layer, by a rule (app, app and title) or by a pin. */

const icons: Record<string, LucideIcon> = { Ghostty: Terminal, Zed: Code2, Chrome: Globe, Notes: StickyNote, Linear: ListTodo, Slack: Hash, Figma: PenTool, Calendar, Spotify: Music, Preview: FileText };
const Icon = ({ app, size = 12 }: { app: string; size?: number }) => { const I = icons[app] ?? AppWindow; return <I size={size} strokeWidth={1.75} />; };

/** The layers as state, so assigning a window in the study changes what holds it. */
function useLayers() {
  const [list, setList] = useState<Layer[]>(initial);
  const add = (layerId: string, rule: Rule) =>
    setList(ls => ls.map(l => l.id === layerId ? { ...l, rules: [...l.rules, rule] } : l));
  const pin = (layerId: string, w: Win) => add(layerId, { kind: "pin", app: w.app, title: w.title, win: w.id });
  const app = (layerId: string, w: Win) => add(layerId, { kind: "app", app: w.app });
  return { list, pin, app };
}

function Slot({ n }: { n: number }) { return <kbd className="lp-slot">⌘⌥{n}</kbd>; }

function Why({ rule }: { rule: Rule }) {
  return <span className="lp-why" data-kind={rule.kind}>
    {rule.kind === "pin" ? <><Pin size={10} />Pinned</> : rule.kind === "app" ? <>App is {rule.app}</> : <>Title has “{rule.title}”</>}
  </span>;
}

/** Assign an unclaimed window: pin this one window, or take every window of its app. */
function Assign({ w, list, pin, app }: { w: Win; list: Layer[]; pin: (l: string, w: Win) => void; app: (l: string, w: Win) => void }) {
  const [open, setOpen] = useState(false);
  return <div className="lp-assign">
    <button type="button" className="lp-ghost" onClick={() => setOpen(o => !o)}>Add to layer<ChevronDown size={11} /></button>
    {open && <div className="lp-menu" onMouseLeave={() => setOpen(false)}>
      {list.map(l => <div key={l.id} className="lp-menu-row">
        <span>{l.label}</span>
        <button type="button" onClick={() => { pin(l.id, w); setOpen(false); }}>This window</button>
        <button type="button" onClick={() => { app(l.id, w); setOpen(false); }}>All {w.app}</button>
      </div>)}
    </div>}
  </div>;
}

/* ── A · Rules: one layer at a time, its rules and pins, each with what it holds ── */

export function RulesView() {
  const { list, pin, app } = useLayers();
  const [sel, setSel] = useState(list[0].id);
  const layer = list.find(l => l.id === sel)!;
  const rules = layer.rules.filter(r => r.kind !== "pin");
  const pins = layer.rules.filter(r => r.kind === "pin");
  const loose = unassigned(list);
  const count = (l: Layer) => windows.filter(w => claim(w, list)?.layer === l).length;

  return <div className="lp">
    <nav className="lp-layers">
      {list.map(l => <button key={l.id} type="button" className="lp-layer" data-selected={l.id === sel} onClick={() => setSel(l.id)}>
        <Slot n={l.slot} /><span>{l.label}</span><em>{count(l) || "—"}</em>
      </button>)}
      <button type="button" className="lp-layer lp-layer--add"><Plus size={12} />New layer</button>
    </nav>

    <main className="lp-main">
      <header className="lp-head">
        <h3>{layer.label}</h3><Slot n={layer.slot} />
        <span className="lp-dim">{count(layer)} windows open</span>
      </header>

      <section className="lp-card">
        <h4>Rules<span>Any window that matches, now or later</span></h4>
        {rules.map((r, i) => {
          const h = held(r, layer, list);
          return <div key={i} className="lp-rule">
            <span className="lp-app"><Icon app={r.app} />{r.app}</span>
            <span className="lp-cond">{describe(r)}</span>
            <span className="lp-holds">{h.length ? h.map(w => <i key={w.id} title={w.title}>{w.title}</i>) : <em>Nothing open</em>}</span>
          </div>;
        })}
        <button type="button" className="lp-add"><Plus size={12} />Add rule</button>
      </section>

      <section className="lp-card">
        <h4>Pinned<span>These exact windows, added by hand</span></h4>
        {pins.length ? pins.map((r, i) => <div key={i} className="lp-rule">
          <span className="lp-app"><Icon app={r.app} />{r.app}</span>
          <span className="lp-cond lp-mono">{r.title}</span>
          <span className="lp-holds"><Pin size={11} /></span>
        </div>) : <p className="lp-none">No pinned windows</p>}
      </section>
    </main>

    <aside className="lp-tray">
      <h4>Not on a layer<span>{loose.length}</span></h4>
      {loose.map(w => <div key={w.id} className="lp-loose">
        <span className="lp-app"><Icon app={w.app} />{w.app}</span>
        <span className="lp-mono lp-dim">{w.title}</span>
        <div className="lp-loose-acts">
          <button type="button" className="lp-ghost" onClick={() => pin(layer.id, w)}>Pin to {layer.label}</button>
          <Assign w={w} list={list} pin={pin} app={app} />
        </div>
      </div>)}
      {!loose.length && <p className="lp-none">Every window has a layer</p>}
    </aside>
  </div>;
}

/* ── B · By window: every open window once, its layer and the rule that put it there ── */

export function ByWindowView() {
  const { list, pin, app } = useLayers();
  const [only, setOnly] = useState(false);
  const rows = useMemo(() => {
    const all = windows.map(w => ({ w, c: claim(w, list) }));
    return only ? all.filter(r => !r.c) : all;
  }, [list, only]);
  const byApp = useMemo(() => {
    const m = new Map<string, typeof rows>();
    rows.forEach(r => m.set(r.w.app, [...(m.get(r.w.app) ?? []), r]));
    return [...m.entries()];
  }, [rows]);
  const loose = unassigned(list).length;

  return <div className="lp lp--single">
    <main className="lp-main">
      <div className="lp-bar">
        <span className="lp-count"><strong>{windows.length - loose}</strong> of {windows.length} windows on a layer</span>
        <div className="lp-grow" />
        <div className="lp-seg">
          <button type="button" data-active={!only} onClick={() => setOnly(false)}>All</button>
          <button type="button" data-active={only} onClick={() => setOnly(true)}>Not on a layer<em>{loose}</em></button>
        </div>
      </div>
      <section className="lp-card lp-table">
        {byApp.map(([appName, rs]) => <div key={appName} className="lp-group">
          <h5><Icon app={appName} />{appName}</h5>
          {rs.map(({ w, c }) => <div key={w.id} className="lp-trow" data-loose={!c}>
            <span className="lp-mono">{w.title}</span>
            {c ? <span className="lp-layername">{c.layer.label}<Slot n={c.layer.slot} /></span> : <span className="lp-dim">—</span>}
            {c ? <Why rule={c.rule} /> : <Assign w={w} list={list} pin={pin} app={app} />}
          </div>)}
        </div>)}
      </section>
    </main>
  </div>;
}

/* ── C · Board: a column per layer, rules as cards with what they hold ── */

export function BoardView() {
  const { list, pin, app } = useLayers();
  const loose = unassigned(list);
  return <div className="lp lp--board">
    <section className="lp-col lp-col--loose">
      <h4>Not on a layer<span>{loose.length}</span></h4>
      {loose.map(w => <div key={w.id} className="lp-chip">
        <span className="lp-app"><Icon app={w.app} />{w.app}</span>
        <span className="lp-mono lp-dim">{w.title}</span>
        <Assign w={w} list={list} pin={pin} app={app} />
      </div>)}
    </section>
    {list.map(l => <section key={l.id} className="lp-col">
      <h4>{l.label}<Slot n={l.slot} /></h4>
      {l.rules.map((r, i) => {
        const h = held(r, l, list);
        return <div key={i} className="lp-rulecard" data-kind={r.kind}>
          <div className="lp-rulecard-head"><span className="lp-app"><Icon app={r.app} />{r.app}</span>{r.kind === "pin" && <Pin size={11} />}</div>
          <span className="lp-cond">{r.kind === "pin" ? <span className="lp-mono">{r.title}</span> : describe(r)}</span>
          {r.kind !== "pin" && <span className="lp-held">{h.length ? `${h.length} open` : "Nothing open"}</span>}
        </div>;
      })}
      <button type="button" className="lp-add"><Plus size={12} />Add rule</button>
    </section>)}
  </div>;
}
