/* Overview design studies — shell and shared renderers.
 * Builds the approved Lattices window around a study's Overview content. */
(function () {
  const LT = (window.LT = window.LT || {});

  /** Tiny DOM builder: h("div.cls#id", {attrs|on*}, ...children) */
  LT.h = function h(sel, attrs, ...kids) {
    const [tag, ...rest] = sel.split(/(?=[.#])/);
    const el = document.createElement(tag || "div");
    for (const r of rest) r[0] === "." ? el.classList.add(r.slice(1)) : (el.id = r.slice(1));
    if (attrs && (typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs))) { kids.unshift(attrs); attrs = null; }
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on")) el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
      else if (k === "html") el.innerHTML = v;
      else el.setAttribute(k, v === true ? "" : v);
    }
    const add = (k) => {
      if (k == null || k === false) return;
      if (Array.isArray(k)) return k.forEach(add);
      el.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
    };
    kids.forEach(add);
    return el;
  };
  const h = LT.h;

  // ---------- app glyphs: desaturated, told apart by monogram first ----------
  const GLYPH = {
    Zed: ["Zd", "#33404f"], Ghostty: ["Gh", "#2d3535"], Chrome: ["Ch", "#3f3b33"], Figma: ["Fg", "#40343d"],
    Slack: ["Sl", "#3a3342"], Linear: ["Ln", "#33354a"], Notes: ["Nt", "#454031"], Safari: ["Sf", "#2f3b47"],
    Keynote: ["Kn", "#3a3a3a"], Xcode: ["Xc", "#2f3a49"], Messages: ["Ms", "#2e3e33"], Music: ["Mu", "#47323a"],
    Preview: ["Pv", "#38383c"], Simulator: ["Sm", "#38383c"],
  };
  LT.glyph = (app) => {
    const [mono, g] = GLYPH[app] || [app.slice(0, 2), "#38383c"];
    return h("span.glyph", { style: { "--g": g } }, mono);
  };

  // ---------- icons (stroke, 15px) ----------
  const svg = (d, size = 15) =>
    `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  LT.ICON = {
    home: svg('<path d="M2.5 7.2 8 2.8l5.5 4.4V13a.6.6 0 0 1-.6.6H9.6V10H6.4v3.6H3.1a.6.6 0 0 1-.6-.6Z"/>'),
    overview: svg('<rect x="2" y="3" width="5" height="4.2" rx="1"/><rect x="9" y="3" width="5" height="10" rx="1"/><rect x="2" y="8.8" width="5" height="4.2" rx="1"/>'),
    assistant: svg('<path d="M3 4.5h10v6.2H8.2L5.4 13v-2.3H3z"/>'),
    runs: svg('<circle cx="8" cy="8" r="5.5"/><path d="m7 5.8 3 2.2-3 2.2z"/>'),
    activity: svg('<path d="M3 4h10M3 8h10M3 12h6"/>'),
    gear: svg('<circle cx="8" cy="8" r="2"/><path d="M8 1.8v1.6M8 12.6v1.6M14.2 8h-1.6M3.4 8H1.8M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7 3.6 3.6"/>'),
    search: svg('<circle cx="7" cy="7" r="4.2"/><path d="m10.2 10.2 3.3 3.3"/>', 13),
    focus: svg('<path d="M3 6V3h3M10 3h3v3M13 10v3h-3M6 13H3v-3"/>', 13),
    reveal: svg('<path d="M1.8 8s2.3-4.2 6.2-4.2S14.2 8 14.2 8s-2.3 4.2-6.2 4.2S1.8 8 1.8 8Z"/><circle cx="8" cy="8" r="1.8"/>', 13),
    move: svg('<path d="M3 8h9M9 5l3 3-3 3"/>', 13),
    tile: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2"/><path d="M8 2.5v11M8 8h6"/>', 13),
    distribute: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2"/><path d="M6 2.5v11M10 2.5v11"/>', 13),
    layer: svg('<path d="m8 2.5 5.5 3L8 8.5l-5.5-3z"/><path d="m2.5 8.5 5.5 3 5.5-3"/>', 13),
    pin: svg('<path d="M8 13.5V9.5M5 9.5h6l-1-2V3.5H6v4z"/>', 13),
    tuck: svg('<path d="M3 5h10M5 8h6M7 11h2"/>', 13),
    x: svg('<path d="m4.5 4.5 7 7M11.5 4.5l-7 7"/>', 12),
    chev: svg('<path d="m6 4 4 4-4 4"/>', 12),
    down: svg('<path d="m4 6 4 4 4-4"/>', 12),
    left: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2"/><rect x="2" y="2.5" width="6" height="11" rx="1.2" fill="currentColor" stroke="none" opacity=".55"/>', 13),
    right: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2"/><rect x="8" y="2.5" width="6" height="11" rx="1.2" fill="currentColor" stroke="none" opacity=".55"/>', 13),
    max: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2" fill="currentColor" fill-opacity=".45"/>', 13),
    center: svg('<rect x="2" y="2.5" width="12" height="11" rx="1.2"/><rect x="4.5" y="4.5" width="7" height="7" rx="1" fill="currentColor" stroke="none" opacity=".55"/>', 13),
  };
  LT.icon = (name) => h("span", { html: LT.ICON[name], style: { display: "inline-grid", placeItems: "center" } });

  const MARK = `<svg width="24" height="24" viewBox="0 0 24 24"><rect x="0.5" y="0.5" width="23" height="23" rx="6" fill="#16181a" stroke="rgba(255,255,255,.14)"/>
    <g fill="#33c773"><rect x="6" y="6" width="3" height="3" rx=".6"/><rect x="6" y="10.5" width="3" height="3" rx=".6"/><rect x="6" y="15" width="3" height="3" rx=".6"/><rect x="10.5" y="15" width="3" height="3" rx=".6"/><rect x="15" y="15" width="3" height="3" rx=".6" opacity=".55"/></g></svg>`;

  // ---------- monitor map renderer ----------
  /**
   * Draws one display at one Space. Live windows are filled; last-known
   * positions are dashed outlines. opts: { width, spaceId, labels: "full"|"tiny",
   * isOut(w), onSelect(w, ev), extra(w, el) }
   */
  LT.monitor = function monitor(m, display, opts = {}) {
    const width = opts.width || 480;
    const height = Math.round(width / display.aspect);
    const spaceId = opts.spaceId ?? display.current;
    const el = h("div.mon", { style: { width: width + "px", height: height + "px" } });
    const wins = m.windows.filter((w) => w.display === display.id && w.space === spaceId && w.frame);
    const order = [...wins.filter((w) => !m.isSelected(w.wid)), ...wins.filter((w) => m.isSelected(w.wid))];
    for (const w of order) {
      const [x, y, ww, hh] = w.frame;
      const px = { left: x * width, top: y * height, width: ww * width, height: hh * height };
      const tiny = opts.labels === "tiny" || px.width < 90 || px.height < 40;
      const node = h(
        "div.w",
        {
          "data-wid": w.wid,
          title: `${w.app} — ${w.title}`,
          style: { left: px.left + 1 + "px", top: px.top + 1 + "px", width: px.width - 2 + "px", height: px.height - 2 + "px" },
          onClick: (ev) => { ev.stopPropagation(); opts.onSelect ? opts.onSelect(w, ev) : m.select(w.wid, { toggle: ev.metaKey || ev.shiftKey }); },
          onDblclick: (ev) => { ev.stopPropagation(); m.focus(w.wid); },
        },
        h("div.t1", LT.glyph(w.app), tiny ? null : h("span", w.app), !tiny && w.pos === "lastKnown" ? h("span.muted", { style: { fontWeight: 500, fontSize: "10px" } }, "· last known") : null),
        h("div.t2", w.title)
      );
      if (w.pos !== "live") node.classList.add("ghost");
      if (tiny) node.classList.add("tiny");
      if (opts.isOut && opts.isOut(w)) node.classList.add("out");
      if (m.isSelected(w.wid)) node.classList.add("sel");
      if (opts.extra) opts.extra(w, node);
      el.appendChild(node);
    }
    return el;
  };

  // ---------- shell ----------
  LT.mountShell = function mountShell(cfg) {
    const m = cfg.model;
    const embedded = new URLSearchParams(location.search).has("embed");
    if (embedded) document.body.classList.add("embedded");

    const seg = h("div.seg");
    const bar = h(
      "div.study-bar",
      h("span.tag", "Design study"),
      h("span.name", `${cfg.letter} · ${cfg.name}`),
      h("span", cfg.blurb),
      h("span.spacer"),
      h("span.muted", "Demo state"),
      seg,
      h("button.reset", { onClick: () => m.setDemo(m.demoState) }, "Reset")
    );

    const navItem = (icon, label, active) =>
      h("div.item" + (active ? ".active" : ""), h("span.ico", { html: LT.ICON[icon] }), h("span.lbl", label));

    const sidebar = h(
      "aside.sidebar",
      h("div.brand", h("div.row", h("span.mark", { html: MARK }), h("span.word", "Lattices"))),
      h(
        "nav",
        h("div.section", "Workspace"),
        navItem("home", "Home"),
        navItem("overview", "Overview", true),
        h("div.section", "Agents"),
        navItem("assistant", "Assistant"),
        navItem("runs", "Runs"),
        h("div.section", "System"),
        navItem("activity", "Activity")
      ),
      h(
        "div.foot",
        h("div.item", h("span.ico", h("span.dot")), h("span.lbl", "Daemon"), h("span.port", ":9399")),
        navItem("gear", "Settings")
      )
    );

    const actions = h("div", { style: { display: "flex", gap: "8px", alignItems: "center" } });
    const titlebar = h(
      "header.titlebar",
      h("h1", "Overview"),
      h("span.grow"),
      actions,
      h("button.pa", { onClick: () => m.say("Search opens the command bar (⌘K) — not part of this study", "info") }, LT.icon("search"), "Search", h("kbd", "⌘K"))
    );
    const content = h("div.content");
    const toast = h("div.toast");
    const status = h("footer.statusbar");
    const stage = h("main.stage", titlebar, content, status, toast);
    const win = h("div.win", h("div.backdrop"), h("div.traffic", h("i"), h("i"), h("i")), sidebar, stage);

    document.body.append(bar, win);

    let toastTimer, lastToast = 0;
    const render = () => {
      seg.replaceChildren(
        ...m.DEMO_STATES.map((s) => h("button", { "aria-pressed": String(m.demoState === s.id), onClick: () => m.setDemo(s.id) }, s.label))
      );
      actions.replaceChildren(...(cfg.pageActions ? cfg.pageActions(m) : []));
      const keep = [...content.querySelectorAll("[data-keep]")].map((n) => [n.dataset.keep, n.scrollTop, n.scrollLeft]);
      content.replaceChildren(cfg.render(m));
      for (const [k, t, l] of keep) {
        const n = content.querySelector(`[data-keep="${k}"]`);
        if (n) { n.scrollTop = t; n.scrollLeft = l; }
      }
      const spaces = m.displays.reduce((n, d) => n + d.spaces.filter((s) => !s.fullScreen).length, 0);
      status.replaceChildren(
        h("span", h("span.dot"), "0 sessions running"),
        h("span", `${m.windows.length} windows · ${m.displays.length} displays · ${spaces} spaces`),
        h("span", { style: { flex: 1 } }),
        h("span", "Demo data · nothing on this desktop moves"),
        h("span", "Screen text off")
      );
      if (m.toast && m.toast.id !== lastToast) {
        lastToast = m.toast.id;
        toast.className = "toast show " + m.toast.kind;
        toast.replaceChildren(h("b", m.toast.kind === "blocked" ? "NOT AVAILABLE" : m.toast.kind === "info" ? "SCOPE" : "DEMO"), h("span", m.toast.text));
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => toast.classList.remove("show"), 3600);
      }
    };
    m.subscribe(render);
    m.setDemo(new URLSearchParams(location.search).get("state") || "selected");

    // Keys shared with the real Overview: t tile, d distribute, / search, x deselect, Esc.
    document.addEventListener("keydown", (e) => {
      if (e.target.closest("input, textarea")) return;
      if (e.key === "t") m.runBulk("Tile");
      else if (e.key === "d") m.runBulk("Distribute");
      else if (e.key === "x" || e.key === "Escape") m.clearSelection();
      else if (e.key === "Enter" && m.primary()) m.focus(m.primary().wid);
      else if (e.key === "/") { const s = content.querySelector("input[type=search]"); if (s) { e.preventDefault(); s.focus(); } }
      else if (cfg.onKey) cfg.onKey(e, m);
    });
    return { model: m, content };
  };

  /** A search field that survives re-renders (focus + caret kept). */
  LT.searchField = function searchField(m, placeholder) {
    const input = h("input", { type: "search", placeholder, value: m.scope.search, spellcheck: "false", "data-search": "1" });
    input.addEventListener("input", () => {
      const pos = input.selectionStart;
      m.scope.search = input.value;
      m.emit();
      const again = document.querySelector('input[data-search="1"]');
      if (again) { again.focus(); again.setSelectionRange(pos, pos); }
    });
    return input;
  };
})();
