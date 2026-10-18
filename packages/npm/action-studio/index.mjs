const DEFAULT_DEFINITION = Object.freeze({
  schemaVersion: 1,
  id: "review-release",
  name: "Review release",
  status: "draft",
  instruction: "When I say ‘review the release,’ open the latest release page, put my code beside it, and keep the logs visible.",
  triggers: ["Review the release"],
  outcomes: [
    { id: "release-page", label: "Release page", target: "Open latest release", placement: "left" },
    { id: "code", label: "Code", target: "Current code window", placement: "upper-right" },
    { id: "logs", label: "Logs", target: "Current terminal logs", placement: "lower-right" }
  ],
  behavior: {
    reuseOpenWindows: true,
    preserveUnsavedWork: true,
    ambiguity: "ask"
  }
});

const DEFAULT_CAPABILITIES = Object.freeze({
  placements: [
    "left", "right", "upper-left", "upper-right", "lower-left",
    "lower-right", "center", "maximize", "keep-visible"
  ],
  canPlan: true,
  canTest: true,
  canSave: true
});

/* The nine placements laid out as the screen actually reads: a 3x3 grid.
   Row/column position in this table is the drop target for that placement. */
const PLACEMENT_GRID = [
  ["upper-left", "maximize", "upper-right"],
  ["left", "center", "right"],
  ["lower-left", "keep-visible", "lower-right"]
];

/* Where each placement is drawn, as a percentage frame of the screen. A
   window block occupies the frame it will really take, so the arrangement is
   read off the picture instead of off a dropdown. */
const PLACEMENT_FRAME = {
  "left": { x: 0, y: 0, w: 50, h: 100 },
  "right": { x: 50, y: 0, w: 50, h: 100 },
  "upper-left": { x: 0, y: 0, w: 50, h: 50 },
  "upper-right": { x: 50, y: 0, w: 50, h: 50 },
  "lower-left": { x: 0, y: 50, w: 50, h: 50 },
  "lower-right": { x: 50, y: 50, w: 50, h: 50 },
  "center": { x: 14, y: 11, w: 72, h: 78 },
  "maximize": { x: 0, y: 0, w: 100, h: 100 },
  "keep-visible": { x: 64, y: 60, w: 34, h: 37 }
};

function clone(value) {
  return structuredClone(value);
}

export function normalizeDefinition(input = {}) {
  const fallback = clone(DEFAULT_DEFINITION);
  const outcomes = Array.isArray(input.outcomes)
    ? input.outcomes.filter((outcome) => outcome && outcome.id && outcome.label)
    : fallback.outcomes;

  return {
    schemaVersion: 1,
    id: String(input.id || fallback.id).trim(),
    name: String(input.name || fallback.name).trim(),
    status: input.status === "saved" ? "saved" : "draft",
    instruction: String(input.instruction || fallback.instruction).trim(),
    triggers: Array.isArray(input.triggers)
      ? input.triggers.map((trigger) => String(trigger).trim()).filter(Boolean)
      : fallback.triggers,
    outcomes: outcomes.map((outcome) => ({ ...outcome })),
    behavior: { ...fallback.behavior, ...(input.behavior || {}) }
  };
}

function displayPlacement(value) {
  return value.split("-").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
}

function gridPosition(placement) {
  for (let row = 0; row < 3; row += 1) {
    const column = PLACEMENT_GRID[row].indexOf(placement);
    if (column !== -1) return { column, row };
  }
  return { column: 1, row: 1 };
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function nextID() {
  return "step-" + Math.random().toString(36).slice(2, 9);
}

let assetsPromise;

async function loadAssets() {
  if (!assetsPromise) {
    const htmlURL = new URL("./editor.html", import.meta.url);
    const cssURL = new URL("./action-studio.css", import.meta.url);
    assetsPromise = Promise.all([
      fetch(htmlURL).then((response) => {
        if (!response.ok) throw new Error("Unable to load Action Studio template");
        return response.text();
      }),
      fetch(cssURL).then((response) => {
        if (!response.ok) throw new Error("Unable to load Action Studio stylesheet");
        return response.text();
      })
    ]);
  }
  return assetsPromise;
}

export class LatticesActionEditor extends HTMLElement {
  static observedAttributes = ["readonly"];

  #definition = clone(DEFAULT_DEFINITION);
  #capabilities = clone(DEFAULT_CAPABILITIES);
  #status = { tone: "idle", message: "Ready to test on this Mac" };
  #ready = false;
  #selectedID = "";
  #composerOpen = null;
  #suppressClick = false;

  constructor() {
    super();
    this.attachShadow({ mode: "open" });
  }

  async connectedCallback() {
    if (!this.#ready) {
      const [html, css] = await loadAssets();
      const style = document.createElement("style");
      style.textContent = css;
      this.shadowRoot.append(style);
      const template = document.createElement("template");
      template.innerHTML = html;
      this.shadowRoot.append(template.content.cloneNode(true));
      this.#buildZones();
      this.#bindEvents();
      this.#ready = true;
    }
    this.#render();
  }

  attributeChangedCallback() {
    if (this.#ready) this.#render();
  }

  setDefinition(definition) {
    this.#definition = normalizeDefinition(definition);
    if (!this.#definition.outcomes.some((outcome) => outcome.id === this.#selectedID)) {
      this.#selectedID = "";
    }
    if (this.#ready) this.#render();
  }

  getDefinition() {
    return clone(this.#definition);
  }

  setCapabilities(capabilities) {
    this.#capabilities = { ...clone(DEFAULT_CAPABILITIES), ...capabilities };
    if (this.#ready) this.#render();
  }

  setStatus(status) {
    this.#status = { ...status };
    if (this.#ready) this.#renderStatus();
  }

  #query(selector) {
    const element = this.shadowRoot.querySelector(selector);
    if (!element) throw new Error("Missing Action Studio element: " + selector);
    return element;
  }

  #dispatch(name, detail) {
    this.dispatchEvent(new CustomEvent(name, {
      detail,
      bubbles: true,
      composed: true
    }));
  }

  #emitChange() {
    /* Any edit to a saved action makes it a draft again, so the badge can
       never claim "saved" while the document has unsaved changes. */
    if (this.#definition.status === "saved") {
      this.#definition.status = "draft";
      this.#query(".status-chip").textContent = this.#definition.status;
    }
    this.#dispatch("lattices-action-change", { definition: this.getDefinition() });
  }

  #readOnly() {
    return this.hasAttribute("readonly");
  }

  #allows(placement) {
    return this.#capabilities.placements.includes(placement);
  }

  #buildZones() {
    const zones = this.#query(".zones");
    PLACEMENT_GRID.flat().forEach((placement) => {
      const zone = document.createElement("div");
      zone.className = "zone";
      zone.dataset.placement = placement;
      zone.textContent = displayPlacement(placement);
      zones.append(zone);
    });
  }

  #bindEvents() {
    this.#query(".name-input").addEventListener("input", (event) => {
      this.#definition.name = event.currentTarget.value;
      this.#emitChange();
    });
    this.#query(".instruction").addEventListener("input", (event) => {
      this.#definition.instruction = event.currentTarget.value;
      this.#growInstruction();
      this.#emitChange();
    });
    this.#query(".trigger").addEventListener("input", (event) => {
      this.#definition.triggers[0] = event.currentTarget.value;
      this.#emitChange();
    });
    this.#query(".reuse").addEventListener("change", (event) => {
      this.#definition.behavior.reuseOpenWindows = event.currentTarget.checked;
      this.#renderSummary();
      this.#emitChange();
    });
    this.#query(".preserve").addEventListener("change", (event) => {
      this.#definition.behavior.preserveUnsavedWork = event.currentTarget.checked;
      this.#renderSummary();
      this.#emitChange();
    });
    this.#query(".ambiguity").addEventListener("change", (event) => {
      this.#definition.behavior.ambiguity = event.currentTarget.value;
      this.#renderSummary();
      this.#emitChange();
    });
    this.#query(".describe").addEventListener("click", () => {
      this.#composerOpen = !this.#composerOpen;
      this.#renderComposer();
    });
    this.#query(".interpret").addEventListener("click", () => {
      this.#dispatch("lattices-action-interpret", {
        instruction: this.#definition.instruction
      });
    });
    this.#query(".test").addEventListener("click", () => {
      this.#dispatch("lattices-action-test", { definition: this.getDefinition() });
    });
    this.#query(".save").addEventListener("click", () => {
      this.#dispatch("lattices-action-save", { definition: this.getDefinition() });
    });
    this.#query(".mic").addEventListener("click", () => {
      this.#dispatch("lattices-action-voice-request", {});
    });
    this.#query(".add-outcome").addEventListener("click", () => this.#addOutcome());
  }

  #addOutcome() {
    const taken = new Set(this.#definition.outcomes.map((outcome) => outcome.placement));
    const free = PLACEMENT_GRID.flat().find(
      (placement) => this.#allows(placement) && !taken.has(placement)
    );
    const outcome = {
      id: nextID(),
      label: "New window",
      target: "Choose a window",
      placement: free || this.#capabilities.placements[0] || "center"
    };
    this.#definition.outcomes.push(outcome);
    this.#selectedID = outcome.id;
    this.#renderWindows();
    this.#renderOutcomes();
    this.#renderSummary();
    this.#emitChange();
  }

  #growInstruction() {
    const field = this.#query(".instruction");
    field.style.height = "auto";
    field.style.height = Math.min(field.scrollHeight, 92) + "px";
  }

  #select(stepID) {
    this.#selectedID = this.#selectedID === stepID ? "" : stepID;
    this.#renderWindows();
    this.#renderOutcomes();
  }

  #setPlacement(outcome, placement) {
    if (!this.#allows(placement) || outcome.placement === placement) return;
    outcome.placement = placement;
    this.#renderWindows();
    this.#renderOutcomes();
    this.#emitChange();
  }

  /* Pointer drag, cell-snapped against the 3x3 placement grid. The same
     interaction the Deck Builder study uses for its span grid. */
  #beginDrag(event, outcome, tile) {
    if (this.#readOnly() || event.button !== 0) return;
    /* Clear here rather than relying on a click to consume it: a drag that
       ends outside the tile never fires one, and a stale flag would swallow
       the next legitimate click. */
    this.#suppressClick = false;
    const editor = this.#query(".editor");
    const screen = this.#query(".screen");
    const origin = { x: event.clientX, y: event.clientY };
    let target = outcome.placement;
    let moved = false;

    tile.setPointerCapture(event.pointerId);
    tile.dataset.dragging = "";
    editor.dataset.dragging = "";
    this.#highlightZone(target);

    const onMove = (moveEvent) => {
      const dx = moveEvent.clientX - origin.x;
      const dy = moveEvent.clientY - origin.y;
      if (Math.abs(dx) > 4 || Math.abs(dy) > 4) moved = true;
      tile.style.transform = `translate(${dx}px, ${dy}px)`;

      const rect = screen.getBoundingClientRect();
      const column = clamp(Math.floor(((moveEvent.clientX - rect.left) / rect.width) * 3), 0, 2);
      const row = clamp(Math.floor(((moveEvent.clientY - rect.top) / rect.height) * 3), 0, 2);
      const candidate = PLACEMENT_GRID[row][column];
      target = this.#allows(candidate) ? candidate : target;
      this.#highlightZone(target);
    };

    const onEnd = () => {
      tile.removeEventListener("pointermove", onMove);
      tile.removeEventListener("pointerup", onEnd);
      tile.removeEventListener("pointercancel", onEnd);
      tile.style.transform = "";
      delete tile.dataset.dragging;
      delete editor.dataset.dragging;
      this.#highlightZone(null);

      if (moved) {
        this.#suppressClick = true;
        /* A drag that ends off the tile fires no click, so release the flag on
           the next task rather than leaving it set for the following click. */
        setTimeout(() => { this.#suppressClick = false; }, 0);
        this.#selectedID = outcome.id;
        this.#setPlacement(outcome, target);
        this.#renderWindows();
        this.#renderOutcomes();
      }
    };

    tile.addEventListener("pointermove", onMove);
    tile.addEventListener("pointerup", onEnd);
    tile.addEventListener("pointercancel", onEnd);
  }

  #highlightZone(placement) {
    this.shadowRoot.querySelectorAll(".zone").forEach((zone) => {
      if (zone.dataset.placement === placement) zone.dataset.active = "";
      else delete zone.dataset.active;
    });
  }

  /* Arrow keys walk the same 3x3 grid, so placement is reachable without a
     pointer and the dropdown is a third path rather than the only one. */
  #nudge(outcome, key) {
    const step = {
      ArrowLeft: { column: -1, row: 0 },
      ArrowRight: { column: 1, row: 0 },
      ArrowUp: { column: 0, row: -1 },
      ArrowDown: { column: 0, row: 1 }
    }[key];
    if (!step) return false;

    const at = gridPosition(outcome.placement);
    const column = clamp(at.column + step.column, 0, 2);
    const row = clamp(at.row + step.row, 0, 2);
    const placement = PLACEMENT_GRID[row][column];
    if (!this.#allows(placement)) return true;
    this.#setPlacement(outcome, placement);
    this.shadowRoot.querySelector(`.window-tile[data-step-id="${outcome.id}"]`)?.focus();
    return true;
  }

  #render() {
    const readOnly = this.#readOnly();
    this.#query(".name-input").value = this.#definition.name;
    this.#query(".instruction").value = this.#definition.instruction;
    this.#query(".trigger").value = this.#definition.triggers[0] || "";
    this.#query(".status-chip").textContent = this.#definition.status;
    this.#query(".reuse").checked = this.#definition.behavior.reuseOpenWindows;
    this.#query(".preserve").checked = this.#definition.behavior.preserveUnsavedWork;
    this.#query(".ambiguity").value = this.#definition.behavior.ambiguity;

    this.shadowRoot.querySelectorAll("input, textarea, select").forEach((element) => {
      element.disabled = readOnly;
    });
    this.#query(".interpret").disabled = readOnly || !this.#capabilities.canPlan;
    this.#query(".test").disabled = readOnly || !this.#capabilities.canTest;
    this.#query(".save").disabled = readOnly || !this.#capabilities.canSave;
    this.#query(".mic").disabled = readOnly;
    this.#query(".add-outcome").disabled = readOnly;
    this.#query(".describe").disabled = readOnly;

    if (this.#composerOpen === null) {
      this.#composerOpen = this.#definition.outcomes.length === 0;
    }

    this.#renderComposer();
    this.#growInstruction();
    this.#renderZones();
    this.#renderWindows();
    this.#renderOutcomes();
    this.#renderSummary();
    this.#renderStatus();
  }

  #renderComposer() {
    const wrap = this.#query(".composer-wrap");
    const toggle = this.#query(".describe");
    wrap.hidden = !this.#composerOpen;
    toggle.setAttribute("aria-expanded", String(Boolean(this.#composerOpen)));
    if (this.#composerOpen) this.#growInstruction();
  }

  #renderZones() {
    this.shadowRoot.querySelectorAll(".zone").forEach((zone) => {
      if (this.#allows(zone.dataset.placement)) delete zone.dataset.unavailable;
      else zone.dataset.unavailable = "";
    });
  }

  #renderWindows() {
    const screen = this.#query(".screen");
    const canvas = this.#query(".windows");
    const readOnly = this.#readOnly();
    canvas.replaceChildren();

    if (this.#definition.outcomes.length) delete screen.dataset.empty;
    else screen.dataset.empty = "";

    this.#definition.outcomes.forEach((outcome, position) => {
      const frame = PLACEMENT_FRAME[outcome.placement] || PLACEMENT_FRAME.center;
      const tile = document.createElement("button");
      tile.type = "button";
      tile.className = "window-tile";
      tile.dataset.stepId = outcome.id;
      tile.dataset.placement = outcome.placement;
      tile.style.setProperty("--x", frame.x + "%");
      tile.style.setProperty("--y", frame.y + "%");
      tile.style.setProperty("--w", frame.w + "%");
      tile.style.setProperty("--h", frame.h + "%");
      tile.disabled = readOnly;
      tile.setAttribute(
        "aria-label",
        `${outcome.label}, ${displayPlacement(outcome.placement)}. Arrow keys move it.`
      );
      if (outcome.id === this.#selectedID) tile.dataset.selected = "";

      const top = document.createElement("span");
      top.className = "tile-top";

      const index = document.createElement("span");
      index.className = "tile-index";
      index.textContent = String(position + 1);

      const label = document.createElement("span");
      label.className = "tile-label";
      label.textContent = outcome.label;

      const target = document.createElement("span");
      target.className = "tile-target";
      target.textContent = outcome.target;

      top.append(index, label);
      tile.append(top, target);

      tile.addEventListener("pointerdown", (event) => this.#beginDrag(event, outcome, tile));
      tile.addEventListener("click", () => {
        if (this.#suppressClick) {
          this.#suppressClick = false;
          return;
        }
        this.#select(outcome.id);
      });
      tile.addEventListener("keydown", (event) => {
        if (this.#readOnly()) return;
        if (this.#nudge(outcome, event.key)) event.preventDefault();
      });

      canvas.append(tile);
    });
  }

  #renderOutcomes() {
    const readOnly = this.#readOnly();
    const container = this.#query(".outcomes");
    container.replaceChildren();

    this.#definition.outcomes.forEach((outcome, position) => {
      const row = document.createElement("div");
      row.className = "win-row";
      row.dataset.stepId = outcome.id;
      const selected = outcome.id === this.#selectedID;
      if (selected) row.dataset.selected = "";

      const head = document.createElement("button");
      head.type = "button";
      head.className = "win-head";
      head.disabled = readOnly;
      head.setAttribute("aria-expanded", String(selected));

      const index = document.createElement("span");
      index.className = "step-index";
      index.textContent = String(position + 1);

      const name = document.createElement("span");
      name.className = "win-name";
      name.textContent = outcome.label;

      const place = document.createElement("span");
      place.className = "win-place";
      place.textContent = displayPlacement(outcome.placement);

      head.append(index, name, place);
      head.addEventListener("click", () => this.#select(outcome.id));
      row.append(head);

      if (selected) row.append(this.#buildInspector(outcome));
      container.append(row);
    });
  }

  #buildInspector(outcome) {
    const readOnly = this.#readOnly();
    const body = document.createElement("div");
    body.className = "win-body";

    const field = (labelText, control) => {
      const wrap = document.createElement("label");
      wrap.className = "win-field";
      const caption = document.createElement("span");
      caption.textContent = labelText;
      wrap.append(caption, control);
      return wrap;
    };

    const label = document.createElement("input");
    label.value = outcome.label;
    label.disabled = readOnly;
    label.addEventListener("input", () => {
      outcome.label = label.value;
      this.#renderWindows();
      this.#query(`.win-row[data-step-id="${outcome.id}"] .win-name`).textContent = label.value;
      this.#emitChange();
    });

    const target = document.createElement("input");
    target.value = outcome.target;
    target.disabled = readOnly;
    target.addEventListener("input", () => {
      outcome.target = target.value;
      this.#renderWindows();
      this.#emitChange();
    });

    const placement = document.createElement("select");
    placement.disabled = readOnly;
    DEFAULT_CAPABILITIES.placements
      .filter((candidate) => this.#allows(candidate))
      .forEach((value) => {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = displayPlacement(value);
        option.selected = value === outcome.placement;
        placement.append(option);
      });
    placement.addEventListener("change", () => this.#setPlacement(outcome, placement.value));

    const note = document.createElement("p");
    note.className = "win-field-note";
    note.textContent = "Or drag the window on the workspace.";

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove";
    remove.textContent = "Remove window";
    remove.disabled = readOnly;
    remove.addEventListener("click", () => {
      this.#definition.outcomes = this.#definition.outcomes.filter(
        (candidate) => candidate.id !== outcome.id
      );
      this.#selectedID = "";
      this.#renderWindows();
      this.#renderOutcomes();
      this.#renderSummary();
      this.#emitChange();
    });

    body.append(
      field("Name", label),
      field("Target", target),
      field("Placement", placement),
      note,
      remove
    );
    return body;
  }

  /* Every line is read back off the definition -- the panel never states
     behavior the action does not actually have. */
  #renderSummary() {
    const list = this.#query(".summary-list");
    const behavior = this.#definition.behavior;
    const count = this.#definition.outcomes.length;
    const ambiguity = {
      ask: "Asks you when more than one window matches.",
      "best-match": "Takes the best match when more than one window matches.",
      skip: "Skips the step when more than one window matches."
    }[behavior.ambiguity];

    const lines = [
      {
        on: count > 0,
        text: count === 1 ? "Places 1 window." : "Places " + count + " windows."
      },
      {
        on: behavior.reuseOpenWindows,
        text: behavior.reuseOpenWindows
          ? "Reuses windows that are already open."
          : "Opens a new window for every step."
      },
      {
        on: behavior.preserveUnsavedWork,
        text: behavior.preserveUnsavedWork
          ? "Never closes a window with unsaved changes."
          : "May close windows that have unsaved changes."
      },
      { on: behavior.ambiguity === "ask", text: ambiguity }
    ];

    list.replaceChildren();
    lines.forEach((line) => {
      const item = document.createElement("li");
      if (line.on) item.dataset.on = "";
      item.textContent = line.text;
      list.append(item);
    });
  }

  #renderStatus() {
    const footer = this.#query(".footer");
    footer.dataset.tone = this.#status.tone;
    this.#query(".status-message").textContent = this.#status.message;

    const unavailable = [];
    if (!this.#capabilities.canPlan) unavailable.push("plan");
    if (!this.#capabilities.canTest) unavailable.push("test");
    if (!this.#capabilities.canSave) unavailable.push("save");
    this.#query(".capability-note").textContent = unavailable.length
      ? "Unavailable: " + unavailable.join(", ")
      : "ACTION SCHEMA v1";
  }
}

export function defineLatticesActionEditor(tagName = "lattices-action-editor") {
  if (!customElements.get(tagName)) {
    customElements.define(tagName, LatticesActionEditor);
  }
}

export const sampleDefinition = clone(DEFAULT_DEFINITION);
export const defaultCapabilities = clone(DEFAULT_CAPABILITIES);

defineLatticesActionEditor();
