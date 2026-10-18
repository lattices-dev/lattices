"use client";

import { useState } from "react";
import {
  AppWindow,
  Btn,
  Icon,
  Kbd,
  Rail,
  SESSIONS,
  Sec,
  StatusBar,
  Toolbar,
  type IconName,
} from "./_shell";

interface Result {
  id: string;
  group: string;
  icon: IconName;
  lead: string;
  tail?: string;
  ctx: string;
  preview: { cols: string; hot: 0 | 1 };
  facts: [string, string][];
}

const RESULTS: Result[] = [
  {
    id: "r1",
    group: "Windows",
    icon: "windows",
    lead: "Ghostty",
    tail: " — lattices, swift build",
    ctx: "Space 1",
    preview: { cols: "1.35fr 1fr", hot: 0 },
    facts: [
      ["Display", "Studio Display"],
      ["Space", "1 · Build"],
      ["cwd", "~/dev/lattices"],
    ],
  },
  {
    id: "r2",
    group: "Windows",
    icon: "windows",
    lead: "Chrome",
    tail: " — lattices.dev / Docs",
    ctx: "Space 1",
    preview: { cols: "1fr 1.35fr", hot: 1 },
    facts: [
      ["Display", "Studio Display"],
      ["Space", "1 · Build"],
      ["cwd", "—"],
    ],
  },
  {
    id: "r3",
    group: "Sessions",
    icon: "play",
    lead: "Start ",
    tail: "lattices",
    ctx: "~/dev/lattices",
    preview: { cols: "1fr 1fr", hot: 0 },
    facts: [
      ["Layout", "Dev three-up"],
      ["tmux", "lattices"],
      ["Panes", "4"],
    ],
  },
  {
    id: "r4",
    group: "Pages",
    icon: "studio",
    lead: "Studio",
    ctx: "⌘2",
    preview: { cols: "1.35fr 1fr", hot: 0 },
    facts: [
      ["Page", "Studio"],
      ["Layers", "3"],
      ["Shortcut", "⌘2"],
    ],
  },
  {
    id: "r5",
    group: "Commands",
    icon: "tileLeft",
    lead: "Tile front window left",
    ctx: "⌘⇧M",
    preview: { cols: "1fr 1fr", hot: 0 },
    facts: [
      ["Target", "Front window"],
      ["Placement", "left"],
      ["Shortcut", "⌘⇧M"],
    ],
  },
];

const GROUPS = [...new Set(RESULTS.map((r) => r.group))];

export function NavigatorPanel() {
  const [active, setActive] = useState("r1");
  const current = RESULTS.find((r) => r.id === active) ?? RESULTS[0];

  return (
    <AppWindow>
      <div className="as-body as-body--overlay">
        <Rail active="home" />

        <div className="as-content">
          <Toolbar title="Home">
            <Btn icon="scan">Scan screen</Btn>
            <Btn icon="play" primary>
              Start session
            </Btn>
            <Btn icon="search" trailing={<Kbd>⌘K</Kbd>}>
              Search
            </Btn>
          </Toolbar>

          <div className="as-scroll">
            <div className="as-pane as-home">
              <div>
                <Sec title="Sessions" count={3} />
                <div className="as-sessions">
                  {SESSIONS.map((session) => (
                    <span
                      key={session.name}
                      className={`as-session${session.running ? " as-session--on" : ""}`}
                    >
                      <span className="as-session__top">
                        <span className="as-session__name">{session.name}</span>
                        <span className="as-session__state">
                          <i />
                          {session.running ? "Running" : "Stopped"}
                        </span>
                      </span>
                      <span className="as-session__path">{session.path}</span>
                      <span className="as-session__facts">
                        {session.facts.map((fact) => (
                          <span key={fact}>{fact}</span>
                        ))}
                      </span>
                    </span>
                  ))}
                </div>
              </div>
              <aside className="as-aside" />
            </div>
          </div>

          <StatusBar
            items={[
              <>
                <span className="as-statusbar__ok">●</span> 2 sessions running
              </>,
            ]}
            right="Last scan 40s ago"
          />
        </div>

        <div className="as-dim" />

        <div className="as-palette">
          <div className="as-pal__input">
            <Icon name="command" />
            <span className="as-pal__scope">Everything</span>
            <span className="as-pal__q">lat</span>
            <span className="as-pal__caret" />
          </div>

          <div className="as-pal__body">
            <div className="as-pal__results">
              {GROUPS.map((group) => (
                <div key={group}>
                  <p className="as-pal__group">{group}</p>
                  {RESULTS.filter((r) => r.group === group).map((result) => (
                    <button
                      key={result.id}
                      type="button"
                      onMouseEnter={() => setActive(result.id)}
                      onFocus={() => setActive(result.id)}
                      onClick={() => setActive(result.id)}
                      className={`as-res${active === result.id ? " as-res--on" : ""}`}
                    >
                      <Icon name={result.icon} />
                      <span className="as-res__label">
                        <b>{result.lead}</b>
                        {result.tail}
                      </span>
                      <span className="as-res__ctx">{result.ctx}</span>
                    </button>
                  ))}
                </div>
              ))}
            </div>

            <div className="as-pal__preview">
              <div
                className="as-thumb"
                style={{ gridTemplateColumns: current.preview.cols }}
              >
                <i className={current.preview.hot === 0 ? "as-hot" : undefined} />
                <i className={current.preview.hot === 1 ? "as-hot" : undefined} />
              </div>
              <dl className="as-kv">
                {current.facts.map(([key, value]) => (
                  <div key={key} style={{ display: "contents" }}>
                    <dt>{key}</dt>
                    <dd>{value}</dd>
                  </div>
                ))}
              </dl>
            </div>
          </div>

          <div className="as-pal__foot">
            <span>
              <Kbd>↵</Kbd> Focus
            </span>
            <span>
              <Kbd>⇧↵</Kbd> Tile
            </span>
            <span>
              <Kbd>⇥</Kbd> Narrow scope
            </span>
            <span style={{ marginLeft: "auto" }}>
              <Kbd>esc</Kbd> Close
            </span>
          </div>
        </div>
      </div>
    </AppWindow>
  );
}
