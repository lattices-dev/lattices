"use client";

import { useState } from "react";
import {
  AppWindow,
  Btn,
  ColHead,
  Kbd,
  LAYOUTS,
  Rail,
  SESSIONS,
  Sec,
  StatusBar,
  Toolbar,
  WindowRow,
  WINDOWS,
} from "./_shell";

const SHORTCUTS = [
  { key: "⌘K", label: "Find anything" },
  { key: "⌘⇧M", label: "Tile front window" },
  { key: "⌃←→", label: "Switch space" },
  { key: "?", label: "All shortcuts" },
];

export function HomePanel() {
  const [selected, setSelected] = useState("w1");
  const rows = WINDOWS.slice(0, 6);

  return (
    <AppWindow>
      <div className="as-body">
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
                <Sec title="Sessions" count={SESSIONS.length} action="Manage" />
                <div className="as-sessions">
                  {SESSIONS.map((session) => (
                    <button
                      type="button"
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
                          <span key={fact} className={session.running ? undefined : "as-off"}>
                            {fact}
                          </span>
                        ))}
                      </span>
                    </button>
                  ))}
                </div>

                <div style={{ marginTop: 24 }}>
                  <Sec title="Active windows" count={38} action="Open in Windows" />
                  <div className="as-table">
                    <ColHead />
                    {rows.map((win, i) => (
                      <WindowRow
                        key={win.id}
                        win={win}
                        selected={selected === win.id}
                        trailing={i === 1 ? "actions" : "when"}
                        onSelect={() => setSelected(win.id)}
                      />
                    ))}
                  </div>
                </div>
              </div>

              <aside className="as-aside">
                <div>
                  <Sec title="Layouts" />
                  {LAYOUTS.map((layout) => (
                    <button type="button" key={layout.name} className="as-layout">
                      <span
                        className="as-glyph"
                        style={{ gridTemplateColumns: layout.cells === 2 ? "1.4fr 1fr" : `repeat(${layout.cells}, 1fr)` }}
                      >
                        {Array.from({ length: layout.cells }, (_, i) => (
                          <i key={i} />
                        ))}
                      </span>
                      <span className="as-layout__name">{layout.name}</span>
                      <span className="as-layout__key">{layout.key}</span>
                    </button>
                  ))}
                </div>

                <div>
                  <Sec title="Shortcuts" />
                  <div className="as-tips">
                    {SHORTCUTS.map((shortcut) => (
                      <div className="as-tip" key={shortcut.key}>
                        <Kbd>{shortcut.key}</Kbd>
                        {shortcut.label}
                      </div>
                    ))}
                  </div>
                </div>
              </aside>
            </div>
          </div>

          <StatusBar
            items={[
              <>
                <span className="as-statusbar__ok">●</span> 2 sessions running
              </>,
              "38 windows · 2 displays · 4 spaces",
            ]}
            right="Last scan 40s ago"
          />
        </div>
      </div>
    </AppWindow>
  );
}
