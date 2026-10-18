"use client";

import { useMemo, useState } from "react";
import {
  B_APPS,
  B_DISPLAYS,
  B_WINDOW_TOTAL,
  B_WINDOWS,
  BAppIcon,
  BBtn,
  BI,
  BSeg,
  BWindow,
  displayOf,
  matches,
  NINE,
  spaceLabel,
  type BDisplay,
  type BDisplayKey,
  type BPlace,
  type BWin,
} from "./_b";

const QUERY = "lattices";

/** Titles need room; below this (in points) a box shows only its app. */
const ROOMY_W = 600;
const ROOMY_H = 240;

export function DesktopPanelB() {
  const [shown, setShown] = useState<Record<BDisplayKey, number>>({ studio: 1, builtin: 1 });
  const [selected, setSelected] = useState("w4");
  const [place, setPlace] = useState<BPlace | null>(null);

  const hits = useMemo(() => B_WINDOWS.filter((w) => matches(w, QUERY)), []);
  const byText = hits.filter((w) => w.ocr).length;
  const current = B_WINDOWS.find((w) => w.id === selected) ?? B_WINDOWS[0];

  return (
    <BWindow
      tab="desktop"
      actions={
        <>
          <BBtn icon="scan">Scan</BBtn>
          <BSeg
            value="map"
            options={[
              { id: "map", icon: "display", label: "Map" },
              { id: "list", icon: "list", label: "List" },
            ]}
          />
        </>
      }
    >
      <div className="bs-page__desk">
        <div className="bs-desk__head">
          <div className="bs-filter">
            <BI name="search" />
            <span>{QUERY}</span>
            <span className="bs-bar__caret bs-bar__caret--sm" />
            <span className="bs-filter__hit">
              {hits.length} of {B_WINDOW_TOTAL} · {byText} by screen text
            </span>
          </div>
          <span className="bs-desk__scan">Scanned 40s ago</span>
          <span className="bs-spacer" />
          <BBtn icon="copy">Copy as text</BBtn>
        </div>

        <div className="bs-desk__map">
          {B_DISPLAYS.map((d) => {
            const space = shown[d.key];
            const wins = B_WINDOWS.filter((w) => w.display === d.key && w.space === space).sort(
              (a, b) => a.z - b.z,
            );
            return (
              <div key={d.key} className="bs-display" style={{ flex: `${d.w} 1 0%` }}>
                <div className="bs-display__label">
                  {d.name}
                  <span>
                    {d.w}×{d.h}
                    {d.main ? " · main" : ""}
                  </span>
                </div>

                <div className="bs-display__box" style={{ aspectRatio: `${d.w} / ${d.h}` }}>
                  {wins.map((w) => (
                    <WinBox
                      key={w.id}
                      win={w}
                      host={d}
                      dim={!matches(w, QUERY)}
                      selected={w.id === selected}
                      onSelect={() => setSelected(w.id)}
                    />
                  ))}
                </div>

                <div className="bs-spaces">
                  {d.spaces.map((s) => (
                    <button
                      key={s.index}
                      type="button"
                      className="bs-space"
                      aria-pressed={s.index === space}
                      onClick={() => setShown({ ...shown, [d.key]: s.index })}
                    >
                      {s.index === d.current ? <i className="bs-dot" /> : null}
                      {s.index} {s.label}
                      <span className="bs-space__n">{s.count}</span>
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>

        <div className="bs-detail">
          <div className="bs-detail__id">
            <BAppIcon app={current.app} size={22} />
            <span>
              <span className="bs-detail__app">{B_APPS[current.app].label}</span>
              <span className="bs-detail__title">{current.title}</span>
            </span>
          </div>
          <KV k="Frame" v={`${current.w}×${current.h} at ${current.x},${current.y}`} />
          <KV k="Space" v={spaceLabel(current)} />
          <KV k="cwd" v={current.cwd ?? "—"} />
          <KV k="tmux" v={current.tmux ?? "—"} />
          <KV k="pid" v={String(current.pid)} />
          <div className="bs-detail__acts">
            <BBtn icon="focus">Focus</BBtn>
            <BBtn icon="send" trailing={<BI name="chevron" />}>
              Send to
            </BBtn>
            <div className="bs-nine bs-nine--mini" aria-label="Move to">
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
          </div>
        </div>
      </div>
    </BWindow>
  );
}

/** A window at its real frame, as a percentage of its display — so the map scales with the page. */
function WinBox({
  win,
  host,
  dim,
  selected,
  onSelect,
}: {
  win: BWin;
  host: BDisplay;
  dim: boolean;
  selected: boolean;
  onSelect: () => void;
}) {
  const pct = (n: number, of: number) => `${((n / of) * 100).toFixed(2)}%`;
  const roomy = win.w >= ROOMY_W && win.h >= ROOMY_H;
  const cls = ["bs-winbox", dim ? "bs-winbox--dim" : "", selected ? "bs-winbox--sel" : ""]
    .filter(Boolean)
    .join(" ");
  return (
    <button
      type="button"
      className={cls}
      style={{
        left: pct(win.x, host.w),
        top: pct(win.y, host.h),
        width: pct(win.w, host.w),
        height: pct(win.h, host.h),
      }}
      onClick={onSelect}
      aria-pressed={selected}
      title={`${B_APPS[win.app].label} — ${win.title} · ${displayOf(win).name}`}
    >
      <span className="bs-winbox__name">
        <BAppIcon app={win.app} size={14} />
        {B_APPS[win.app].label}
      </span>
      {roomy ? <span className="bs-winbox__title">{win.title}</span> : null}
      {win.ocr ? <BI name="text" className="bs-icon bs-winbox__ocr" /> : null}
    </button>
  );
}

function KV({ k, v }: { k: string; v: string }) {
  return (
    <dl className="bs-kv">
      <dt>{k}</dt>
      <dd>{v}</dd>
    </dl>
  );
}
