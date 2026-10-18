import { sampleDefinition } from "../index.mjs";
import { readLibrary, saveDefinition, validateDefinition } from "./storage.mjs";

const editor = document.querySelector("lattices-action-editor");
const shell = document.querySelector("#shell");
const productName = document.querySelector("#product-name");

document.querySelectorAll("[data-skin]").forEach((button) => {
  button.addEventListener("click", () => {
    const skin = button.dataset.skin;
    shell.className = "shell skin-" + skin;
    productName.textContent = skin === "talkie"
      ? "Talkie · Actions"
      : "Lattices · Action Studio";

    document.querySelectorAll("[data-skin]").forEach((candidate) => {
      candidate.setAttribute("aria-pressed", String(candidate === button));
    });
  });
});

// This browser host provides authoring, spatial preview and local persistence.
// A native planner, voice capture and window verification are not connected.
editor.setCapabilities({ canPlan: false, canTest: false });
let dirty = false;
let actions = [];
let storage;
const library = document.querySelector(".library");
const newButton = library.querySelector("header button");
const list = document.createElement("div");
list.className = "group";
library.querySelectorAll(".group").forEach((group) => group.remove());
library.append(list);

function renderLibrary() {
  list.replaceChildren();
  const heading = document.createElement("div");
  heading.className = "group-label";
  heading.textContent = "SAVED IN THIS BROWSER";
  list.append(heading);
  if (!actions.length) {
    const empty = document.createElement("p");
    empty.textContent = "Save your first action to keep it here.";
    list.append(empty);
  }
  actions.forEach((action) => {
    const button = document.createElement("button");
    const selected = action.id === editor.getDefinition().id;
    button.className = "action-row" + (selected ? " active" : "");
    button.setAttribute("aria-pressed", String(selected));
    const icon = document.createElement("span");
    icon.textContent = "□";
    icon.setAttribute("aria-hidden", "true");
    const copy = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = action.name;
    const detail = document.createElement("small");
    detail.textContent = "Saved locally";
    copy.append(name, detail);
    button.append(icon, copy);
    button.addEventListener("click", () => {
      if (dirty && !window.confirm("Discard unsaved edits and open this action?")) return;
      editor.setDefinition(action);
      dirty = false;
      editor.setStatus({ tone: "idle", message: "Saved in this browser · layout preview only" });
      renderLibrary();
    });
    list.append(button);
  });
}

try {
  storage = window.localStorage;
  actions = readLibrary(storage);
  if (actions.length) editor.setDefinition(actions[0]);
  editor.setStatus({ tone: "idle", message: "Browser workspace · save locally · native planning and testing unavailable" });
} catch {
  editor.setCapabilities({ canPlan: false, canTest: false, canSave: false });
  editor.setStatus({ tone: "error", message: "Saved actions could not be loaded. Existing storage has been preserved; saving is disabled." });
}
renderLibrary();

newButton.addEventListener("click", () => {
  if (dirty && !window.confirm("Discard unsaved edits and start a new action?")) return;
  editor.setDefinition({ ...sampleDefinition, id: crypto.randomUUID(), name: "Untitled action", status: "draft" });
  dirty = true;
  editor.setStatus({ tone: "idle", message: "New action from sample · edit the steps and save in this browser" });
  renderLibrary();
});

editor.addEventListener("lattices-action-change", () => {
  dirty = true;
  editor.setStatus({ tone: "idle", message: "Unsaved edits · layout preview only" });
});
editor.addEventListener("lattices-action-save", () => {
  const definition = editor.getDefinition();
  const errors = validateDefinition(definition);
  if (errors.length) {
    editor.setStatus({ tone: "error", message: errors.join(" ") });
    return;
  }
  try {
    const result = saveDefinition(storage, definition);
    actions = result.actions;
    editor.setDefinition(result.saved);
    dirty = false;
    renderLibrary();
    editor.setStatus({ tone: "success", message: "Saved in this browser. No windows changed or devices synced." });
  } catch {
    editor.setStatus({ tone: "error", message: "Could not save this action. Your edits remain open; browser storage may be unavailable or full." });
  }
});
editor.addEventListener("lattices-action-interpret", () => {
  editor.setStatus({ tone: "warning", message: "Automatic interpretation is not connected. Edit the steps directly." });
});
editor.addEventListener("lattices-action-test", () => {
  editor.setStatus({ tone: "warning", message: "Native window testing is not connected. The layout is a preview only." });
});
editor.addEventListener("lattices-action-voice-request", () => {
  editor.setStatus({ tone: "warning", message: "Voice capture is not connected in this browser host. Type the instruction instead." });
});
window.addEventListener("beforeunload", (event) => {
  if (dirty) { event.preventDefault(); event.returnValue = ""; }
});
