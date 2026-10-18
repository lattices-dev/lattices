// Browser-host persistence. This is deliberately separate from the editor and native runtime.
export const STORAGE_KEY = "lattices.action-studio.library.v1";
const placements = new Set(["left", "right", "upper-left", "upper-right", "lower-left", "lower-right", "center", "maximize", "keep-visible"]);
const text = (value) => typeof value === "string" && value.trim().length > 0;

export function validateDefinition(definition) {
  if (!definition || typeof definition !== "object") return ["Action must be a document."];
  const errors = [];
  if (definition.schemaVersion !== 1) errors.push("Unsupported action version.");
  if (!text(definition.id)) errors.push("Action needs an identifier.");
  if (!text(definition.name)) errors.push("Enter an action name.");
  if (!text(definition.instruction)) errors.push("Describe the desired outcome.");
  if (!Array.isArray(definition.triggers) || !definition.triggers.length || !definition.triggers.every(text)) errors.push("Enter a trigger phrase.");
  if (!Array.isArray(definition.outcomes) || !definition.outcomes.length) {
    errors.push("Add at least one step.");
  } else {
    const ids = new Set();
    definition.outcomes.forEach((step, index) => {
      if (!step || !text(step.id) || ids.has(step.id)) errors.push(`Step ${index + 1} needs a unique identifier.`);
      if (!step || !text(step.label) || !text(step.target)) errors.push(`Complete the label and target for step ${index + 1}.`);
      if (!step || !placements.has(step.placement)) errors.push(`Choose a supported placement for step ${index + 1}.`);
      if (step) ids.add(step.id);
    });
  }
  const behavior = definition.behavior;
  if (!behavior || typeof behavior.reuseOpenWindows !== "boolean" || typeof behavior.preserveUnsavedWork !== "boolean" || !["ask", "skip", "best-match"].includes(behavior.ambiguity)) errors.push("Choose valid action behavior.");
  return errors;
}

export function readLibrary(storage) {
  const raw = storage.getItem(STORAGE_KEY);
  if (raw === null) return [];
  const library = JSON.parse(raw);
  if (library?.version !== 1 || !Array.isArray(library.actions)) throw new Error("Saved action library is not supported.");
  const ids = new Set();
  for (const action of library.actions) {
    if (validateDefinition(action).length || ids.has(action.id)) throw new Error("Saved action library contains an invalid action.");
    ids.add(action.id);
  }
  return structuredClone(library.actions);
}

export function saveDefinition(storage, definition) {
  const errors = validateDefinition(definition);
  if (errors.length) throw new Error(errors.join(" "));
  // Re-read before every write so another tab's saved actions are retained.
  const actions = readLibrary(storage);
  const saved = structuredClone({ ...definition, status: "saved" });
  const index = actions.findIndex((action) => action.id === saved.id);
  if (index < 0) actions.push(saved);
  else actions[index] = saved;
  storage.setItem(STORAGE_KEY, JSON.stringify({ version: 1, actions }));
  return { saved, actions };
}
