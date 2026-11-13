/* An invented workspace for the Layers page study: the tideline project and a
   few neighbours. A layer holds windows two ways, as workspace.json does:
   rules that match any window by app and title, and pins that hold one window
   by hand. Membership follows LayerMembership: a pin beats a rule, an app and
   title beat a bare app, a longer title beats a shorter one, then the earlier
   layer wins. */

export type Rule =
  | { kind: "app"; app: string }
  | { kind: "title"; app: string; title: string }
  | { kind: "pin"; app: string; title: string; win: string };

export interface Layer { id: string; label: string; slot: number; rules: Rule[] }

export interface Win { id: string; app: string; title: string }

export const windows: Win[] = [
  { id: "w1", app: "Ghostty", title: "mini: tideline" },
  { id: "w2", app: "Ghostty", title: "tideline — bun test --watch" },
  { id: "w3", app: "Zed", title: "tideline — src/harbor/sync.ts" },
  { id: "w4", app: "Chrome", title: "localhost:5173 — Tideline" },
  { id: "w5", app: "Notes", title: "Tideline release checklist" },
  { id: "w6", app: "Ghostty", title: "mini: harbor" },
  { id: "w7", app: "Zed", title: "harbor — api/routes.ts" },
  { id: "w8", app: "Chrome", title: "Harbor API docs" },
  { id: "w9", app: "Linear", title: "TID-142 Harbor sync drops the last tide" },
  { id: "w10", app: "Slack", title: "#tideline" },
  { id: "w11", app: "Calendar", title: "Week 44" },
  { id: "w12", app: "Figma", title: "Tideline — Charts" },
  { id: "w13", app: "Chrome", title: "Tide tables — NOAA" },
  { id: "w14", app: "Spotify", title: "Spotify" },
  { id: "w15", app: "Ghostty", title: "scratch" },
  { id: "w16", app: "Preview", title: "harbor-diagram.pdf" },
];

export const layers: Layer[] = [
  { id: "tideline", label: "Tideline", slot: 1, rules: [
    { kind: "title", app: "Ghostty", title: "tideline" },
    { kind: "title", app: "Zed", title: "tideline" },
    { kind: "title", app: "Chrome", title: "Tideline" },
    { kind: "pin", app: "Notes", title: "Tideline release checklist", win: "w5" },
  ] },
  { id: "harbor", label: "Harbor", slot: 2, rules: [
    { kind: "title", app: "Ghostty", title: "harbor" },
    { kind: "title", app: "Zed", title: "harbor" },
    { kind: "title", app: "Chrome", title: "Harbor" },
    { kind: "pin", app: "Preview", title: "harbor-diagram.pdf", win: "w16" },
  ] },
  { id: "planning", label: "Planning", slot: 3, rules: [
    { kind: "app", app: "Linear" },
    { kind: "app", app: "Slack" },
    { kind: "app", app: "Calendar" },
  ] },
  { id: "design", label: "Design", slot: 4, rules: [
    { kind: "app", app: "Figma" },
    { kind: "title", app: "Chrome", title: "Dribbble" },
  ] },
  { id: "focus", label: "Focus", slot: 6, rules: [
    { kind: "app", app: "Spotify" },
  ] },
];

export type Claim = { layer: Layer; rule: Rule };

const strength = (r: Rule) => r.kind === "pin" ? 1e6 : r.kind === "title" ? 1000 + r.title.length : 0;

export function matches(r: Rule, w: Win) {
  if (r.kind === "pin") return r.win === w.id;
  if (r.app !== w.app) return false;
  return r.kind === "app" || w.title.toLowerCase().includes(r.title.toLowerCase());
}

/** The layer and rule holding a window, or none. */
export function claim(w: Win, list: Layer[] = layers): Claim | undefined {
  let best: Claim | undefined;
  for (const layer of list) for (const rule of layer.rules) {
    if (matches(rule, w) && (!best || strength(rule) > strength(best.rule))) best = { layer, rule };
  }
  return best;
}

/** The windows a rule holds right now: it matches them and nothing stronger does. */
export function held(rule: Rule, layer: Layer, list: Layer[] = layers) {
  return windows.filter(w => { const c = claim(w, list); return c?.layer === layer && c.rule === rule; });
}

export const unassigned = (list: Layer[] = layers) => windows.filter(w => !claim(w, list));

export function describe(r: Rule) {
  return r.kind === "app" ? "Any window" : r.kind === "title" ? `Title has “${r.title}”` : r.title;
}
