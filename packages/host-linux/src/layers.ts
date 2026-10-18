import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import * as desktop from "./desktop.ts";
import * as hypr from "./hyprland.ts";
import { layoutFrames, layoutKind } from "./layer-layout.ts";
import { parsePlacement } from "./placement.ts";
import { Router, RouterError, num, requireStr, str, type Json, type Params } from "./router.ts";

interface Pin { wid: number; pid?: number; app: string; title: string }
interface Entry { app?: string; title?: string; path?: string; group?: string; match?: Record<string, unknown>; pins?: Pin[]; saved?: boolean; tile?: string; display?: number }
interface Layer { id: string; label: string; projects: Entry[]; layout?: string | null }
interface Config { name?: string; layers?: Layer[]; groups?: { id: string; tabs: Entry[] }[]; [key: string]: unknown }
interface Parked { window: desktop.Window; space: number }
const json = (value: unknown) => value as Json;
const contains = (value: string, needle?: string) => needle === undefined || value.toLowerCase().includes(needle.toLowerCase());
const content = (w: desktop.Window) => w.frame.w >= 120 && w.frame.h >= 120 && !!w.title && !(w.app === "org.quickshell" && w.title === "Lattices");
const expand = (path: string) => resolve(path === "~" ? homedir() : path.startsWith("~/") ? homedir() + path.slice(1) : path);
const sessionName = (path: string) => { const full = expand(path); return basename(full) + "-" + createHash("sha256").update(full).digest("hex").slice(0, 6); };

function clauseMatches(c: Record<string, unknown>, w: desktop.Window): boolean {
  let positive = false;
  for (const [key, value] of Object.entries(c)) {
    if (key === "not" || value === undefined || value === null || value === "") continue;
    const field = key.startsWith("app") ? w.app : key.startsWith("title") ? w.title : w.latticesSession ?? "";
    let ok = false;
    if (["app", "titleContains", "sessionContains"].includes(key) && typeof value === "string") ok = contains(field, value);
    else if (["appEquals", "titleEquals", "session"].includes(key) && typeof value === "string") ok = field.toLowerCase() === value.toLowerCase();
    else if (["appRegex", "titleRegex"].includes(key) && typeof value === "string") { try { ok = new RegExp(value, "i").test(field); } catch { return false; } }
    else if (key === "isOnScreen") ok = w.isOnScreen === value;
    else if (key === "spaceId") ok = w.spaceIds.includes(Number(value));
    else return false;
    positive = true;
    if (!ok) return false;
  }
  return positive && !(Array.isArray(c.not) && c.not.some(exclude => clauseMatches(exclude, w)));
}

// Keep one owner per window, using the same pin/rule/group/path/app priority.
function membership(config: Config, windows: desktop.Window[]) {
  const layers = config.layers ?? [];
  const held = layers.map(layer => layer.projects.map(() => [] as desktop.Window[]));
  for (const w of windows.filter(content)) {
    let best: { l: number; p: number; tier: number; specificity: number } | undefined;
    layers.forEach((layer, l) => layer.projects.forEach((entry, p) => {
      let tier = 99;
      let specificity = (entry.title?.length ?? 0) * 1000 + (entry.app?.length ?? 0);
      if (entry.pins?.some(pin => pin.wid === w.wid && pin.app === w.app && (pin.pid === undefined || pin.pid === w.pid))) tier = 0;
      else if (!entry.saved) {
        if (entry.match) {
          if (clauseMatches(entry.match, w)) tier = Object.keys(entry.match).filter(key => key !== "not").every(key => key.startsWith("app")) ? 4 : 1;
        }
        else if (entry.group && config.groups?.find(group => group.id === entry.group)?.tabs.some(tab => tab.path ? w.latticesSession === sessionName(tab.path) : !!tab.app && contains(w.app, tab.app) && contains(w.title, tab.title))) tier = 2;
        else if (entry.path && w.latticesSession === sessionName(entry.path)) tier = 3;
        else if (entry.app && contains(w.app, entry.app) && contains(w.title, entry.title)) tier = 4;
      }
      if (tier === 0) specificity = 0;
      if (tier < 99 && (!best || tier < best.tier || (tier === best.tier && specificity > best.specificity))) best = { l, p, tier, specificity };
    }));
    if (best) held[best.l][best.p].push(w);
  }
  return held;
}

export class Layers {
  private readonly path: string;
  private readonly stagePath: string;
  private backedUp = false;
  private active: string | null = null;
  private parked: Parked[] = [];
  private queue = Promise.resolve();
  private stageError: string | undefined;
  constructor(private emit: (event: string, data: unknown) => void = () => {}, directory = process.env.LATTICES_WORKSPACE_DIR ?? `${homedir()}/.lattices`, private deps = { snapshot: desktop.snapshot, apply: hypr.apply, place: desktop.place }) {
    this.path = `${directory}/workspace.json`;
    this.stagePath = `${directory}/layers-stage-linux.json`;
    if (existsSync(this.stagePath)) {
      try {
        const state = JSON.parse(readFileSync(this.stagePath, "utf8"));
        if (!Array.isArray(state.parked) || state.parked.some((r: Parked) => !r.window || !Number.isInteger(r.space) || !Number.isInteger(r.window.wid) || !Number.isInteger(r.window.pid))) throw new Error("Invalid parked window records");
        this.active = state.active ?? null;
        this.parked = state.parked;
      } catch (error) { this.stageError = `Cannot read layers-stage-linux.json: ${(error as Error).message}`; }
    }
  }
  private config(): Config {
    if (!existsSync(this.path)) return { name: "Workspace", layers: [] };
    const config = JSON.parse(readFileSync(this.path, "utf8")) as Config;
    if (!config || typeof config !== "object" || Array.isArray(config) || (config.layers !== undefined && (!Array.isArray(config.layers) || config.layers.some(layer => !layer.id || !layer.label || !Array.isArray(layer.projects))))) throw new RouterError("Invalid workspace.json: expected layers with id, label and projects");
    return config;
  }
  private atomic(path: string, value: unknown) {
    mkdirSync(dirname(path), { recursive: true });
    const temporary = `${path}.${process.pid}.tmp`;
    writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
    renameSync(temporary, path);
  }
  private save(config: Config) {
    if (!this.backedUp && existsSync(this.path)) copyFileSync(this.path, this.path + ".bak");
    this.backedUp = true;
    this.atomic(this.path, config);
    this.emit("layers.changed", {});
  }
  private saveStage() { this.atomic(this.stagePath, { active: this.active, parked: this.parked }); }
  private target(config: Config, params: Params): number {
    const layers = config.layers ?? [];
    const index = num(params, "index");
    const name = str(params, "layer") ?? str(params, "name");
    const found = index ?? layers.findIndex(layer => name ? layer.id === name || layer.label === name : layer.id === this.active);
    if (!Number.isInteger(found) || found < 0 || found >= layers.length) throw RouterError.notFound("layer");
    return found;
  }
  private async snapshot() {
    if (this.stageError) throw new RouterError(this.stageError);
    const snap = await this.deps.snapshot();
    const windows = snap.clients.filter(c => c.mapped && (c.workspace.id > 0 || c.workspace.name === "special:lattices"))
      .sort((a, b) => a.focusHistoryID - b.focusHistoryID).map(c => desktop.toWindow(c, snap.monitors, snap.focused));
    this.parked = this.parked.filter(record => windows.some(w => w.wid === record.window.wid && w.pid === record.window.pid && w.spaceIds[0] < 0));
    return { ...snap, windows };
  }
  private stage() { return { parked: this.parked.map(r => ({ wid: r.window.wid, app: r.window.app, title: r.window.title })), hidden: [] }; }
  async list() {
    const config = this.config();
    await this.snapshot();
    return { layers: (config.layers ?? []).map((layer, index) => ({ id: layer.id, label: layer.label, index, projectCount: layer.projects.length, layout: layer.layout ?? null })), active: (config.layers ?? []).findIndex(layer => layer.id === this.active), stage: this.stage() };
  }
  async members(params: Params = {}) {
    const config = this.config();
    const snap = await this.snapshot();
    const held = membership(config, snap.windows);
    const chosen = params.layer !== undefined || params.index !== undefined ? this.target(config, params) : -1;
    const active = (config.layers ?? []).findIndex(layer => layer.id === this.active);
    return { active, stage: this.stage(), layers: (config.layers ?? []).map((layer, index) => ({
      ...layer, index, active: index === active,
      entries: layer.projects.map((entry, p) => ({ index: p, name: entry.app ?? (entry.path ? basename(entry.path) : entry.group ?? "Window rule"), rule: entry.saved ? "Saved window" : entry.title ?? entry.path ?? entry.group ?? "App rule", missing: held[index][p].length ? null : "Not open", windows: held[index][p].map(w => ({ ...w, presence: this.parked.some(r => r.window.wid === w.wid) ? "parked" : w.isOnScreen ? "showing" : "elsewhere" })) }))
    })).filter(layer => chosen < 0 || layer.index === chosen) };
  }
  private pick(params: Params, windows: desktop.Window[], visible = false) {
    const specified = params.windowIds ?? (params.wid !== undefined ? [params.wid] : undefined) ?? (Array.isArray(params.windows) ? params.windows.map(w => typeof w === "object" && w ? (w as Record<string, Json>).wid : null) : undefined);
    if (specified !== undefined && (!Array.isArray(specified) || specified.some(id => typeof id !== "number" || !Number.isInteger(id)))) throw new RouterError("windowIds must contain integer window ids");
    const picked = specified === undefined ? windows.filter(w => visible && w.isOnScreen && content(w)) : (specified as number[]).map(id => {
      const window = windows.find(w => w.wid === id && content(w));
      if (!window) throw RouterError.notFound(`content window ${id}`);
      return window;
    });
    return [...new Map(picked.map(w => [w.wid, w])).values()];
  }
  private assign(config: Config, layer: Layer, windows: desktop.Window[]) {
    const ids = new Set(windows.map(w => w.wid));
    for (const other of config.layers ?? []) {
      for (const entry of other.projects) if (entry.pins) entry.pins = entry.pins.filter(pin => !ids.has(pin.wid));
      other.projects = other.projects.filter(entry => !entry.saved || entry.pins?.length);
    }
    for (const w of windows) layer.projects.push({ app: w.app, title: w.title, saved: true, pins: [{ wid: w.wid, pid: w.pid, app: w.app, title: w.title }] });
  }
  async edit(method: string, params: Params) {
    const snap = await this.snapshot();
    const config = this.config(); // Read after async work; preserve other config fields.
    config.layers ??= [];
    if (method === "layers.create") {
      const label = requireStr(params, "name").trim();
      if (!label) throw new RouterError("A layer needs a name");
      const picked = this.pick(params, snap.windows, params.visible !== false);
      const layer: Layer = { id: randomUUID(), label, projects: [], layout: layoutKind(params.layout) };
      config.layers.push(layer); this.assign(config, layer, picked);
      if (Array.isArray(params.windows)) for (const spec of params.windows) {
        if (spec && typeof spec === "object" && !Array.isArray(spec) && typeof spec.tile === "string") {
          parsePlacement(spec.tile);
          const entry = layer.projects.find(e => e.pins?.some(pin => pin.wid === spec.wid));
          if (entry) entry.tile = spec.tile;
        }
      }
      this.save(config);
      return { index: config.layers.length - 1, id: layer.id, label, count: picked.length };
    }
    const index = this.target(config, params);
    const layer = config.layers[index];
    if (method === "layers.rename") {
      const name = requireStr(params, "name").trim();
      if (!name) throw new RouterError("A layer needs a name");
      layer.label = name;
    } else if (method === "layers.layout") layer.layout = layoutKind(params.layout);
    else if (method === "layers.delete") {
      if (layer.id === this.active) await this.reveal();
      const latest = this.config();
      latest.layers = (latest.layers ?? []).filter(l => l.id !== layer.id);
      this.save(latest); return { ok: true };
    } else {
      const picked = this.pick(params, snap.windows);
      if (method === "layers.assign") this.assign(config, layer, picked);
      else {
        const ids = new Set(picked.map(w => w.wid));
        for (const entry of layer.projects) if (entry.pins) entry.pins = entry.pins.filter(pin => !ids.has(pin.wid));
        layer.projects = layer.projects.filter(entry => !entry.saved || entry.pins?.length);
      }
      this.save(config);
      const held = membership(config, snap.windows)[index].flat().filter(w => picked.some(p => p.wid === w.wid)).map(w => w.wid);
      return method === "layers.assign" ? { index, added: picked.length } : { index, removed: picked.length - held.length, held };
    }
    this.save(config); return { ok: true };
  }
  private async restore(record: Parked, window: desktop.Window) {
    const address = window.address;
    await this.deps.apply([{ op: "toWorkspace", address, workspace: record.space }]);
    if (record.window.isFloating) await this.deps.apply([{ op: "float", address }, { op: "resize", address, w: record.window.frame.w, h: record.window.frame.h }, { op: "move", address, x: record.window.frame.x, y: record.window.frame.y }]);
    this.parked = this.parked.filter(r => r !== record);
    this.saveStage();
  }
  async reveal() {
    const snap = await this.snapshot();
    let unparked = 0;
    for (const record of [...this.parked]) {
      if (!snap.displays.some(d => d.currentSpaceId === record.space)) continue;
      const w = snap.windows.find(w => w.wid === record.window.wid && w.pid === record.window.pid);
      if (w) { await this.restore(record, w); unparked++; }
    }
    this.active = null; this.saveStage(); this.emit("layers.changed", {});
    return { ok: true, unparked, stillParked: this.parked.length, rescued: 0, unhidden: [], stage: this.stage() };
  }
  async activate(params: Params) {
    const config = this.config();
    const index = this.target(config, params);
    const layer = config.layers![index];
    const mode = str(params, "mode") ?? "focus";
    if (!["focus", "tile", "retile"].includes(mode)) throw new RouterError("Linux layers support focus and tile modes; launch is not available");
    const snap = await this.snapshot();
    const focusedMonitor = snap.monitors.find(m => m.focused) ?? snap.monitors[0];
    const display = snap.displays.find(d => d.displayId === focusedMonitor?.name);
    if (!display || display.currentSpaceId <= 0) throw new RouterError("No current desktop");
    const members = membership(config, snap.windows)[index];
    const inScope = (w: desktop.Window) => w.displayIndex === display.displayIndex && (w.spaceIds.includes(display.currentSpaceId) || this.parked.some(r => r.window.wid === w.wid && r.space === display.currentSpaceId));
    const selected = members.flat().filter(inScope);
    if (!selected.length) throw new RouterError("This layer has no windows on the current display and desktop");
    const ids = new Set(selected.map(w => w.wid));
    const park = snap.windows.filter(w => content(w) && w.isOnScreen && inScope(w) && !ids.has(w.wid) && !snap.clients.find(c => c.address === w.address)?.pinned);
    const automatic = selected.filter(w => !members.some((held, p) => held.some(h => h.wid === w.wid) && (layer.projects[p].tile || layer.projects[p].display !== undefined)));
    const kind = layoutKind(layer.layout);
    const frames = kind ? layoutFrames(kind, automatic.map(w => w.app), display.visibleFrame.w / display.visibleFrame.h) : [];
    // Validate explicit placements before putting away any windows.
    const tiles = mode === "focus" ? [] : layer.projects.flatMap((entry, p) => entry.tile ? members[p].filter(inScope).map(w => ({ w, fractions: parsePlacement(entry.tile!) })) : []);
    if (params.dryRun === true) return { ok: true, index, label: layer.label, parked: park.map(w => w.wid), windows: selected.map(w => w.wid), layout: kind, frames };
    for (const w of park) {
      const record = { window: w, space: display.currentSpaceId };
      this.parked.push(record); this.saveStage(); // Recovery survives host restarts and partial batches.
      await this.deps.apply([{ op: "toWorkspace", address: w.address, workspace: "special:lattices" }]);
    }
    for (const w of selected) {
      const record = this.parked.find(r => r.window.wid === w.wid);
      if (record) await this.restore(record, w);
    }
    for (let i = 0; i < frames.length; i++) await this.deps.place(automatic[i], frames[i], display);
    for (const tile of tiles) await this.deps.place(tile.w, tile.fractions, display);
    await this.deps.apply([{ op: "focus", address: selected[0].address }]);
    this.active = layer.id; this.saveStage(); this.emit("layers.changed", { active: index });
    return { ok: true, index, label: layer.label, count: selected.length, stage: this.stage() };
  }
  serialize<T>(action: () => Promise<T>): Promise<T> {
    const result = this.queue.then(action);
    this.queue = result.then(() => {}, () => {});
    return result;
  }
}

export function registerLayerEndpoints(router: Router, emit?: (event: string, data: unknown) => void) {
  const layers = new Layers(emit);
  const targets = [{ name: "layer", type: "string", description: "Layer id or label" }, { name: "index", type: "int", description: "Layer index (zero-based)" }];
  for (const method of ["layers.list", "layers.members", "layers.create", "layers.assign", "layers.unassign", "layers.rename", "layers.delete", "layers.layout", "layers.activate", "layers.switch", "layers.reveal"]) {
    const read = method === "layers.list" || method === "layers.members";
    router.register({ method, access: read ? "read" : "mutate", capability: read ? "windows.read" : "windows.place", description: method === "layers.layout" ? "Set a layer layout: none, auto, columns or master-stack" : `Workspace ${method.replace(".", " ")}`, params: [...targets, { name: "name", type: "string", description: "Layer name" }, { name: "windowIds", type: "array", description: "Window ids to save, assign or remove" }, { name: "layout", type: "string", description: "Arrangement" }, { name: "mode", type: "string", description: "focus or tile" }, { name: "dryRun", type: "bool", description: "Plan a switch without moving windows" }], returns: "Layer state or action receipt", handler: params => layers.serialize(async () => json(method === "layers.list" ? await layers.list() : method === "layers.members" ? await layers.members(params) : method === "layers.reveal" ? await layers.reveal() : method === "layers.activate" || method === "layers.switch" ? await layers.activate(params) : await layers.edit(method, params))) });
  }
}
