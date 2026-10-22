import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { edidSize, parseEdidSize } from "../src/edid.ts";
import { toDisplays } from "../src/desktop.ts";
import type { HyprMonitor } from "../src/hyprland.ts";

/** A 128-byte base block: header, cm size at 21/22, first timing descriptor at 54. */
function edid({ cm = [80, 34], mm = [800, 335], clock = 0x1234 }: { cm?: number[]; mm?: number[]; clock?: number } = {}) {
  const b = new Uint8Array(128);
  b.set([0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]);
  b[21] = cm[0]!; b[22] = cm[1]!;
  b[54] = clock & 0xff; b[55] = clock >> 8;
  b[66] = mm[0]! & 0xff; b[67] = mm[1]! & 0xff;
  b[68] = ((mm[0]! >> 8) << 4) | (mm[1]! >> 8);
  return b;
}

describe("EDID physical size", () => {
  test("first detailed timing descriptor, high nibbles included", () => {
    expect(parseEdidSize(edid())).toEqual({ widthMm: 800, heightMm: 335 });
    expect(parseEdidSize(edid({ cm: [0, 0], mm: [1872, 1053] }))).toEqual({ widthMm: 1872, heightMm: 1053 });
  });

  test("falls back to the base block's cm size", () => {
    expect(parseEdidSize(edid({ mm: [0, 0] }))).toEqual({ widthMm: 800, heightMm: 340 });
    expect(parseEdidSize(edid({ clock: 0 }))).toEqual({ widthMm: 800, heightMm: 340 });
    // An aspect ratio or cm in the descriptor disagrees with the base size.
    expect(parseEdidSize(edid({ mm: [16, 9] }))).toEqual({ widthMm: 800, heightMm: 340 });
  });

  test("unsized, short or headerless blobs have no size", () => {
    expect(parseEdidSize(edid({ cm: [0, 0], mm: [0, 0] }))).toBeUndefined();
    expect(parseEdidSize(edid({ cm: [70, 0], mm: [0, 0] }))).toBeUndefined();
    expect(parseEdidSize(new Uint8Array(0))).toBeUndefined();
    expect(parseEdidSize(edid().slice(0, 100))).toBeUndefined();
    const bad = edid(); bad[0] = 0x01;
    expect(parseEdidSize(bad)).toBeUndefined();
  });

  test("reads the connector's sysfs edid; missing or empty means undefined", () => {
    const root = mkdtempSync(join(tmpdir(), "lats-edid-"));
    try {
      mkdirSync(join(root, "card1-HDMI-A-1"));
      writeFileSync(join(root, "card1-HDMI-A-1", "edid"), edid());
      mkdirSync(join(root, "card1-DP-1"));
      writeFileSync(join(root, "card1-DP-1", "edid"), new Uint8Array(0));
      mkdirSync(join(root, "card1-HDMI-A-10"));
      writeFileSync(join(root, "card1-HDMI-A-10", "edid"), edid({ mm: [700, 400], cm: [70, 40] }));
      expect(edidSize("HDMI-A-1", root)).toEqual({ widthMm: 800, heightMm: 335 });
      expect(edidSize("HDMI-A-10", root)).toEqual({ widthMm: 700, heightMm: 400 });
      expect(edidSize("DP-1", root)).toBeUndefined();
      expect(edidSize("DP-2", root)).toBeUndefined();
      expect(edidSize("HDMI-A-1", join(root, "missing"))).toBeUndefined();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("toDisplays puts the size on the identity, never on headless outputs", () => {
    const base = { id: 0, description: "", x: 0, y: 0, width: 3440, height: 1440, scale: 1, transform: 0, reserved: [0, 0, 0, 0], activeWorkspace: { id: 1, name: "1" }, focused: true } as const;
    const real = { ...base, name: "HDMI-A-1", make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444" } as HyprMonitor;
    const unsized = { ...base, id: 2, name: "DP-1", x: 6880, make: "Samsung", model: "U32J59x", serial: "HCRY300398" } as HyprMonitor;
    const headless = { ...base, id: 1, name: "LATS-1", x: 3440, make: "", model: "", serial: "" } as HyprMonitor;
    const asked: string[] = [];
    const sizes = (c: string) => { asked.push(c); return c === "HDMI-A-1" ? { widthMm: 800, heightMm: 335 } : undefined; };
    const [d, v, u] = toDisplays([real, headless, unsized], [], sizes);
    expect(d!.monitor).toEqual({ make: "Dell Inc.", model: "AW3425DWM", serial: "JWLC444", key: "aw3425dwm|jwlc444", widthMm: 800, heightMm: 335 });
    expect("monitor" in v!).toBe(false);
    expect(u!.monitor?.key).toBe("u32j59x|hcry300398");
    expect("widthMm" in u!.monitor!).toBe(false);
    expect(asked).toEqual(["HDMI-A-1", "DP-1"]);
  });
});
