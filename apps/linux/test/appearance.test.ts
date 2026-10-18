import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_PALETTE, TOKEN_NAMES, TRANSLUCENCY, configPath, contrast, deriveTokens, loadAppearance, locateCurrent, parseConfig,
  parseFlat, parseHex, parsePalette, readPalette, resolveAppearance, themeCandidates, watchAppearance, type Appearance,
} from "../appearance.ts";
import * as fixtures from "./AppearanceFixtures.mjs";

const MATTE = 'mode = "dark"\n\naccent = "#e68e0d"\nbackground = "#121212"\nforeground = "#bebebe"\n\n# Named signals are not what they say.\ngreen = "#FFC107"\nyellow = "#b91c1c"\n';
const LATTE = 'mode = "light"\naccent = "#1e66f5"\nbackground = "#eff1f5"\nforeground = "#4c4f69"\n';
const NIGHT = 'accent = "#7aa2f7"\nbackground = "#1a1b26"\nforeground = "#a9b1d6"\n';

const roots: string[] = [];
afterAll(() => { for (const root of roots) rmSync(root, { recursive: true, force: true }); });

/** A private home under /tmp. Nothing here reads or changes the real desktop theme. */
function desktop() {
  const root = mkdtempSync(join(tmpdir(), "lattices-appearance-"));
  roots.push(root);
  const env = { HOME: root, XDG_STATE_HOME: join(root, "state"), XDG_CONFIG_HOME: join(root, "config") };
  const current = join(env.XDG_STATE_HOME, "omarchy", "current");
  const write = (path: string, text: string) => { mkdirSync(join(path, ".."), { recursive: true }); writeFileSync(path, text); };
  return {
    root, env, current,
    /** What `omarchy theme set` does: stage beside the theme, swap the directory, then name it. */
    setTheme(name: string, colors: string, extra: Record<string, string> = {}) {
      const next = join(current, "next-theme");
      rmSync(next, { recursive: true, force: true });
      write(join(next, "colors.toml"), colors);
      for (const [file, text] of Object.entries(extra)) write(join(next, file), text);
      rmSync(join(current, "theme"), { recursive: true, force: true });
      renameSync(next, join(current, "theme"));
      writeFileSync(join(current, "theme.name"), name + "\n");
    },
    removeTheme() { rmSync(join(current, "theme"), { recursive: true, force: true }); },
    config(text: string) { write(configPath(env), text); },
  };
}

test("hex colors are normalized and anything else is refused", () => {
  expect(parseHex("#E68E0D")).toBe("#e68e0d");
  expect(parseHex("e68e0d")).toBe("#e68e0d");
  expect(parseHex("#fa0")).toBe("#ffaa00");
  expect(parseHex("#e68e0dcc")).toBe("#e68e0d");
  for (const bad of ["", "#12", "#gggggg", "rgb(1, 2, 3)", "amber", "#1234567", null, 7, undefined]) expect(parseHex(bad)).toBeNull();
});

test("flat files are read as leniently as Omarchy reads colors.toml", () => {
  expect(parseFlat('# heading\n[colors]\naccent = "#e68e0d" # warm\nbare = #fa0 trailing\n"quoted key" = \'single\'\ntranslucency = 0.9 # glass\nbroken line\n = "no key"\nbad key! = "x"\n')).toEqual({
    accent: "#e68e0d", bare: "#fa0", quotedkey: "single", translucency: "0.9",
  });
});

test("the current theme is found in the state directory, then the older config layout", () => {
  const { root, env, current, setTheme } = desktop();
  expect(themeCandidates(env)).toEqual([
    join(root, "state", "omarchy", "current"), join(root, ".local", "state", "omarchy", "current"), join(root, "config", "omarchy", "current"),
  ]);
  expect(themeCandidates({ HOME: root })).toEqual([join(root, ".local", "state", "omarchy", "current"), join(root, ".config", "omarchy", "current")]);
  expect(locateCurrent(env)).toBeNull();
  expect(readPalette(env)).toBeNull();
  expect(loadAppearance(env).appearance).toMatchObject({ source: "default", theme: null, mode: "dark" });

  // The older layout: current/theme is a link into the themes directory.
  const legacy = join(root, "config", "omarchy");
  mkdirSync(join(legacy, "themes", "tokyo-night"), { recursive: true });
  mkdirSync(join(legacy, "current"), { recursive: true });
  writeFileSync(join(legacy, "themes", "tokyo-night", "colors.toml"), NIGHT);
  symlinkSync(join(legacy, "themes", "tokyo-night"), join(legacy, "current", "theme"));
  expect(readPalette(env)).toMatchObject({ name: "tokyo-night", mode: "dark", accent: "#7aa2f7" });

  // Once the state layout exists it wins, even for the moment its theme is gone.
  setTheme("matte-black", MATTE);
  expect(locateCurrent(env)).toBe(current);
  expect(readPalette(env)).toMatchObject({ name: "matte-black", accent: "#e68e0d" });
  rmSync(join(current, "theme"), { recursive: true });
  expect(readPalette(env)).toBeNull();

  // Without XDG_STATE_HOME the same files are found under ~/.local/state.
  const plain = desktop();
  const home = { HOME: plain.root };
  mkdirSync(join(plain.root, ".local", "state", "omarchy", "current", "theme"), { recursive: true });
  writeFileSync(join(plain.root, ".local", "state", "omarchy", "current", "theme", "colors.toml"), LATTE);
  expect(readPalette(home)).toMatchObject({ mode: "light", background: "#eff1f5", name: null });
});

test("a theme switch that replaces the whole directory is followed, and gaps keep the last palette", () => {
  const { env, current, setTheme, removeTheme } = desktop();
  setTheme("matte-black", MATTE);
  const seen: Appearance[] = [];
  const watch = watchAppearance(appearance => seen.push(appearance), { env, intervalMs: 60_000 });
  try {
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ source: "omarchy", theme: "matte-black", mode: "dark", chassisOpacity: TRANSLUCENCY.fallback });
    expect(seen[0].tokens.accent).toBe("#e68e0d");
    watch.poll();
    expect(seen).toHaveLength(1);

    // Mid-switch: the directory is gone, then present but half written.
    removeTheme();
    watch.poll();
    mkdirSync(join(current, "theme"));
    watch.poll();
    writeFileSync(join(current, "theme", "colors.toml"), 'mode = "light"\nbackground = "#ffffff"\n');
    watch.poll();
    writeFileSync(join(current, "theme", "colors.toml"), 'background = "#zzzzzz"\nforeground = "not a color"\n');
    watch.poll();
    writeFileSync(join(current, "theme", "colors.toml"), "\u0000\u0001 not toml at all");
    watch.poll();
    expect(seen).toHaveLength(1);

    setTheme("catppuccin-latte", LATTE);
    watch.poll();
    expect(seen).toHaveLength(2);
    expect(seen[1]).toMatchObject({ source: "omarchy", theme: "catppuccin-latte", mode: "light" });
    expect(seen[1].tokens.bg).toBe("#eff1f5");

    // An edit in place is followed too, and a forced poll always reports.
    writeFileSync(join(current, "theme", "colors.toml"), LATTE.replace("#1e66f5", "#d20f39"));
    watch.poll();
    expect(seen).toHaveLength(3);
    expect(seen[2].tokens.accent).not.toBe(seen[1].tokens.accent);
    watch.poll(true);
    expect(seen).toHaveLength(4);
    expect(seen[3]).toEqual(seen[2]);
  } finally { watch.stop(); }
});

test("without any valid palette the neutral and amber defaults are used", () => {
  const { env, current } = desktop();
  mkdirSync(join(current, "theme"), { recursive: true });
  writeFileSync(join(current, "theme", "colors.toml"), 'accent = "#00ff00"\n');
  const { appearance, palette } = loadAppearance(env);
  expect(palette).toBeNull();
  expect(appearance).toMatchObject({ source: "default", theme: null, mode: "dark", font: "Adwaita Sans", mono: "JetBrains Mono" });
  expect(appearance.tokens).toEqual(deriveTokens(DEFAULT_PALETTE));
  // A theme without an accent keeps its grounds and takes the default amber.
  writeFileSync(join(current, "theme", "colors.toml"), 'bg = "#1a1b26"\nfg = "#a9b1d6"\n');
  const tinted = loadAppearance(env).appearance;
  expect(tinted.source).toBe("omarchy");
  expect(tinted.tokens.chassis).toBe("#1a1b26");
  expect(tinted.tokens.accent).toBe("#e68e0d");
});

test("mode follows Omarchy's precedence: mode, theme_type, light.mode, then the background", () => {
  const ground = (background: string, foreground: string) => `background = "${background}"\nforeground = "${foreground}"\n`;
  expect(parsePalette('mode = "light"\n' + ground("#101010", "#eeeeee"))?.mode).toBe("light");
  expect(parsePalette('theme_type = "Light"\n' + ground("#101010", "#eeeeee"))?.mode).toBe("light");
  expect(parsePalette('mode = "dark"\ntheme_type = "light"\n' + ground("#ffffff", "#000000"))?.mode).toBe("dark");
  expect(parsePalette(ground("#101010", "#eeeeee"), { lightFile: true })?.mode).toBe("light");
  expect(parsePalette(ground("#fafafa", "#202020"))?.mode).toBe("light");
  expect(parsePalette(ground("#202020", "#fafafa"))?.mode).toBe("dark");
  expect(parsePalette('mode = "sepia"\n' + ground("#202020", "#fafafa"))?.mode).toBe("dark");
  const { env, setTheme } = desktop();
  setTheme("paper", ground("#101010", "#eeeeee"), { "light.mode": "" });
  expect(readPalette(env)?.mode).toBe("light");
});

test("dark and light palettes both yield readable tokens in their own mode", () => {
  const palettes = [parsePalette(MATTE)!, parsePalette(LATTE)!, parsePalette(NIGHT)!, parsePalette('background = "#ffffff"\nforeground = "#000000"\naccent = "#6e6e6e"\n')!,
    parsePalette('background = "#000000"\nforeground = "#ffffff"\naccent = "#8d8d8d"\n')!];
  for (const palette of palettes) {
    const t = deriveTokens(palette);
    expect(Object.keys(t).sort()).toEqual([...TOKEN_NAMES].sort());
    for (const value of Object.values(t)) expect(value).toMatch(/^#[0-9a-f]{6}$/);
    const light = palette.mode === "light";
    expect(contrast("#ffffff", t.bg) < contrast("#000000", t.bg)).toBe(light);
    expect(contrast("#ffffff", t.text) > contrast("#000000", t.text)).toBe(light);
    for (const ground of [t.bg, t.chassis]) {
      expect(contrast(t.text, ground)).toBeGreaterThan(11);
      expect(contrast(t.body, ground)).toBeGreaterThan(7);
      expect(contrast(t.muted, ground)).toBeGreaterThan(4.5);
      expect(contrast(t.dim, ground)).toBeGreaterThan(3.5);
      for (const signal of [t.accent, t.caution, t.red, t.live]) expect(contrast(signal, ground)).toBeGreaterThanOrEqual(4.45);
    }
    expect(contrast(t.accentInk, t.accent)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(t.text, t.accentSoft)).toBeGreaterThan(9);
    expect(contrast(t.text, t.surface)).toBeGreaterThan(10);
    expect(contrast(t.redText, t.bg)).toBeGreaterThan(4.5);
    expect(contrast(t.borderLit, t.bg)).toBeGreaterThan(contrast(t.border, t.bg));
  }
  // The chassis keeps the theme's own background in dark mode and its own page white in light mode.
  expect(deriveTokens(parsePalette(NIGHT)!).chassis).toBe("#1a1b26");
  expect(deriveTokens(parsePalette(LATTE)!).bg).toBe("#eff1f5");
  // An accent too faint for its ground is moved until it reads, not replaced.
  expect(contrast(deriveTokens({ mode: "dark", background: "#121212", foreground: "#bebebe", accent: "#2a2a2a" }).accent, "#121212")).toBeGreaterThanOrEqual(4.45);
  // A declared mode that could not hold readable text is not obeyed blindly.
  const mislabelled = deriveTokens({ mode: "light", background: "#101010", foreground: "#eeeeee", accent: "#e68e0d" });
  expect(contrast(mislabelled.text, mislabelled.bg)).toBeGreaterThan(11);
});

test("state colors never come from a palette key's name", () => {
  const plain = deriveTokens(parsePalette('background = "#121212"\nforeground = "#bebebe"\naccent = "#e68e0d"\n')!);
  const loud = deriveTokens(parsePalette('background = "#121212"\nforeground = "#bebebe"\naccent = "#e68e0d"\nred = "#00ff00"\ngreen = "#ff00ff"\nyellow = "#0000ff"\ncyan = "#ff0000"\nmuted = "#00ffff"\nselection = "#ffff00"\n')!);
  expect(loud).toEqual(plain);
  const neutral = (hex: string) => new Set([hex.slice(1, 3), hex.slice(3, 5), hex.slice(5, 7)]).size === 1;
  for (const name of ["ink", "bg", "chassis", "surface", "hover", "border", "borderLit", "text", "body", "muted", "dim", "live", "liveSoft", "liveLine"] as const) expect(neutral(plain[name])).toBe(true);
  const [r, g, b] = [1, 3, 5].map(at => parseInt(plain.red.slice(at, at + 2), 16));
  expect(r).toBeGreaterThan(g * 1.8);
  expect(r).toBeGreaterThan(b * 1.8);
});

test("the appearance file overrides and clamps, and bad values fall back with a reason", () => {
  expect(parseConfig("")).toEqual({ config: { followSystem: true, accent: null, translucency: 0.94, uiFont: null, monoFont: null }, issues: [] });
  expect(parseConfig('follow_system = false\naccent = "#FA0"\ntranslucency = 0.9\nui_font = "Inter"\nmono_font = "JetBrainsMono Nerd Font"\n')).toEqual({
    config: { followSystem: false, accent: "#ffaa00", translucency: 0.9, uiFont: "Inter", monoFont: "JetBrainsMono Nerd Font" }, issues: [],
  });
  expect(parseConfig("translucency = 0.2").config.translucency).toBe(0.88);
  expect(parseConfig("translucency = 94").config.translucency).toBe(1);
  expect(parseConfig("translucency = 1").config.translucency).toBe(1);
  const bad = parseConfig('follow_system = "maybe"\naccent = "tangerine"\ntranslucency = "glassy"\nui_font = "a; rm -rf ~"\nmono_font = "' + "m".repeat(65) + '"\n');
  expect(bad.config).toEqual({ followSystem: true, accent: null, translucency: 0.94, uiFont: null, monoFont: null });
  expect(bad.issues).toHaveLength(5);
  expect(parseConfig("translucency = -1").issues).toHaveLength(1);

  const { env, setTheme, config } = desktop();
  setTheme("tokyo-night", NIGHT);
  expect(loadAppearance(env).appearance).toMatchObject({ source: "omarchy", theme: "tokyo-night", chassisOpacity: 0.94 });
  config('accent = "#ff8800"\ntranslucency = 0.5\nmono_font = "Iosevka"\n');
  const overridden = loadAppearance(env).appearance;
  expect(overridden).toMatchObject({ source: "omarchy", theme: "tokyo-night", chassisOpacity: 0.88, font: "Adwaita Sans", mono: "Iosevka" });
  expect(overridden.tokens.accent).toBe("#ff8800");
  expect(overridden.tokens.chassis).toBe("#1a1b26");
  config('follow_system = false\naccent = "#ff8800"\n');
  const detached = loadAppearance(env).appearance;
  expect(detached).toMatchObject({ source: "default", theme: null, mode: "dark" });
  expect(detached.tokens.chassis).toBe(DEFAULT_PALETTE.background);
  expect(detached.tokens.accent).toBe("#ff8800");

  // Turning follow_system back on returns to the desktop palette, and a bad file is reported once per change.
  const seen: Appearance[] = [];
  const warnings: string[] = [];
  const watch = watchAppearance(appearance => seen.push(appearance), { env, intervalMs: 60_000, warn: message => warnings.push(message) });
  try {
    config('translucency = "glassy"\n');
    watch.poll(); watch.poll();
    expect(seen.at(-1)).toMatchObject({ source: "omarchy", theme: "tokyo-night", chassisOpacity: 0.94 });
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("translucency");
  } finally { watch.stop(); }
});

test("Theme.qml's built-in colors are the loader's defaults", () => {
  const qml = readFileSync(fileURLToPath(new URL("../Theme.qml", import.meta.url)), "utf8");
  const builtIn = Object.fromEntries([...qml.matchAll(/^\s*property color (\w+): "(#[0-9a-f]{6})"$/gm)].map(match => [match[1], match[2]]));
  expect(builtIn).toEqual(deriveTokens(DEFAULT_PALETTE));
  expect(JSON.parse(/readonly property var tokenNames: (\[[^\]]+\])/.exec(qml)![1])).toEqual([...TOKEN_NAMES]);
  expect(resolveAppearance(null)).toMatchObject({ source: "default", font: /property string font: "([^"]+)"/.exec(qml)![1], mono: /property string mono: "([^"]+)"/.exec(qml)![1] });
  // Saturated green and cyan are gone from the theme and from every control that used to hard-code them.
  expect(qml).not.toMatch(/#33c773|#9fd8e3/i);
  const directory = fileURLToPath(new URL("../", import.meta.url));
  for (const file of ["ActionButton", "BrandMark", "DeckButton", "InputField", "LatticeGrid", "NavRow", "ShellChrome", "SpaceCell", "Tag", "WindowRow", "MissionControlPage", "OperatorConsolePage"])
    expect(readFileSync(join(directory, file + ".qml"), "utf8")).not.toMatch(/"#[0-9a-fA-F]{3,8}"/);
});

test("the QML fixtures are what the loader produces today", () => {
  for (const [key, source] of Object.entries(fixtures.sources) as [keyof typeof fixtures.sources, { name: string; colors: string; config: Record<string, unknown> }][]) {
    const { config } = parseConfig(Object.entries(source.config).map(([name, value]) => `${name} = ${JSON.stringify(value)}`).join("\n"));
    expect(resolveAppearance(parsePalette(source.colors, { name: source.name }), config)).toEqual((fixtures as Record<string, unknown>)[key] as Appearance);
  }
});

const stock = "/usr/share/omarchy/themes";
test.skipIf(!existsSync(stock))("every installed Omarchy theme derives a readable appearance", () => {
  const names = readdirSync(stock).filter(name => existsSync(join(stock, name, "colors.toml")));
  expect(names.length).toBeGreaterThan(0);
  for (const name of names) {
    const palette = parsePalette(readFileSync(join(stock, name, "colors.toml"), "utf8"), { name, lightFile: existsSync(join(stock, name, "light.mode")) });
    expect(palette, name).not.toBeNull();
    const t = deriveTokens(palette!);
    expect(contrast(t.text, t.chassis), name).toBeGreaterThan(11);
    expect(contrast(t.muted, t.chassis), name).toBeGreaterThan(4.5);
    expect(contrast(t.accent, t.chassis), name).toBeGreaterThanOrEqual(4.45);
    expect(contrast(t.accentInk, t.accent), name).toBeGreaterThanOrEqual(4.5);
  }
});

test("the app bridge reports the appearance and follows a theme switch while the host is offline", async () => {
  const { env, setTheme } = desktop();
  setTheme("matte-black", MATTE);
  const closed = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") });
  const port = closed.port;
  closed.stop(true);
  const child = Bun.spawn([process.execPath, fileURLToPath(new URL("../backend.ts", import.meta.url))], {
    stdin: "pipe", stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env, LATTICES_LINUX_PORT: String(port) },
  });
  const messages: Record<string, any>[] = [];
  const listeners = new Set<() => void>();
  const pump = (async () => {
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of child.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        messages.push(JSON.parse(buffer.slice(0, newline)));
        buffer = buffer.slice(newline + 1);
        for (const listener of listeners) listener();
      }
    }
  })();
  const waitFor = (predicate: (message: Record<string, any>) => boolean) => new Promise<Record<string, any>>((resolve, reject) => {
    const timeout = setTimeout(() => { listeners.delete(check); reject(new Error("No matching bridge message")); }, 6000);
    function check() {
      const message = messages.find(predicate);
      if (message) { clearTimeout(timeout); listeners.delete(check); resolve(message); }
    }
    listeners.add(check); check();
  });
  try {
    const first = await waitFor(message => message.type === "appearance");
    expect(first.appearance).toMatchObject({ source: "omarchy", theme: "matte-black", mode: "dark", chassisOpacity: 0.94 });
    expect(Object.keys(first.appearance.tokens).sort()).toEqual([...TOKEN_NAMES].sort());
    await waitFor(message => message.type === "offline");
    setTheme("catppuccin-latte", LATTE);
    const next = await waitFor(message => message.type === "appearance" && message.appearance.theme === "catppuccin-latte");
    expect(next.appearance).toMatchObject({ source: "omarchy", mode: "light" });
    expect(messages.some(message => message.type === "state")).toBe(false);
    // Refresh repeats the appearance for a reloaded shell, with no request ID of its own.
    const before = messages.filter(message => message.type === "appearance").length;
    child.stdin.write(JSON.stringify({ method: "refresh", requestId: "refresh-1" }) + "\n");
    child.stdin.flush();
    await waitFor(() => messages.filter(message => message.type === "appearance").length > before);
    expect(messages.filter(message => message.type === "appearance").every(message => message.requestId === undefined)).toBe(true);
  } finally {
    child.kill();
    await child.exited;
    await pump;
  }
}, 15000);
