// Physical panel size from the kernel's EDID blob. Hyprland's JSON carries no
// reliable millimetres, so the size comes from /sys/class/drm/card*-<connector>/edid,
// read once per request that asks for displays. Missing or unreadable → undefined.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface PhysicalSize { widthMm: number; heightMm: number }

const HEADER = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00];

/**
 * The first detailed timing descriptor's image size (bytes 66/67, high nibbles
 * in 68), falling back to the base block's cm size (bytes 21/22) × 10. A
 * descriptor that disagrees with the base size by more than half (some panels
 * put an aspect ratio or cm there) loses to the base size.
 */
export function parseEdidSize(edid: Uint8Array): PhysicalSize | undefined {
  if (edid.length < 128 || HEADER.some((b, i) => edid[i] !== b)) return undefined;
  const cm = edid[21]! > 0 && edid[22]! > 0 ? { widthMm: edid[21]! * 10, heightMm: edid[22]! * 10 } : undefined;
  // A descriptor with a zero pixel clock is a display descriptor, not a timing.
  const timing = edid[54]! !== 0 || edid[55]! !== 0;
  const w = ((edid[68]! & 0xf0) << 4) | edid[66]!;
  const h = ((edid[68]! & 0x0f) << 8) | edid[67]!;
  if (timing && w > 0 && h > 0) {
    const plausible = !cm || (Math.abs(w - cm.widthMm) <= cm.widthMm / 2 && Math.abs(h - cm.heightMm) <= cm.heightMm / 2);
    if (plausible) return { widthMm: w, heightMm: h };
  }
  return cm;
}

/** The size behind a DRM connector name (Hyprland's monitor `name`, e.g. HDMI-A-1). */
export function edidSize(connector: string, root = "/sys/class/drm"): PhysicalSize | undefined {
  try {
    const entry = readdirSync(root).find((d) => /^card\d+-/.test(d) && d.slice(d.indexOf("-") + 1) === connector);
    return entry ? parseEdidSize(readFileSync(join(root, entry, "edid"))) : undefined;
  } catch {
    return undefined;
  }
}
