"use client";

import { useEffect, useState, type CSSProperties } from "react";
import { BookOpen, CircleDot, Columns2, Home, Layers, Maximize, MessagesSquare, Monitor, Search, Settings, Stethoscope } from "lucide-react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { windows } from "./windows-page/model";
import { StructuredContent } from "./windows-page/Structured";
import "./windows-page/windows-page.css";

type Direction = "current" | "desk";
type Accent = "coral" | "white" | "blue";

const DIRECTIONS: { id: Direction; name: string; note: string }[] = [
  { id: "current", name: "Today", note: "Screenshot of the shipped page" },
  { id: "desk", name: "Desk", note: "Both displays on one desk as they sit, then one table grouped by display" },
];

const ACCENTS: Record<Accent, string> = { coral: "#ef6a47", white: "rgba(255,255,255,0.92)", blue: "#4c8dff" };

/* ── Shell: mirrors AppShellView (sidebar on the window background, content in an inset panel) ── */

function Sidebar() {
  const item = (icon: React.ReactNode, label: string, active = false) =>
    <div className="wp-nav" data-active={active}>{icon}<span>{label}</span></div>;
  return <aside className="wp-sidebar">
    <div className="wp-traffic"><i /><i /><i /></div>
    <div className="wp-brand"><span className="wp-mark"><i /><i /><i /><i /></span>Lattices</div>
    <div className="wp-nav-label">Workspace</div>
    {item(<Home />, "Home")}{item(<Columns2 />, "Windows", true)}{item(<Layers />, "Layers")}{item(<Monitor />, "Machines")}
    <div className="wp-nav-label">Agents</div>
    {item(<MessagesSquare />, "Assistant")}{item(<CircleDot />, "Runs")}
    <div className="wp-sidebar-foot">{item(<Stethoscope />, "Diagnostics")}{item(<BookOpen />, "Docs")}{item(<Settings />, "Settings")}</div>
  </aside>;
}

function AppWindow({ variant, loading, accent }: { variant: "desk"; loading: boolean; accent: Accent }) {
  return <section className="wp-app" style={{ "--accent": ACCENTS[accent] } as CSSProperties}>
    <Sidebar />
    <div className="wp-body">
      <header className="wp-titlebar">
        <h2>Windows</h2><div className="wp-spacer" />
        <button type="button" className="wp-btn"><Maximize size={12} />Here</button>
        <button type="button" className="wp-btn"><Search size={12} />Search<kbd>⌘K</kbd></button>
      </header>
      <StructuredContent key={variant} variant={variant} loading={loading} />
      <footer className="wp-status"><span>0 sessions running · {windows.length} content windows · 2 displays</span><span>Screen text off</span></footer>
    </div>
  </section>;
}

/** Shrinks the 1280-wide window to fit the stage, so every direction is judged whole. */
function useFit() {
  const [el, setEl] = useState<HTMLDivElement | null>(null);
  const [scale, setScale] = useState(1);
  useEffect(() => {
    if (!el) return;
    const ro = new ResizeObserver(() => setScale(Math.min(1, el.clientWidth / 1282)));
    ro.observe(el);
    return () => ro.disconnect();
  }, [el]);
  return { ref: setEl, scale };
}

export function WindowsPageStudy({ page }: { page: LatticesPage }) {
  const fit = useFit();
  const [direction, setDirection] = useState<Direction>("desk");
  const [accent, setAccent] = useState<Accent>("coral");
  const [loading, setLoading] = useState(false);
  useEffect(() => {
    if (!loading) return;
    const t = setTimeout(() => setLoading(false), 700);
    return () => clearTimeout(t);
  }, [loading]);

  return <div className="wp-study">
    <header className="wp-study-head">
      <div><h1>{page.label}</h1><p>{page.blurb}</p></div>
    </header>
    <nav className="wp-study-bar">
      <div className="wp-tabs">{DIRECTIONS.map(d => <button key={d.id} type="button" data-active={d.id === direction} onClick={() => setDirection(d.id)} title={d.note}>{d.name}</button>)}</div>
      <div className="wp-spacer" />
      {direction !== "current" && <>
        <div className="wp-tabs">{(Object.keys(ACCENTS) as Accent[]).map(a => <button key={a} type="button" data-active={a === accent} onClick={() => setAccent(a)}><i className="wp-swatch" style={{ background: ACCENTS[a] }} />{a}</button>)}</div>
        <button type="button" className="wp-replay" onClick={() => setLoading(true)}>Replay load</button>
      </>}
    </nav>
    <p className="wp-study-note">{DIRECTIONS.find(d => d.id === direction)!.note}</p>
    <div className="wp-stage" ref={fit.ref} style={{ height: 722 * fit.scale }}>
      <div style={{ transform: `scale(${fit.scale})`, transformOrigin: "top left" }}>
        {direction === "current"
          ? <img className="wp-current" src="/windows-page/current.png" alt="The Windows page as shipped" />
          : <AppWindow variant={direction} loading={loading} accent={accent} />}
      </div>
    </div>
  </div>;
}
