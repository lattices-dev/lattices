// Physical monitor identity and DDC/CI input source (VCP 0x60) via ddcutil.
// One monitor can be cabled to several hosts; the key below matches the same
// panel across hosts, and VCP 0x60 says which input is on screen. Each call
// does one read or one write: no polling, no background loops.

import { hasCommand, run } from "./exec.ts";

export interface MonitorIdentity {
  make: string;
  model: string;
  serial: string;
  key: string;
  /** Physical image size from EDID; omitted when the panel doesn't report one. */
  widthMm?: number;
  heightMm?: number;
}

export interface InputSource { code: number; name: string }

/** lowercase(trim(model)) | lowercase(trim(serial)); both hosts read the same EDID strings. */
export function monitorKey(model: string, serial: string): string {
  return `${model.trim().toLowerCase()}|${serial.trim().toLowerCase()}`;
}

/** Identity for a real panel; undefined without both a model and a serial (headless, some built-ins). */
export function monitorIdentity(m: { make?: string; model?: string; serial?: string }): MonitorIdentity | undefined {
  const model = m.model?.trim() ?? "";
  const serial = m.serial?.trim() ?? "";
  if (!model || !serial) return undefined;
  return { make: m.make?.trim() ?? "", model, serial, key: monitorKey(model, serial) };
}

const INPUT_NAMES: Record<number, string> = {
  0x01: "VGA-1", 0x03: "DVI-1", 0x0f: "DP-1", 0x10: "DP-2", 0x11: "HDMI-1", 0x12: "HDMI-2", 0x1b: "USB-C",
};

/** MCCS input name; the value is masked to its low byte (some monitors set high bits). */
export function inputSource(value: number): InputSource {
  const code = value & 0xff;
  return { code, name: INPUT_NAMES[code] ?? `Input 0x${code.toString(16).padStart(2, "0")}` };
}

export interface Detected { bus: number; connector: string | null; make: string; model: string; serial: string; key: string }

/**
 * `ddcutil detect --terse` blocks: "Display N", "I2C bus: /dev/i2c-N",
 * "DRM connector: card1-HDMI-A-1", "Monitor: MFG:MODEL:SERIAL". "Invalid
 * display" blocks and monitors without a serial are skipped.
 */
export function parseDetect(text: string): Detected[] {
  const found: Detected[] = [];
  for (const block of text.split(/\n(?=\S)/)) {
    if (!/^Display \d+/.test(block)) continue;
    const bus = /I2C bus:\s*\/dev\/i2c-(\d+)/.exec(block)?.[1];
    const monitor = /Monitor:\s*(.+)/.exec(block)?.[1]?.trim();
    if (bus === undefined || !monitor) continue;
    // Model may contain spaces; the manufacturer id and serial don't contain colons.
    const first = monitor.indexOf(":");
    const last = monitor.lastIndexOf(":");
    if (first < 0 || last <= first) continue;
    const identity = monitorIdentity({ make: monitor.slice(0, first), model: monitor.slice(first + 1, last), serial: monitor.slice(last + 1) });
    if (!identity) continue;
    const connector = /DRM connector:\s*(\S+)/.exec(block)?.[1] ?? null;
    found.push({ bus: Number(bus), connector, ...identity });
  }
  return found;
}

/** `getvcp 60 --terse`: "VCP 60 SNC x12". Null for anything else (unsupported, error). */
export function parseGetVcp(text: string): InputSource | null {
  const match = /^VCP 60 SNC x([0-9a-f]+)\s*$/im.exec(text);
  return match ? inputSource(Number.parseInt(match[1]!, 16)) : null;
}

/** Input codes listed under 60(...) inside the capabilities string's vcp(...) section. */
export function parseCapabilities(text: string): InputSource[] {
  const raw = /capabilities string:\s*(.*)/i.exec(text)?.[1] ?? text;
  const start = raw.indexOf("vcp(");
  if (start < 0) return [];
  // Walk the vcp section at depth 1 so codes inside other features' value lists never match.
  let depth = 0;
  let token = "";
  for (let i = start + 4; i < raw.length; i++) {
    const c = raw[i]!;
    if (c === "(") {
      if (depth === 0 && token.trim().toUpperCase() === "60") {
        const end = raw.indexOf(")", i);
        if (end < 0) return [];
        const codes = raw.slice(i + 1, end).trim().split(/\s+/).filter((v) => /^[0-9a-f]{1,2}$/i.test(v));
        return [...new Map(codes.map((v) => {
          const source = inputSource(Number.parseInt(v, 16));
          return [source.code, source] as const;
        })).values()];
      }
      depth++;
      token = "";
    } else if (c === ")") {
      if (depth === 0) return [];
      depth--;
      token = "";
    } else if (/\s/.test(c)) {
      token = "";
    } else if (depth === 0) {
      token += c;
    }
  }
  return [];
}

export interface DdcDeps {
  available: () => boolean;
  ddcutil: (args: string[]) => Promise<string>;
  now: () => number;
}

const DETECT_TTL_MS = 60_000;

export function ddcService(deps: DdcDeps) {
  let cache: { at: number; displays: Detected[] } | null = null;
  // A monitor's input list doesn't change; it is read once per bus while detect is fresh.
  const inputLists = new Map<number, InputSource[]>();
  // One ddcutil at a time: concurrent calls would race on the same I2C bus
  // (a get interleaved with a set) and run the slow detect twice.
  let queue: Promise<unknown> = Promise.resolve();
  const ddcutil = (args: string[]): Promise<string> => {
    const next = queue.then(() => deps.ddcutil(args));
    queue = next.catch(() => {});
    return next;
  };
  let detecting: Promise<Detected[]> | null = null;
  // detect is slow on hosts with many buses; one result serves for a minute.
  const detect = async (fresh = false): Promise<Detected[]> => {
    if (!fresh && cache && deps.now() - cache.at < DETECT_TTL_MS) return cache.displays;
    if (detecting) return detecting;
    detecting = (async () => {
      try {
        const displays = parseDetect(await ddcutil(["detect", "--terse"]));
        inputLists.clear();
        cache = { at: deps.now(), displays };
        return displays;
      } finally { detecting = null; }
    })();
    return detecting;
  };
  const busFor = async (key: string, fresh = false): Promise<number | null> => {
    if (!deps.available()) return null;
    try { return (await detect(fresh)).find((d) => d.key === key.trim().toLowerCase())?.bus ?? null; }
    catch { return null; }
  };
  // A failed call may mean the monitor moved bus; the next call re-detects.
  const forget = () => { cache = null; inputLists.clear(); };
  return {
    detect,
    /** ddc:false when ddcutil is missing, the monitor isn't on an I2C bus, or the read fails. */
    async get(key: string) {
      const bus = await busFor(key);
      if (bus === null) return { key, ddc: false, input: null, inputs: [] as InputSource[] };
      let input: InputSource | null;
      try { input = parseGetVcp(await ddcutil(["getvcp", "60", "--bus", String(bus), "--terse"])); }
      catch { forget(); return { key, ddc: false, input: null, inputs: [] as InputSource[] }; }
      let inputs = inputLists.get(bus);
      if (!inputs) {
        try { inputs = parseCapabilities(await ddcutil(["capabilities", "--bus", String(bus), "--terse"])); inputLists.set(bus, inputs); }
        catch { inputs = []; /* capabilities are optional */ }
      }
      return { key, ddc: input !== null, input, inputs };
    },
    /**
     * Writes VCP 0x60. Only ever called from an explicit user request. Detect
     * runs fresh first: a cached bus could now belong to another monitor, and
     * a write must never switch the wrong panel.
     */
    async set(key: string, code: number) {
      const bus = await busFor(key, true);
      if (bus === null) return { ok: false, input: null };
      const target = inputSource(code);
      try { await ddcutil(["setvcp", "60", `0x${target.code.toString(16).padStart(2, "0")}`, "--bus", String(bus)]); }
      catch { forget(); return { ok: false, input: null }; }
      return { ok: true, input: target };
    },
  };
}

const service = ddcService({
  available: () => hasCommand("ddcutil"),
  ddcutil: (args) => run("ddcutil", args, { timeoutMs: 15_000 }),
  now: Date.now,
});
export const getInput = service.get;
export const setInput = service.set;
