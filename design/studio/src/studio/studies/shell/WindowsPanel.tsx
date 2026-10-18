"use client";

import { useMemo, useState } from "react";
import {
  APPS,
  AppIcon,
  AppWindow,
  Btn,
  ColHead,
  DISPLAYS,
  Icon,
  Kbd,
  OcrLine,
  Rail,
  Sec,
  StatusBar,
  Toolbar,
  WindowRow,
  WINDOWS,
  type DisplayKey,
  type Win,
} from "./_shell";

const SPACES = [
  { label: "1 · Build", n: 15 },
  { label: "2 · Review", n: 9 },
  { label: "3 · Comms", n: 7 },
  { label: "4 · Scratch", n: 7 },
];

/* Apps with fewer than four windows don't earn their own filter row —
   they collapse into the overflow control instead. */
const APP_FILTERS = [
  { app: "ghostty", n: 9 },
  { app: "chrome", n: 8 },
  { app: "xcode", n: 4 },
  { app: "slack", n: 3 },
] as const;

const PLACEMENTS = [
  "Top left", "Top", "Top right",
  "Left", "Center", "Right",
  "Bottom left", "Bottom", "Bottom right",
];

export function WindowsPanel() {
  const [display, setDisplay] = useState<DisplayKey | null>("studio");
  const [selected, setSelected] = useState<string[]>(["w1", "w2"]);
  const [placement, setPlacement] = useState("Left");

  const visible = useMemo(
    () => WINDOWS.filter((w) => (display ? w.display === display : true)),
    [display],
  );

  const groups = useMemo(() => {
    const byGroup = new Map<string, Win[]>();
    for (const win of visible) {
      const key = `${DISPLAYS[win.display].label} · Space ${win.space}`;
      byGroup.set(key, [...(byGroup.get(key) ?? []), win]);
    }
    return [...byGroup.entries()];
  }, [visible]);

  const focused = WINDOWS.find((w) => w.id === selected[selected.length - 1]) ?? WINDOWS[0];

  const toggle = (id: string) =>
    setSelected((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));

  return (
    <AppWindow>
      <div className="as-body">
        <Rail active="windows" />

        <div className="as-content">
          <Toolbar
            title="Windows"
            sub={selected.length ? `${selected.length} selected` : undefined}
          >
            <Btn icon="copy">Copy inventory</Btn>
            <Btn trailing={<Icon name="chevron" />}>Group by space</Btn>
            <Btn icon="studio" primary>
              Tile selection
            </Btn>
          </Toolbar>

          <div className="as-scroll">
            <div className="as-inv">
              <div className="as-side">
                <div className="as-side__grp">
                  <p className="as-side__label">Displays</p>
                  {(Object.keys(DISPLAYS) as DisplayKey[]).map((key) => (
                    <button
                      key={key}
                      type="button"
                      className="as-filt"
                      aria-pressed={display === key}
                      onClick={() => setDisplay(display === key ? null : key)}
                    >
                      <span
                        className="as-filt__sw"
                        style={{ background: DISPLAYS[key].swatch }}
                      />
                      <span className="as-filt__name">{DISPLAYS[key].label}</span>
                      <span className="as-filt__n">{DISPLAYS[key].windows}</span>
                    </button>
                  ))}
                </div>

                <div className="as-side__grp">
                  <p className="as-side__label">Spaces</p>
                  {SPACES.map((space) => (
                    <button key={space.label} type="button" className="as-filt">
                      <span className="as-filt__name">{space.label}</span>
                      <span className="as-filt__n">{space.n}</span>
                    </button>
                  ))}
                </div>

                <div className="as-side__grp">
                  <p className="as-side__label">Apps</p>
                  {APP_FILTERS.map((entry) => (
                    <button key={entry.app} type="button" className="as-filt">
                      <span className="as-filt__name">{APPS[entry.app].label}</span>
                      <span className="as-filt__n">{entry.n}</span>
                    </button>
                  ))}
                  <button type="button" className="as-filt as-filt--more">
                    <span className="as-filt__name">12 more</span>
                    <Icon name="chevron" className="as-icon" />
                  </button>
                </div>
              </div>

              <div className="as-invmain">
                <div className="as-invbar">
                  <div className="as-search">
                    <Icon name="search" />
                    <span>lattices</span>
                    <span className="as-search__hit">11 windows · 4 by screen text</span>
                  </div>
                  <Btn icon="filter">Filters</Btn>
                </div>

                <div className="as-invrows as-table as-table--inv">
                  <ColHead compact />
                  {groups.map(([label, wins], groupIndex) => (
                    <div key={label}>
                      <div className="as-grouphead">
                        {label}
                        {groupIndex === 0 ? (
                          <span className="as-grouphead__hint">current</span>
                        ) : null}
                      </div>
                      {wins.map((win) => (
                        <div key={win.id}>
                          <WindowRow
                            win={win}
                            compact
                            spaceLabel={win.space}
                            selected={selected.includes(win.id)}
                            onSelect={() => toggle(win.id)}
                          />
                          <OcrLine win={win} />
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              </div>

              <div className="as-insp">
                <div className="as-insp__head">
                  <AppIcon app={focused.app} />
                  <span>
                    <span className="as-insp__app">{APPS[focused.app].label}</span>
                    <span className="as-insp__win" style={{ display: "block" }}>
                      {focused.title}
                    </span>
                  </span>
                </div>

                <dl className="as-kv">
                  <dt>Display</dt>
                  <dd>{DISPLAYS[focused.display].label}</dd>
                  <dt>Space</dt>
                  <dd>{focused.space}</dd>
                  <dt>Frame</dt>
                  <dd>{focused.origin} {focused.size}</dd>
                  <dt>Working dir</dt>
                  <dd>{focused.cwd}</dd>
                  <dt>tmux</dt>
                  <dd>{focused.tmux ?? "—"}</dd>
                  <dt>PID</dt>
                  <dd>{focused.pid}</dd>
                </dl>

                <div>
                  <Sec title="Move to" />
                  <div className="as-tilegrid">
                    {PLACEMENTS.map((spot) => (
                      <button
                        key={spot}
                        type="button"
                        title={spot}
                        aria-label={spot}
                        aria-pressed={placement === spot}
                        onClick={() => setPlacement(spot)}
                      />
                    ))}
                  </div>
                </div>

                <div className="as-insp__actions">
                  <Btn icon="focus">Focus</Btn>
                  <Btn icon="send">Send to space</Btn>
                </div>
              </div>
            </div>
          </div>

          <StatusBar
            items={[
              <>
                <span className="as-statusbar__ok">●</span> 38 windows · 2 displays · 4 spaces
              </>,
              "Screen text indexed 40s ago",
            ]}
            right={
              <>
                {selected.length} selected · <Kbd>⌘K</Kbd> to search
              </>
            }
          />
        </div>
      </div>
    </AppWindow>
  );
}
