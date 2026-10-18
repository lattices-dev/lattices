import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

// Reads the desktop palette (Omarchy) and the user's optional appearance file,
// then retunes them into the Lattices tokens that Theme.qml applies. Nothing
// here writes to disk.

export type Mode = "dark" | "light";
export interface Palette { mode: Mode; background: string; foreground: string; accent: string | null; name: string | null }
export interface AppearanceConfig { followSystem: boolean; accent: string | null; translucency: number; uiFont: string | null; monoFont: string | null }
export interface Appearance {
  source: "omarchy" | "default"; theme: string | null; mode: Mode;
  chassisOpacity: number; font: string; mono: string; tokens: Record<TokenName, string>;
}
type Env = Record<string, string | undefined>;

export const TOKEN_NAMES = [
  "ink", "bg", "chassis", "surface", "hover", "border", "borderLit", "borderHot", "grid",
  "text", "body", "muted", "dim",
  "accent", "accentSoft", "accentLine", "accentHover", "accentInk", "selection",
  "live", "liveSoft", "liveLine",
  "caution", "cautionSoft", "cautionLine",
  "red", "redSoft", "redText",
] as const;
export type TokenName = typeof TOKEN_NAMES[number];

export const TRANSLUCENCY = { min: 0.88, max: 1, fallback: 0.94 } as const;
export const DEFAULT_FONTS = { font: "Adwaita Sans", mono: "JetBrains Mono" } as const;
// Neutral black, gray and white with one warm amber. Used whenever no desktop
// palette is available or the user turns follow_system off.
export const DEFAULT_PALETTE: Palette = { mode: "dark", background: "#121212", foreground: "#bebebe", accent: "#e68e0d", name: null };
export const DEFAULT_CONFIG: AppearanceConfig = { followSystem: true, accent: null, translucency: TRANSLUCENCY.fallback, uiFont: null, monoFont: null };

// ── Color ───────────────────────────────────────────────────────────────

/** `#rgb`, `#rrggbb` or `#rrggbbaa` (alpha dropped), with or without `#`. */
export function parseHex(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const hex = value.trim().replace(/^#/, "");
  if (!/^(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(hex)) return null;
  const full = hex.length === 3 ? hex.replace(/./g, digit => digit + digit) : hex.slice(0, 6);
  return "#" + full.toLowerCase();
}
const channels = (hex: string) => [1, 3, 5].map(at => parseInt(hex.slice(at, at + 2), 16));
export function mix(from: string, to: string, amount: number): string {
  const a = channels(from), b = channels(to), t = Math.min(1, Math.max(0, amount));
  return "#" + a.map((value, i) => Math.round(value + (b[i] - value) * t).toString(16).padStart(2, "0")).join("");
}
export function luminance(hex: string): number {
  const [r, g, b] = channels(hex).map(value => { const c = value / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
/** The color nearest `from` on the way to `to` that reaches `ratio` against `ground`. */
function reach(from: string, to: string, ground: string, ratio: number): string {
  if (contrast(from, ground) >= ratio) return from;
  if (contrast(to, ground) < ratio) return to;
  let low = 0, high = 1;
  for (let step = 0; step < 12; step++) {
    const middle = (low + high) / 2;
    if (contrast(mix(from, to, middle), ground) >= ratio) high = middle; else low = middle;
  }
  return mix(from, to, high);
}

/**
 * The Lattices tokens for one palette. Only background, foreground and accent
 * are read: a theme's named signal colors do not carry a fixed meaning (one
 * stock theme's `green` is yellow), so caution and failure hues are our own.
 */
export function deriveTokens(palette: Pick<Palette, "mode" | "background" | "foreground" | "accent">): Record<TokenName, string> {
  const ground = palette.background;
  let dark = palette.mode === "dark";
  // A palette whose declared mode cannot hold readable text on its own
  // background is treated as the other mode.
  if (contrast(dark ? "#ffffff" : "#000000", ground) < 4.5) dark = !dark;
  const pole = mix(palette.foreground, dark ? "#ffffff" : "#000000", 0.86);
  const lift = (amount: number) => mix(ground, pole, amount);
  const chassis = dark ? ground : lift(0.035);
  const bg = dark ? mix(ground, "#000000", 0.16) : ground;
  const tone = (ratio: number) => reach(chassis, pole, chassis, ratio);
  const accent = reach(palette.accent ?? DEFAULT_PALETTE.accent!, pole, chassis, 4.5);
  const caution = reach(dark ? "#ddbb88" : "#8e550b", pole, chassis, 5);
  const red = reach(dark ? "#ef6c70" : "#b6202a", pole, chassis, 4.5);
  const inks = [mix(accent, "#000000", 0.86), mix(accent, "#ffffff", 0.92)];
  return {
    ink: dark ? mix(ground, "#000000", 0.4) : lift(0.07),
    bg, chassis,
    surface: lift(dark ? 0.05 : 0.035),
    hover: lift(dark ? 0.095 : 0.09),
    border: lift(dark ? 0.085 : 0.11),
    borderLit: lift(dark ? 0.17 : 0.2),
    borderHot: lift(dark ? 0.27 : 0.32),
    grid: lift(dark ? 0.1 : 0.12),
    text: tone(16.5), body: tone(10.5), muted: tone(6.6), dim: tone(4.3),
    accent,
    accentSoft: mix(bg, accent, 0.15),
    accentLine: mix(bg, accent, 0.52),
    accentHover: mix(accent, pole, 0.2),
    accentInk: contrast(inks[0], accent) >= contrast(inks[1], accent) ? inks[0] : inks[1],
    selection: mix(bg, accent, 0.34),
    live: tone(16.5),
    liveSoft: mix(bg, pole, 0.11),
    liveLine: mix(bg, pole, 0.36),
    caution,
    cautionSoft: mix(bg, caution, 0.13),
    cautionLine: mix(bg, caution, 0.45),
    red,
    redSoft: mix(bg, red, 0.15),
    redText: mix(red, pole, 0.42),
  };
}

// ── Files ───────────────────────────────────────────────────────────────

/**
 * `key = value` lines, as lenient as Omarchy's own colors.toml reader: quoted
 * or bare values, `#` comments, table headers and unknown lines skipped.
 */
export function parseFlat(text: string): Record<string, string> {
  const values: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    const split = line.indexOf("=");
    if (split < 0) continue;
    const key = line.slice(0, split).replace(/["'\s]/g, "");
    if (!/^[A-Za-z0-9_-]+$/.test(key)) continue;
    const raw = line.slice(split + 1).trim();
    const quoted = /^(["'])(.*?)\1/.exec(raw);
    const value = quoted ? quoted[2] : raw.startsWith("#") ? raw.split(/\s/)[0] : raw.split("#")[0].trim();
    if (value.length <= 200) values[key] = value;
  }
  return values;
}

/** A palette from colors.toml text, or null when it lacks a usable background or foreground. */
export function parsePalette(text: string, hints: { lightFile?: boolean; name?: string | null } = {}): Palette | null {
  const raw = parseFlat(text);
  const background = parseHex(raw.background ?? raw.bg ?? raw.color0);
  const foreground = parseHex(raw.foreground ?? raw.fg ?? raw.color7);
  if (!background || !foreground) return null;
  // Same precedence as omarchy-theme-color: mode, theme_type, light.mode, background.
  const declared = (raw.mode ?? raw.theme_type ?? "").toLowerCase();
  const [r, g, b] = channels(background);
  const mode: Mode = declared === "light" || declared === "dark" ? declared : hints.lightFile || r + g + b > 382 ? "light" : "dark";
  return { mode, background, foreground, accent: parseHex(raw.accent), name: hints.name ?? null };
}

const stateHome = (env: Env) => env.XDG_STATE_HOME || join(env.HOME || homedir(), ".local", "state");
const configHome = (env: Env) => env.XDG_CONFIG_HOME || join(env.HOME || homedir(), ".config");

/** Omarchy `current` directories, newest layout first. */
export function themeCandidates(env: Env = process.env): string[] {
  const home = env.HOME || homedir();
  return [...new Set([
    join(stateHome(env), "omarchy", "current"),
    join(home, ".local", "state", "omarchy", "current"),
    join(configHome(env), "omarchy", "current"),
  ])];
}
/**
 * The first Omarchy `current` directory that exists. A theme switch removes
 * `current/theme` for a moment but never `current`, so an older layout is not
 * picked up mid-switch.
 */
export function locateCurrent(env: Env = process.env): string | null {
  return themeCandidates(env).find(existsSync) ?? null;
}
const cleanName = (value: string) => { const name = value.trim(); return /^[\w .-]{1,64}$/.test(name) ? name : null; };
const read = (path: string) => { try { return readFileSync(path, "utf8"); } catch { return null; } };

/** The palette Omarchy has applied right now, or null while it is missing or invalid. */
export function readPalette(env: Env = process.env): Palette | null {
  const current = locateCurrent(env);
  if (!current) return null;
  const theme = join(current, "theme");
  const text = read(join(theme, "colors.toml"));
  if (text === null) return null;
  let name = cleanName(read(join(current, "theme.name")) ?? "");
  if (!name) { try { const real = basename(realpathSync(theme)); name = real === "theme" ? null : cleanName(real); } catch { /* Unnamed. */ } }
  return parsePalette(text, { lightFile: existsSync(join(theme, "light.mode")), name });
}

export const configPath = (env: Env = process.env) => join(configHome(env), "lattices", "appearance.toml");
const fontName = (value: string) => /^[\p{L}\p{N}][\p{L}\p{N} ._'-]{0,63}$/u.test(value) ? value : null;

/** The user's appearance file. Every bad value is reported and replaced by its default. */
export function parseConfig(text: string): { config: AppearanceConfig; issues: string[] } {
  const raw = parseFlat(text);
  const config = { ...DEFAULT_CONFIG };
  const issues: string[] = [];
  if (raw.follow_system !== undefined) {
    if (raw.follow_system === "true" || raw.follow_system === "false") config.followSystem = raw.follow_system === "true";
    else issues.push("follow_system must be true or false");
  }
  if (raw.accent !== undefined && raw.accent !== "") {
    config.accent = parseHex(raw.accent);
    if (!config.accent) issues.push("accent must be a hex color such as \"#e68e0d\"");
  }
  if (raw.translucency !== undefined) {
    const value = /^\d*\.?\d+$/.test(raw.translucency) ? Number(raw.translucency) : NaN;
    if (Number.isFinite(value)) config.translucency = Math.min(TRANSLUCENCY.max, Math.max(TRANSLUCENCY.min, value));
    else issues.push(`translucency must be a number from ${TRANSLUCENCY.min} to ${TRANSLUCENCY.max}`);
  }
  for (const [key, field] of [["ui_font", "uiFont"], ["mono_font", "monoFont"]] as const) {
    if (raw[key] === undefined || raw[key] === "") continue;
    config[field] = fontName(raw[key]);
    if (!config[field]) issues.push(`${key} must be a font family name of at most 64 characters`);
  }
  return { config, issues };
}
export function readConfig(env: Env = process.env): { config: AppearanceConfig; issues: string[] } {
  const text = read(configPath(env));
  return text === null ? { config: { ...DEFAULT_CONFIG }, issues: [] } : parseConfig(text);
}

// ── Appearance ──────────────────────────────────────────────────────────

/** What Theme.applyAppearance receives. A null palette means the built-in neutral and amber. */
export function resolveAppearance(palette: Palette | null, config: AppearanceConfig = DEFAULT_CONFIG): Appearance {
  const base = config.followSystem && palette ? palette : DEFAULT_PALETTE;
  return {
    source: base === DEFAULT_PALETTE ? "default" : "omarchy",
    theme: base.name,
    mode: base.mode,
    chassisOpacity: config.translucency,
    font: config.uiFont ?? DEFAULT_FONTS.font,
    mono: config.monoFont ?? DEFAULT_FONTS.mono,
    tokens: deriveTokens({ ...base, accent: config.accent ?? base.accent }),
  };
}

/**
 * One read of the desktop. `previous` is the last valid palette: it is kept
 * while the theme directory is missing or unreadable, as it is mid-switch.
 */
export function loadAppearance(env: Env = process.env, previous: Palette | null = null): { appearance: Appearance; palette: Palette | null; issues: string[] } {
  const { config, issues } = readConfig(env);
  const palette = config.followSystem ? readPalette(env) ?? previous : previous;
  return { appearance: resolveAppearance(palette, config), palette, issues };
}

/**
 * Emits the appearance now and again whenever it changes. Polling by content
 * catches Omarchy replacing the whole theme directory as well as an edit in
 * place, and does not depend on the local host.
 */
export function watchAppearance(emit: (appearance: Appearance) => void, options: { env?: Env; intervalMs?: number; warn?: (message: string) => void } = {}) {
  const env = options.env ?? process.env;
  let palette: Palette | null = null;
  let sent = "";
  let warned = "";
  const poll = (force = false) => {
    const next = loadAppearance(env, palette);
    palette = next.palette;
    const complaint = next.issues.join("; ");
    if (complaint !== warned) { warned = complaint; if (complaint) options.warn?.(`${configPath(env)}: ${complaint}`); }
    const encoded = JSON.stringify(next.appearance);
    if (!force && encoded === sent) return;
    sent = encoded;
    emit(next.appearance);
  };
  poll(true);
  const timer = setInterval(poll, options.intervalMs ?? 1000);
  timer.unref?.();
  return { poll, stop: () => clearInterval(timer) };
}
