import { expect, test } from "bun:test";
import { readLibrary, saveDefinition, STORAGE_KEY, validateDefinition } from "../demo/storage.mjs";
const fixture = () => ({ schemaVersion: 1, id: "focus", name: "Focus", instruction: "Keep code visible", triggers: ["Focus"], outcomes: [{ id: "code", label: "Code", target: "Editor", placement: "left" }], behavior: { reuseOpenWindows: true, preserveUnsavedWork: true, ambiguity: "ask" } });
const memory = () => { const values = new Map(); return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) }; };
test("saved actions survive reload and edits replace only their own identity", () => {
  const storage = memory();
  saveDefinition(storage, fixture());
  saveDefinition(storage, { ...fixture(), id: "other", name: "Other" });
  saveDefinition(storage, { ...fixture(), name: "Updated" });
  expect(readLibrary(storage).map(({ name }) => name)).toEqual(["Updated", "Other"]);
  expect(readLibrary(storage)[0].status).toBe("saved");
});
test("invalid placements, empty fields and duplicate steps are rejected before writing", () => {
  const storage = memory();
  const invalid = fixture();
  invalid.name = " ";
  invalid.outcomes.push({ ...invalid.outcomes[0], placement: "offscreen" });
  expect(validateDefinition(invalid)).toHaveLength(3);
  expect(() => saveDefinition(storage, invalid)).toThrow();
  expect(storage.getItem(STORAGE_KEY)).toBeNull();
});
test("corrupt or future storage remains intact rather than being replaced", () => {
  for (const raw of ["broken", '{"version":2,"actions":[]}', '{"version":1,"actions":[{}]}']) {
    const storage = memory(); storage.setItem(STORAGE_KEY, raw);
    expect(() => saveDefinition(storage, fixture())).toThrow();
    expect(storage.getItem(STORAGE_KEY)).toBe(raw);
  }
});
test("storage errors propagate and never produce a success receipt", () => {
  const storage = { getItem: () => null, setItem: () => { throw new Error("Quota exceeded"); } };
  expect(() => saveDefinition(storage, fixture())).toThrow("Quota exceeded");
});
