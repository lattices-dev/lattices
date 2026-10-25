/**
 * Viewport sizing for Action Browser.
 *
 * Two different things can be "resized", and they are not interchangeable:
 *
 *   target=tab     CSS emulation for one tab (Emulation.setDeviceMetricsOverride).
 *                  Exact, per-tab, invisible to every other tab, and reversible.
 *                  It lives on the CDP client session, so it dies the moment the
 *                  socket closes -- which is why ViewportSessions retains its
 *                  owning connection across tool calls, until reset or release.
 *
 *   target=window  The real Chrome window that hosts the tab (Browser.setWindowBounds).
 *                  Durable because it is OS window state rather than session state,
 *                  but it moves every tab in that window and the OS may clamp it.
 *
 * Everything here is pure so the argument contract can be tested without Chrome.
 */

export type ViewportTarget = "tab" | "window";

export type ViewportOverride = {
  width: number;
  height: number;
  deviceScaleFactor: number;
  mobile: boolean;
};

export type ResizeRequest =
  | { kind: "reset"; target: ViewportTarget; matchMedia: string[] }
  | { kind: "set"; target: ViewportTarget; viewport: ViewportOverride; matchMedia: string[] };

/** Narrow enough for a phone breakpoint, wide enough for a 5K desktop layout. */
export const MIN_VIEWPORT_EDGE = 120;
export const MAX_VIEWPORT_EDGE = 8192;
export const MIN_DEVICE_SCALE_FACTOR = 0.5;
export const MAX_DEVICE_SCALE_FACTOR = 4;

/** Matches the --window-size Chrome is launched with, so target=window reset is a real restore. */
export const DEFAULT_WINDOW_SIZE = { width: 1440, height: 1000 } as const;

export function viewportTarget(value: unknown): ViewportTarget {
  if (value === undefined || value === "tab") return "tab";
  if (value === "window") return "window";
  throw new Error("target must be either tab or window.");
}

function requireEdge(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${label} is required and must be a number of CSS pixels.`);
  }
  if (!Number.isInteger(value)) {
    throw new Error(`${label} must be a whole number of CSS pixels, not ${value}.`);
  }
  if (value < MIN_VIEWPORT_EDGE || value > MAX_VIEWPORT_EDGE) {
    throw new Error(
      `${label} must be between ${MIN_VIEWPORT_EDGE} and ${MAX_VIEWPORT_EDGE} CSS pixels, not ${value}.`,
    );
  }
  return value;
}

function requireScaleFactor(value: unknown): number {
  if (value === undefined) return 1;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error("deviceScaleFactor must be a number.");
  }
  if (value < MIN_DEVICE_SCALE_FACTOR || value > MAX_DEVICE_SCALE_FACTOR) {
    throw new Error(
      `deviceScaleFactor must be between ${MIN_DEVICE_SCALE_FACTOR} and ${MAX_DEVICE_SCALE_FACTOR}, not ${value}.`,
    );
  }
  return value;
}

function requireMatchMedia(value: unknown): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string" || !entry.trim())) {
    throw new Error("matchMedia must be an array of non-empty media query strings.");
  }
  return (value as string[]).map((entry) => entry.trim());
}

export function parseResizeRequest(args: Record<string, unknown>): ResizeRequest {
  const target = viewportTarget(args.target);
  const matchMedia = requireMatchMedia(args.matchMedia);
  const emulationOnly = args.deviceScaleFactor !== undefined || args.mobile !== undefined;
  if (target === "window" && emulationOnly) {
    throw new Error(
      "deviceScaleFactor and mobile only apply to target=tab, which resizes the page through CSS emulation.",
    );
  }

  if (args.reset === true) {
    if (args.width !== undefined || args.height !== undefined) {
      throw new Error("reset cannot be combined with width or height; send one or the other.");
    }
    return { kind: "reset", target, matchMedia };
  }

  if (typeof args.mobile !== "undefined" && typeof args.mobile !== "boolean") {
    throw new Error("mobile must be a boolean.");
  }

  return {
    kind: "set",
    target,
    matchMedia,
    viewport: {
      width: requireEdge(args.width, "width"),
      height: requireEdge(args.height, "height"),
      deviceScaleFactor: requireScaleFactor(args.deviceScaleFactor),
      mobile: args.mobile === true,
    },
  };
}

/**
 * A coarse label for the requested width. Advisory only -- a caller verifying its
 * own breakpoints should pass matchMedia and read the answers rather than trust this.
 */
export function widthClass(width: number): string {
  if (width < 480) return "mobile";
  if (width < 768) return "large-mobile";
  if (width < 1024) return "tablet";
  if (width < 1440) return "small-desktop";
  return "desktop";
}

/**
 * Chrome and macOS can both refuse an exact size: a window cannot exceed the
 * display, and a page with a hard min-width keeps its own layout width. Report the
 * gap instead of letting a caller believe it verified a breakpoint it never reached.
 */
export function measureDrift(
  requested: { width: number; height: number },
  measured: { width: number; height: number },
): { exact: boolean; widthDelta: number; heightDelta: number } {
  const widthDelta = measured.width - requested.width;
  const heightDelta = measured.height - requested.height;
  return { exact: widthDelta === 0 && heightDelta === 0, widthDelta, heightDelta };
}

/** Window bounds carry the tab strip and omnibox; the caller asked about the page. */
export function windowBoundsFor(
  viewport: { width: number; height: number },
  chromeInset: { width: number; height: number },
): { width: number; height: number } {
  return {
    width: Math.max(MIN_VIEWPORT_EDGE, Math.round(viewport.width + chromeInset.width)),
    height: Math.max(MIN_VIEWPORT_EDGE, Math.round(viewport.height + chromeInset.height)),
  };
}
