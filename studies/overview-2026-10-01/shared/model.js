/* Overview design studies — in-memory model.
 *
 * A small stand-in for OverviewModel + OverviewProjection, so every study
 * shares the same semantics:
 *   - scope (monitor, Space, layer, search, kind) is independent of selection;
 *   - a selected window can sit outside the scope and be revealed;
 *   - only windows that are in scope, on their display's current Space and at a
 *     live position are eligible for Tile / Distribute / Place / Move;
 *   - editing a layer is a draft (configuration) and is separate from
 *     arranging windows; Save & arrange is offered only while the layer is active.
 *
 * Nothing here touches the desktop. Every action changes demo state and
 * reports what the app would have done.
 */
(function () {
  const LT = (window.LT = window.LT || {});
  const clone = (v) => JSON.parse(JSON.stringify(v));

  const PLACE = {
    left: { label: "Left", frame: [0, 0, 0.5, 1] },
    right: { label: "Right", frame: [0.5, 0, 0.5, 1] },
    max: { label: "Max", frame: [0, 0, 1, 1] },
    center: { label: "Center", frame: [0.17, 0.1, 0.66, 0.8] },
  };
  LT.PLACE = PLACE;

  const EXCLUSION_LABEL = {
    otherSpace: (w, m) => `on Desktop ${m.spaceNumber(w.space)}`,
    fullScreen: () => "full screen",
    appHidden: () => "app hidden",
    unknown: () => "minimized or closed",
    tucked: () => "tucked",
    outsideMonitor: () => "on another monitor",
    outsideSpace: () => "on another Space",
    outsideLayer: () => "outside the layer",
    search: () => "hidden by search",
    kind: () => "hidden by filter",
  };

  LT.createModel = function createModel() {
    const fx = clone(LT.FIXTURE);
    const m = {
      displays: fx.displays,
      windows: fx.windows,
      layers: fx.layers,
      kinds: fx.kinds,
      scope: { display: null, spaceId: null, layerId: "tideline", search: "", kind: "all" },
      selection: [101],
      draft: null,
      toast: null,
      listeners: [],
      toastSeq: 0,
    };

    // ---------- lookup ----------
    m.win = (wid) => m.windows.find((w) => w.wid === wid);
    m.display = (id) => m.displays.find((d) => d.id === id);
    m.layer = (id) => m.layers.find((l) => l.id === id);
    m.spaceOf = (id) => {
      for (const d of m.displays) for (const s of d.spaces) if (s.id === id) return { display: d, space: s };
      return null;
    };
    m.spaceNumber = (id) => (m.spaceOf(id) || { space: { n: "?" } }).space.n;
    m.primary = () => (m.selection.length ? m.win(m.selection[m.selection.length - 1]) : null);
    m.isSelected = (wid) => m.selection.includes(wid);

    // ---------- layer roles (draft-aware) ----------
    m.layerView = (id) => {
      if (m.draft && m.draft.layerId === id) return m.draft;
      const l = m.layer(id);
      return l ? { layerId: l.id, entries: l.entries, tucked: l.tucked } : null;
    };
    m.roleIn = (w, layerId) => {
      const v = m.layerView(layerId);
      const l = m.layer(layerId);
      if (!v || !l) return null;
      const entry = v.entries.find((e) => e.wid === w.wid);
      if (entry && v.tucked.includes(w.wid)) return { role: "tucked", entry };
      if (entry) return { role: "member", entry };
      if (w.space === l.home.space) return { role: "unclaimed" };
      return null;
    };
    m.layersOf = (w) =>
      m.layers.filter((l) => {
        const r = m.roleIn(w, l.id);
        return r && r.role !== "unclaimed";
      });

    // ---------- scope ----------
    m.scopeExclusion = (w) => {
      const s = m.scope;
      if (s.display != null && w.display !== s.display) return "outsideMonitor";
      if (s.spaceId != null && w.space !== s.spaceId) return "outsideSpace";
      if (s.layerId && !m.roleIn(w, s.layerId)) return "outsideLayer";
      if (s.search) {
        const q = s.search.toLowerCase();
        if (!(w.title + " " + w.app).toLowerCase().includes(q)) return "search";
      }
      if (s.kind !== "all" && w.kind !== s.kind) return "kind";
      return null;
    };
    m.stateExclusion = (w) => {
      if (w.state !== "showing") return w.state;
      if (m.scope.layerId) {
        const r = m.roleIn(w, m.scope.layerId);
        if (r && r.role === "tucked") return "tucked";
      }
      return null;
    };
    m.inScope = (w) => !m.scopeExclusion(w);
    m.isLive = (w) => w.state === "showing" && w.pos === "live";
    m.eligible = (w) => m.inScope(w) && !m.stateExclusion(w);
    m.exclusionLabel = (key, w) => (EXCLUSION_LABEL[key] ? EXCLUSION_LABEL[key](w, m) : key);

    m.stateLabel = (w) => {
      switch (w.state) {
        case "showing": return "Showing";
        case "otherSpace": return `Desktop ${m.spaceNumber(w.space)}`;
        case "fullScreen": return "Full screen";
        case "appHidden": return "App hidden";
        default: return "Minimized or closed";
      }
    };
    m.positionLabel = (w) => (w.pos === "lastKnown" ? "Last known" : w.pos === "none" ? "No position" : null);
    m.whereLabel = (w) => {
      const d = m.display(w.display);
      if (w.space == null) return `${d.short} · ${m.stateLabel(w)}`;
      const s = m.spaceOf(w.space).space;
      return s.fullScreen ? `${d.short} · Full-screen Space` : `${d.short} · Desktop ${s.n}`;
    };

    m.inScopeWindows = () => m.windows.filter(m.inScope);
    m.counts = () => {
      const inScope = m.inScopeWindows();
      return {
        inScope: inScope.length,
        eligible: inScope.filter((w) => !m.stateExclusion(w)).length,
        elsewhere: m.windows.length - inScope.length,
      };
    };

    /** The bulk plan: eligible windows grouped by display, plus what was left out and why. */
    m.plan = (verb) => {
      const groups = m.displays
        .map((d) => ({ display: d, windows: m.windows.filter((w) => w.display === d.id && m.eligible(w)) }))
        .filter((g) => g.windows.length);
      const excluded = {};
      for (const w of m.inScopeWindows()) {
        const key = m.stateExclusion(w);
        if (!key) continue;
        const label = m.exclusionLabel(key, w);
        excluded[label] = (excluded[label] || 0) + 1;
      }
      const count = groups.reduce((n, g) => n + g.windows.length, 0);
      const excludedText = Object.entries(excluded).map(([k, n]) => `${n} ${k}`).join(" · ");
      return { verb, groups, count, excluded, excludedText, enabled: count > 0 };
    };

    /** Why a single-window action is or isn't available. Returns null when allowed. */
    m.blocker = (w, action) => {
      if (!w) return "Nothing selected";
      if (action === "focus") {
        if (w.state === "unknown") return "Minimized or closed — nothing to focus";
        return null;
      }
      // place / move
      if (w.state === "otherSpace") return `On Desktop ${m.spaceNumber(w.space)} — focus it first; its position is last known`;
      if (w.state === "fullScreen") return "Full screen — exit full screen to place it";
      if (w.state === "appHidden") return "App hidden — focus to show it first";
      if (w.state === "unknown") return "Minimized or closed";
      if (w.pos !== "live") return "Position is not live";
      return null;
    };
    m.focusNote = (w) => {
      if (!w) return "";
      if (w.state === "otherSpace") return `Switches ${m.display(w.display).short} to Desktop ${m.spaceNumber(w.space)}`;
      if (w.state === "fullScreen") return "Switches to its full-screen Space";
      if (w.state === "appHidden") return `Unhides ${w.app}`;
      return "Raises and focuses";
    };

    // ---------- change plumbing ----------
    m.subscribe = (fn) => m.listeners.push(fn);
    m.emit = () => m.listeners.forEach((fn) => fn(m));
    m.say = (text, kind = "demo") => {
      m.toast = { text, kind, id: ++m.toastSeq };
      m.emit();
    };

    // ---------- selection ----------
    m.select = (wid, opts = {}) => {
      if (opts.toggle) {
        m.selection = m.isSelected(wid) ? m.selection.filter((x) => x !== wid) : [...m.selection, wid];
      } else {
        m.selection = [wid];
      }
      m.emit();
    };
    m.clearSelection = () => { m.selection = []; m.emit(); };

    m.setScope = (patch) => { Object.assign(m.scope, patch); if (patch.display !== undefined && patch.spaceId === undefined) m.scope.spaceId = null; m.emit(); };

    /** Show in scope: widen the scope just enough to include the window. */
    m.reveal = (wid) => {
      const w = m.win(wid);
      if (!w) return;
      const s = m.scope;
      const changed = [];
      if (s.display != null && w.display !== s.display) { s.display = w.display; changed.push(m.display(w.display).short); }
      if (s.spaceId != null && w.space !== s.spaceId) { s.spaceId = null; changed.push("all Spaces"); }
      if (s.layerId && !m.roleIn(w, s.layerId)) { s.layerId = null; changed.push("no layer"); }
      if (s.search && m.scopeExclusion(w) === "search") { s.search = ""; changed.push("search cleared"); }
      if (s.kind !== "all" && w.kind !== s.kind) { s.kind = "all"; changed.push("all kinds"); }
      m.selection = [wid];
      m.say(changed.length ? `Scope widened to show ${w.app}: ${changed.join(", ")}` : `${w.app} is already in scope`, "info");
    };

    // ---------- desktop actions (simulated) ----------
    const switchSpace = (display, spaceId) => {
      display.current = spaceId;
      for (const w of m.windows) {
        if (w.display !== display.id || w.space == null) continue;
        if (w.space === spaceId) { w.state = m.spaceOf(spaceId).space.fullScreen ? "fullScreen" : "showing"; w.pos = "live"; }
        else if (w.state === "showing" || w.state === "fullScreen") { w.state = m.spaceOf(w.space).space.fullScreen ? "fullScreen" : "otherSpace"; w.pos = "lastKnown"; }
      }
    };

    m.focus = (wid) => {
      const w = m.win(wid);
      const why = m.blocker(w, "focus");
      if (why) return m.say(why, "blocked");
      const d = m.display(w.display);
      const note = m.focusNote(w);
      if (w.state === "otherSpace" || w.state === "fullScreen") switchSpace(d, w.space);
      if (w.state === "appHidden") { w.state = "showing"; w.pos = "live"; w.space = d.current; }
      m.selection = [wid];
      m.say(note === "Raises and focuses" ? `Would focus ${w.app} — ${w.title}` : `Would focus ${w.app}. ${note}.`);
    };

    m.place = (wid, key) => {
      const w = m.win(wid);
      const why = m.blocker(w, "place");
      if (why) return m.say(why, "blocked");
      w.frame = PLACE[key].frame.slice();
      m.say(`Would place ${w.app} ${PLACE[key].label.toLowerCase()} on ${m.display(w.display).name}`);
    };

    m.moveToSpace = (wid, spaceId) => {
      const w = m.win(wid);
      const why = m.blocker(w, "move");
      if (why) return m.say(why, "blocked");
      if (w.space === spaceId) return m.say(`${w.app} is already on Desktop ${m.spaceNumber(spaceId)}`, "info");
      w.space = spaceId;
      w.state = "otherSpace";
      w.pos = "lastKnown";
      m.say(`Would move ${w.app} to Desktop ${m.spaceNumber(spaceId)} on ${m.display(w.display).short}`);
    };

    const tileFrames = (n) => {
      if (n === 1) return [[0, 0, 1, 1]];
      if (n === 2) return [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]];
      if (n === 3) return [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]];
      if (n === 4) return [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]];
      const top = Math.ceil(n / 2), bottom = n - top, out = [];
      for (let i = 0; i < top; i++) out.push([i / top, 0, 1 / top, 0.5]);
      for (let i = 0; i < bottom; i++) out.push([i / bottom, 0.5, 1 / bottom, 0.5]);
      return out;
    };
    const rowFrames = (n) => Array.from({ length: n }, (_, i) => [i / n, 0, 1 / n, 1]);

    m.runBulk = (verb) => {
      const plan = m.plan(verb);
      if (!plan.enabled) return m.say(`${verb}: nothing eligible in this scope${plan.excludedText ? " — " + plan.excludedText : ""}`, "blocked");
      for (const g of plan.groups) {
        const frames = verb === "Tile" ? tileFrames(g.windows.length) : rowFrames(g.windows.length);
        g.windows.forEach((w, i) => (w.frame = frames[i]));
      }
      const where = plan.groups.map((g) => `${g.windows.length} on ${g.display.short}`).join(", ");
      m.say(`Would ${verb.toLowerCase()} ${where}${plan.excludedText ? ". Left out: " + plan.excludedText : ""}`);
    };

    // ---------- layer editing (configuration, not arranging) ----------
    m.beginEdit = (layerId) => {
      const l = m.layer(layerId);
      m.draft = { layerId, entries: clone(l.entries), tucked: l.tucked.slice(), changes: [] };
      m.emit();
    };
    const note = (text) => { m.draft.changes.push(text); m.emit(); };
    m.draftPin = (wid) => {
      const w = m.win(wid);
      if (!m.draft || m.draft.entries.some((e) => e.wid === wid)) return;
      m.draft.entries.push({ id: "d" + wid, app: w.app, match: w.title, via: "pin", wid });
      note(`Pin ${w.app}`);
    };
    m.draftRemove = (wid) => {
      const w = m.win(wid);
      m.draft.entries = m.draft.entries.filter((e) => e.wid !== wid);
      m.draft.tucked = m.draft.tucked.filter((x) => x !== wid);
      note(`Remove ${w.app}`);
    };
    m.draftTuck = (wid) => {
      const w = m.win(wid);
      const t = m.draft.tucked.includes(wid);
      m.draft.tucked = t ? m.draft.tucked.filter((x) => x !== wid) : [...m.draft.tucked, wid];
      note(`${t ? "Untuck" : "Tuck"} ${w.app}`);
    };
    m.cancelEdit = () => { m.draft = null; m.say("Draft discarded — layer unchanged", "info"); };
    m.saveEdit = (arrange) => {
      const d = m.draft, l = m.layer(d.layerId);
      if (arrange && !l.active) return m.say(`${l.name} is not active — Save only; arranging needs the live layer`, "blocked");
      l.entries = d.entries; l.tucked = d.tucked;
      const n = d.changes.length;
      m.draft = null;
      if (arrange) {
        const members = m.windows.filter((w) => { const r = m.roleIn(w, l.id); return r && r.role === "member" && m.isLive(w); });
        const frames = tileFrames(members.length);
        members.forEach((w, i) => (w.frame = (l.homes[w.wid] || frames[i]).slice()));
        m.say(`Would save ${l.name} (${n} change${n === 1 ? "" : "s"}) and arrange ${members.length} live members`);
      } else {
        m.say(`Would save ${l.name} (${n} change${n === 1 ? "" : "s"}). No windows moved.`);
      }
    };

    // ---------- demo states (shared by every study) ----------
    m.reset = () => {
      const fresh = clone(LT.FIXTURE);
      m.displays = fresh.displays; m.windows = fresh.windows; m.layers = fresh.layers;
      m.scope = { display: null, spaceId: null, layerId: "tideline", search: "", kind: "all" };
      m.selection = [101]; m.draft = null; m.toast = null;
    };
    m.DEMO_STATES = [
      { id: "selected", label: "Selected" },
      { id: "outside", label: "Out of scope" },
      { id: "empty", label: "Empty scope" },
      { id: "editing", label: "Editing layer" },
    ];
    m.demoState = "selected";
    m.setDemo = (id) => {
      m.reset();
      m.demoState = id;
      if (id === "outside") { m.selection = [202]; }
      if (id === "empty") { m.scope = { display: 1, spaceId: 13, layerId: null, search: "", kind: "terminal" }; m.selection = [102]; }
      if (id === "editing") { m.beginEdit("tideline"); m.draftPin(105); m.selection = [105]; }
      m.emit();
    };

    return m;
  };
})();
