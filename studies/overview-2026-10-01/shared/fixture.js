/* Overview design studies — shared fixture.
 *
 * One invented, internally consistent desk ("tideline", a tide-forecast
 * project), used unchanged by every study so they compare fairly. Frames are
 * fractions of each display's visible area: [x, y, w, h].
 *
 * States mirror OverviewProjection:
 *   showing    — on the display's current Space, live position
 *   otherSpace — on another Desktop of that display (position is last known)
 *   fullScreen — its own full-screen Space
 *   appHidden  — app hidden (⌘H)
 *   unknown    — minimized or closed; no position
 */
(function () {
  const LT = (window.LT = window.LT || {});

  LT.FIXTURE = {
    displays: [
      {
        id: 1,
        name: "Studio Display",
        short: "Studio",
        size: "2560 × 1440",
        aspect: 2560 / 1440,
        spaces: [
          { id: 11, n: 1 },
          { id: 12, n: 2 },
          { id: 13, n: 3 },
          { id: 14, n: 4, fullScreen: "Keynote" },
        ],
        current: 11,
      },
      {
        id: 2,
        name: "MacBook Pro",
        short: "MacBook",
        size: "1512 × 982",
        aspect: 1512 / 982,
        spaces: [{ id: 21, n: 1 }],
        current: 21,
      },
    ],

    windows: [
      // Studio Display — Desktop 1 (current)
      { wid: 101, app: "Zed", kind: "editor", title: "tideline — src/forecast/harmonics.rs", display: 1, space: 11, state: "showing", pos: "live", frame: [0, 0, 0.5, 1] },
      { wid: 102, app: "Ghostty", kind: "terminal", title: "tideline · bun dev", display: 1, space: 11, state: "showing", pos: "live", frame: [0.5, 0, 0.5, 0.5] },
      { wid: 103, app: "Ghostty", kind: "terminal", title: "tideline · cargo test --watch", display: 1, space: 11, state: "showing", pos: "live", frame: [0.5, 0.5, 0.25, 0.5] },
      { wid: 104, app: "Chrome", kind: "browser", title: "localhost:5173 — Tideline", display: 1, space: 11, state: "showing", pos: "live", frame: [0.75, 0.5, 0.25, 0.5] },
      { wid: 105, app: "Figma", kind: "design", title: "Tideline — Chart system", display: 1, space: 11, state: "showing", pos: "live", frame: [0.18, 0.12, 0.46, 0.7] },

      // Studio Display — Desktop 2
      { wid: 201, app: "Slack", kind: "chat", title: "#tideline-dev", display: 1, space: 12, state: "otherSpace", pos: "lastKnown", frame: [0, 0, 0.34, 1] },
      { wid: 202, app: "Linear", kind: "planning", title: "TID-142 · Offset drift near slack water", display: 1, space: 12, state: "otherSpace", pos: "lastKnown", frame: [0.34, 0, 0.33, 1] },
      { wid: 203, app: "Chrome", kind: "browser", title: "Grafana — buoy ingest", display: 1, space: 12, state: "otherSpace", pos: "lastKnown", frame: [0.67, 0, 0.33, 1] },

      // Studio Display — Desktop 3
      { wid: 301, app: "Notes", kind: "notes", title: "Release notes 0.9", display: 1, space: 13, state: "otherSpace", pos: "lastKnown", frame: [0.08, 0.1, 0.4, 0.8] },
      { wid: 302, app: "Safari", kind: "browser", title: "NOAA CO-OPS API reference", display: 1, space: 13, state: "otherSpace", pos: "lastKnown", frame: [0.5, 0.06, 0.46, 0.88] },

      // Studio Display — full-screen Space
      { wid: 401, app: "Keynote", kind: "doc", title: "Tideline — field trial review", display: 1, space: 14, state: "fullScreen", pos: "lastKnown", frame: [0, 0, 1, 1] },

      // MacBook Pro — Desktop 1 (current)
      { wid: 501, app: "Xcode", kind: "editor", title: "TidelineKit — Buoy.swift", display: 2, space: 21, state: "showing", pos: "live", frame: [0, 0, 0.62, 1] },
      { wid: 502, app: "Ghostty", kind: "terminal", title: "~ scratch", display: 2, space: 21, state: "showing", pos: "live", frame: [0.62, 0, 0.38, 0.55] },
      { wid: 503, app: "Messages", kind: "chat", title: "Mara", display: 2, space: 21, state: "showing", pos: "live", frame: [0.62, 0.55, 0.38, 0.45] },

      // Not on any visible Space
      { wid: 601, app: "Music", kind: "media", title: "Music", display: 1, space: null, state: "appHidden", pos: "lastKnown", frame: [0.3, 0.2, 0.4, 0.6] },
      { wid: 602, app: "Preview", kind: "doc", title: "tide-chart-export.pdf", display: 2, space: null, state: "unknown", pos: "none", frame: null },
    ],

    /* Layers: a layer is configuration. Entries match windows by pin (one
     * window) or rule (app + title). An entry can match nothing ("No window").
     * Tucked windows stay claimed by the layer but are left out of arranging.
     * `active` means the layer is the live workspace layer, which gates
     * Save & arrange. */
    layers: [
      {
        id: "tideline",
        name: "tideline",
        home: { display: 1, space: 11 },
        active: true,
        entries: [
          { id: "e1", app: "Zed", match: "title ∋ tideline", via: "rule", wid: 101 },
          { id: "e2", app: "Ghostty", match: "bun dev", via: "pin", wid: 102 },
          { id: "e3", app: "Ghostty", match: "title ∋ tideline", via: "rule", wid: 103 },
          { id: "e4", app: "Chrome", match: "localhost:5173", via: "rule", wid: 104 },
          { id: "e5", app: "Xcode", match: "TidelineKit", via: "rule", wid: 501 },
          { id: "e6", app: "Simulator", match: "app", via: "rule", wid: null },
        ],
        tucked: [501],
        homes: { 101: [0, 0, 0.5, 1], 102: [0.5, 0, 0.5, 0.5], 103: [0.5, 0.5, 0.25, 0.5], 104: [0.75, 0.5, 0.25, 0.5] },
      },
      {
        id: "ops",
        name: "ops",
        home: { display: 1, space: 12 },
        active: false,
        entries: [
          { id: "o1", app: "Slack", match: "app", via: "rule", wid: 201 },
          { id: "o2", app: "Linear", match: "app", via: "rule", wid: 202 },
          { id: "o3", app: "Chrome", match: "Grafana", via: "pin", wid: 203 },
        ],
        tucked: [],
        homes: {},
      },
      {
        id: "writing",
        name: "writing",
        home: { display: 1, space: 13 },
        active: false,
        entries: [
          { id: "w1", app: "Notes", match: "app", via: "rule", wid: 301 },
          { id: "w2", app: "Safari", match: "NOAA", via: "pin", wid: 302 },
          { id: "w3", app: "Keynote", match: "Tideline", via: "rule", wid: 401 },
        ],
        tucked: [],
        homes: {},
      },
    ],

    kinds: [
      { id: "all", label: "All" },
      { id: "terminal", label: "Terminals" },
      { id: "editor", label: "Editors" },
      { id: "browser", label: "Browsers" },
    ],
  };
})();
