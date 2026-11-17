"use client";

import { useState } from "react";
import { Maximize, Search } from "lucide-react";
import type { LatticesPage } from "@/studio/studioRegistry";
import { Sidebar, useFit } from "./WindowsPage";
import { windows } from "./layers-page/model";
import { BoardView, ByWindowView, RulesView } from "./layers-page/Views";
import "./windows-page/windows-page.css";

type Direction = "current" | "rules" | "windows" | "board";

const DIRECTIONS: { id: Direction; name: string; note: string }[] = [
  { id: "current", name: "Today", note: "Screenshot of the shipped page" },
  { id: "rules", name: "Rules", note: "Pick a layer, read its rules and pins, and what each one holds right now" },
  { id: "windows", name: "By window", note: "Every open window once, with the layer that holds it and why" },
  { id: "board", name: "Board", note: "One column per layer, rules as cards, the unclaimed windows in the first column" },
];

function AppWindow({ direction }: { direction: Exclude<Direction, "current"> }) {
  return <section className="wp-app">
    <Sidebar active="Layers" />
    <div className="wp-body">
      <header className="wp-titlebar">
        <h2>Layers</h2><div className="wp-spacer" />
        <button type="button" className="wp-btn"><Maximize size={12} />Here</button>
        <button type="button" className="wp-btn"><Search size={12} />Search<kbd>⌘K</kbd></button>
      </header>
      {direction === "rules" ? <RulesView /> : direction === "windows" ? <ByWindowView /> : <BoardView />}
      <footer className="wp-status"><span>0 sessions running · {windows.length} content windows · 2 displays</span><span>Screen text off</span></footer>
    </div>
  </section>;
}

export function LayersPageStudy({ page }: { page: LatticesPage }) {
  const fit = useFit();
  const [direction, setDirection] = useState<Direction>("rules");

  return <div className="wp-study">
    <header className="wp-study-head">
      <div><h1>{page.label}</h1><p>{page.blurb}</p></div>
    </header>
    <nav className="wp-study-bar">
      <div className="wp-tabs">{DIRECTIONS.map(d => <button key={d.id} type="button" data-active={d.id === direction} onClick={() => setDirection(d.id)} title={d.note}>{d.name}</button>)}</div>
    </nav>
    <p className="wp-study-note">{DIRECTIONS.find(d => d.id === direction)!.note}</p>
    <div className="wp-stage" ref={fit.ref} style={{ height: 722 * fit.scale }}>
      <div style={{ transform: `scale(${fit.scale})`, transformOrigin: "top left" }}>
        {direction === "current"
          ? <img className="wp-current" style={{ objectFit: "contain", background: "#1c1c1e" }} src="/layers-page/current.png" alt="The Layers page as shipped" />
          : <AppWindow direction={direction} />}
      </div>
    </div>
  </div>;
}
