"use client";

import { useState } from "react";
import {
  B_APPS,
  B_LAYERS,
  B_RECENT,
  B_SESSIONS,
  BAppIcon,
  BBtn,
  BI,
  BSec,
  BWindow,
  FRONT_WINDOW,
  NINE,
  spaceLabel,
  type BPlace,
} from "./_b";
import { CommandBar } from "./CommandBar";

/** The toolbar actions Home carries. The navigator exhibit shows the same page. */
export function HomeActions() {
  return (
    <>
      <BBtn icon="scan">Scan</BBtn>
      <BBtn icon="play" primary>
        Start session
      </BBtn>
    </>
  );
}

export function HomePanelB() {
  const [place, setPlace] = useState<BPlace | null>(null);
  const running = B_SESSIONS.filter((s) => s.running).length;
  const front = FRONT_WINDOW;

  return (
    <BWindow tab="home" actions={<HomeActions />}>
      <CommandBar />

      <div className="bs-browse">
        <section>
          <BSec title="Front" />
          <div className="bs-front">
            <div className="bs-front__head">
              <BAppIcon app={front.app} size={26} />
              <span style={{ minWidth: 0 }}>
                <span className="bs-front__app">{B_APPS[front.app].label}</span>
                <span className="bs-front__title">{front.title}</span>
              </span>
            </div>
            <p className="bs-front__meta">
              {spaceLabel(front)} · {front.w}×{front.h} at {front.x},{front.y}
            </p>
            <div className="bs-nine">
              {NINE.map((cell) => (
                <button
                  key={cell.place}
                  type="button"
                  title={cell.label}
                  aria-label={cell.label}
                  aria-pressed={place === cell.place}
                  onClick={() => setPlace(place === cell.place ? null : cell.place)}
                />
              ))}
            </div>
            <div className="bs-front__more">
              <BBtn icon="maximize">Maximize</BBtn>
              <BBtn icon="send">Send to Built-in</BBtn>
            </div>
          </div>
        </section>

        <section>
          <BSec title="Sessions" count={`${running} running`} />
          <div className="bs-rows">
            {B_SESSIONS.map((s) => (
              <div key={s.name} className="bs-row">
                <i className={`bs-dot${s.running ? " bs-dot--on" : ""}`} />
                <span className="bs-row__text">
                  <span className="bs-row__name">{s.name}</span>
                  <span className="bs-row__sub">
                    {s.path}
                    {s.panes ? ` · ${s.panes} panes` : ""}
                  </span>
                </span>
                <button type="button" className="bs-row__verb">
                  {s.running ? "Attach" : "Launch"}
                </button>
              </div>
            ))}
          </div>
        </section>

        <section>
          <BSec title="Layers" />
          <div className="bs-rows">
            {B_LAYERS.map((layer) => (
              <div key={layer.label} className="bs-row">
                <BI name="layers" />
                <span className="bs-row__text">
                  <span className="bs-row__name">{layer.label}</span>
                  <span className="bs-row__sub">
                    {layer.running > 0
                      ? `${layer.running} of ${layer.total} running`
                      : `${layer.total} projects`}
                    {layer.active ? " · active" : ""}
                  </span>
                </span>
                <button type="button" className="bs-row__verb">
                  {layer.running > 0 ? "Focus" : "Launch"}
                </button>
              </div>
            ))}
          </div>
        </section>

        <section className="bs-recent">
          <BSec title="Recent" />
          <div className="bs-rows">
            {B_RECENT.map((r) => (
              <div key={r.what} className="bs-row">
                <BI name={r.icon} />
                <span className="bs-row__text">
                  <span className="bs-row__name">{r.what}</span>
                  <span className="bs-row__sub">{r.when} ago</span>
                </span>
                <button type="button" className="bs-row__verb">
                  Again
                </button>
              </div>
            ))}
          </div>
        </section>
      </div>
    </BWindow>
  );
}
