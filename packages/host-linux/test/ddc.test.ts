import { describe, expect, test } from "bun:test";
import { ddcService, inputSource, monitorIdentity, monitorKey, parseCapabilities, parseDetect, parseGetVcp } from "../src/ddc.ts";
import { toDisplays } from "../src/desktop.ts";
import type { HyprMonitor } from "../src/hyprland.ts";

// Captured from archie (ddcutil 2.2.7, Dell AW3425DWM on HDMI-A-1), 2026-10-21.
const DETECT = `Display 1
   I2C bus:          /dev/i2c-2
   DRM connector:    card1-HDMI-A-1
   drm_connector_id: 402
   Monitor:          DEL:AW3425DWM:JWLC444

Invalid display
   I2C bus:          /dev/i2c-5
   DRM connector:    card1-DP-2
   Monitor:          SAM:U32J59x:HCRY300398

Display 2
   I2C bus:          /dev/i2c-7
   DRM connector:    card1-DP-1
   Monitor:          DEL:DELL S3422DWG:3KN2KK3
`;
const CAPABILITIES = "Unparsed capabilities string: (prot(monitor)type(LCD)model(AW3425DWM)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 05 08 0B 0C) 16 18 1A 52 60(0F 11 12 ) 87 AC AE B2 B6 C8 C9 CA CC(02 0A 03 04 0E 09 0D 06 ) D6(01 04 05) DC(00 05 ) DF E0(03) E2(00 22 20 21 0E 12 0B 14 27 23 24 3A ) E3 E5 E8 E9(00 01 02 21 22 24 29 2A 2D 2E ) EA(FE ) F0(0F 10 11 31 32 34 36 ) EC(FF02) ED(0400 0800 03FF) F1 F2 F4(10 11 12 13 14 15 16 17 20 21 22 30 31 32 33 40 41 42 43 45 44 70 80 90 B0 ) F5( 100 500 800 900 A00 C02 C03) FD)mswhql(1)asset_eep(40)mccs_ver(2.1))\n";

describe("monitor identity", () => {
  test("key is lowercased, trimmed model|serial, matching the Mac side", () => {
    expect(monitorKey("AW3425DWM", "JWLC444")).toBe("aw3425dwm|jwlc444");
    expect(monitorKey(" U32J59x ", "HCRY300398")).toBe("u32j59x|hcry300398");
    expect(monitorKey("DELL S3422DWG", "3KN2KK3 ")).toBe("dell s3422dwg|3kn2kk3");
  });

  test("headless outputs and panels without a serial have no identity", () => {
    expect(monitorIdentity({ make: "", model: "", serial: "" })).toBeUndefined();
    expect(monitorIdentity({ make: "BOE", model: "0x0BCA", serial: "" })).toBeUndefined();
    expect(monitorIdentity({ make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444" }))
      .toEqual({ make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444", key: "aw3425dwm|jwlc444" });
  });

  test("toDisplays carries the identity on real panels only", () => {
    const base = { id: 0, description: "", x: 0, y: 0, width: 3440, height: 1440, scale: 1, transform: 0, reserved: [0, 0, 0, 0], activeWorkspace: { id: 1, name: "1" }, focused: true } as const;
    const real = { ...base, name: "HDMI-A-1", description: "Dell Inc. AW3425DWM JWLC444", make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444" } as HyprMonitor;
    const headless = { ...base, id: 1, name: "LATS-1", x: 3440, make: "", model: "", serial: "" } as HyprMonitor;
    const [d, v] = toDisplays([real, headless], []);
    expect(d!.monitor?.key).toBe("aw3425dwm|jwlc444");
    expect(v!.virtual).toBe(true);
    expect("monitor" in v!).toBe(false);
  });
});

describe("ddcutil parsing", () => {
  test("detect maps valid displays to buses and keys", () => {
    expect(parseDetect(DETECT)).toEqual([
      { bus: 2, connector: "card1-HDMI-A-1", make: "DEL", model: "AW3425DWM", serial: "JWLC444", key: "aw3425dwm|jwlc444" },
      { bus: 7, connector: "card1-DP-1", make: "DEL", model: "DELL S3422DWG", serial: "3KN2KK3", key: "dell s3422dwg|3kn2kk3" },
    ]);
  });

  test("getvcp 60 --terse, masked to the low byte", () => {
    expect(parseGetVcp("VCP 60 SNC x12\n")).toEqual({ code: 0x12, name: "HDMI-2" });
    expect(parseGetVcp("VCP 60 SNC x0f")).toEqual({ code: 0x0f, name: "DP-1" });
    expect(parseGetVcp("VCP 60 SNC x0111")).toEqual({ code: 0x11, name: "HDMI-1" });
    expect(parseGetVcp("VCP 60 ERR")).toBeNull();
    expect(parseGetVcp("No monitor detected on bus /dev/i2c-7")).toBeNull();
  });

  test("input names follow MCCS, unknown codes in hex", () => {
    expect(inputSource(0x1b).name).toBe("USB-C");
    expect(inputSource(0x0d).name).toBe("Input 0x0d");
  });

  test("capabilities list only the inputs under feature 60", () => {
    expect(parseCapabilities(CAPABILITIES)).toEqual([
      { code: 0x0f, name: "DP-1" }, { code: 0x11, name: "HDMI-1" }, { code: 0x12, name: "HDMI-2" },
    ]);
    expect(parseCapabilities("Unparsed capabilities string: (vcp(10 12 F0(60 11)))")).toEqual([]);
    expect(parseCapabilities("garbage")).toEqual([]);
  });
});

describe("ddc service", () => {
  const fixture = (over: Partial<Parameters<typeof ddcService>[0]> = {}) => {
    const calls: string[][] = [];
    let now = 0;
    const service = ddcService({
      available: () => true,
      ddcutil: async (args) => {
        calls.push(args);
        if (args[0] === "detect") return DETECT;
        if (args[0] === "getvcp") return "VCP 60 SNC x12\n";
        if (args[0] === "capabilities") return CAPABILITIES;
        return "";
      },
      now: () => now,
      ...over,
    });
    return { service, calls, advance: (ms: number) => { now += ms; } };
  };

  test("get reads one bus and caches detect and capabilities for a minute", async () => {
    const { service, calls, advance } = fixture();
    const result = await service.get("AW3425DWM|JWLC444");
    expect(result).toEqual({ key: "AW3425DWM|JWLC444", ddc: true, input: { code: 0x12, name: "HDMI-2" }, inputs: [{ code: 0x0f, name: "DP-1" }, { code: 0x11, name: "HDMI-1" }, { code: 0x12, name: "HDMI-2" }] });
    expect(calls).toContainEqual(["getvcp", "60", "--bus", "2", "--terse"]);
    await service.get("aw3425dwm|jwlc444");
    expect(calls.filter((c) => c[0] === "detect")).toHaveLength(1);
    expect(calls.filter((c) => c[0] === "capabilities")).toHaveLength(1);
    advance(60_000);
    await service.get("aw3425dwm|jwlc444");
    expect(calls.filter((c) => c[0] === "detect")).toHaveLength(2);
  });

  test("unknown monitor, missing ddcutil or a failed read is ddc:false, not an error", async () => {
    const off = { ddc: false, input: null, inputs: [] };
    expect(await fixture().service.get("u32j59x|hcry300398")).toEqual({ key: "u32j59x|hcry300398", ...off });
    expect(await fixture({ available: () => false }).service.get("aw3425dwm|jwlc444")).toMatchObject(off);
    expect(await fixture({ ddcutil: async () => { throw new Error("ddcutil: Permission denied"); } }).service.get("aw3425dwm|jwlc444")).toMatchObject(off);
  });

  test("set writes VCP 60 on the monitor's bus", async () => {
    const { service, calls } = fixture();
    expect(await service.set("aw3425dwm|jwlc444", 0x0f)).toEqual({ ok: true, input: { code: 0x0f, name: "DP-1" } });
    expect(calls).toContainEqual(["setvcp", "60", "0x0f", "--bus", "2"]);
    expect(await service.set("nope|nope", 0x0f)).toEqual({ ok: false, input: null });
  });

  test("set re-detects first, so a stale cached bus never gets the write", async () => {
    let detect = DETECT;
    const { service, calls } = fixture({
      ddcutil: async (args) => { calls.push(args); return args[0] === "detect" ? detect : args[0] === "getvcp" ? "VCP 60 SNC x12" : ""; },
    });
    await service.get("aw3425dwm|jwlc444");
    // The Dell moved from bus 2 to bus 9 within the detect TTL.
    detect = DETECT.replace("/dev/i2c-2", "/dev/i2c-9");
    await service.set("aw3425dwm|jwlc444", 0x11);
    expect(calls.filter((c) => c[0] === "setvcp")).toEqual([["setvcp", "60", "0x11", "--bus", "9"]]);
  });

  test("ddcutil runs one call at a time and concurrent gets share one detect", async () => {
    let active = 0;
    let peak = 0;
    const { service, calls } = fixture({
      ddcutil: async (args) => {
        calls.push(args);
        active++; peak = Math.max(peak, active);
        await new Promise((r) => setTimeout(r, 5));
        active--;
        return args[0] === "detect" ? DETECT : args[0] === "getvcp" ? "VCP 60 SNC x12" : CAPABILITIES;
      },
    });
    const [a, b] = await Promise.all([service.get("aw3425dwm|jwlc444"), service.get("dell s3422dwg|3kn2kk3")]);
    expect(a.ddc && b.ddc).toBe(true);
    expect(peak).toBe(1);
    expect(calls.filter((c) => c[0] === "detect")).toHaveLength(1);
  });

  test("a failed read drops the detect cache", async () => {
    let fail = true;
    const { service, calls } = fixture({
      ddcutil: async (args) => {
        calls.push(args);
        if (args[0] === "detect") return DETECT;
        if (fail) throw new Error("ddcutil: No monitor detected");
        return "VCP 60 SNC x12";
      },
    });
    expect((await service.get("aw3425dwm|jwlc444")).ddc).toBe(false);
    fail = false;
    expect((await service.get("aw3425dwm|jwlc444")).ddc).toBe(true);
    expect(calls.filter((c) => c[0] === "detect")).toHaveLength(2);
  });
});
