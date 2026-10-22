/**
 * The hero desktop's windows, in one place.
 *
 * The desktop belongs to "tideline", a made-up tide-chart app: its tmux
 * session (a claude pane beside a `bun dev` pane), the page in Safari, and the
 * file being fixed in Zed. The placed phase is what `lats place tideline
 * right` does to the scattered desktop: deep search ranks the Terminal first,
 * so it moves to the right half. The organized phase is the project's layer:
 * session on the left half, browser and editor stacked on the right.
 *
 * Everything that describes this desktop reads from here: the styled windows
 * and the search transcript in `LandingPage`, and the `lattices map` text
 * below. The map is rasterised from these same percentages, so the two can
 * not disagree about where a window is.
 */
import {
  assertBoxGrid,
  buildBoxGrid,
  gridToText,
  rectFromPercent,
  type BoxGrid,
  type BoxRect,
} from "../lib/asciiBoxMap";

export type HeroDesktopPhase = "messy" | "placed" | "organized";
export type HeroWindowId = "session" | "browser" | "editor";

export type HeroWindowLayout = {
  left: number;
  top: number;
  width: number;
  height: number;
  z: number;
};

/** The layer ⌘⌥1 switches to, as the layer bezel reports it. */
export const heroLayer = { name: "tideline", index: 0, total: 3 };

export const heroWindowLayouts: Record<HeroWindowId, Record<HeroDesktopPhase, HeroWindowLayout>> = {
  session: {
    messy: { left: 26, top: 25, width: 42, height: 60, z: 6 },
    placed: { left: 50.25, top: 5.2, width: 49.25, height: 93.8, z: 6 },
    organized: { left: 0.5, top: 5.2, width: 49.25, height: 93.8, z: 6 },
  },
  browser: {
    messy: { left: 50, top: 10, width: 44, height: 50, z: 2 },
    placed: { left: 50, top: 10, width: 44, height: 50, z: 2 },
    organized: { left: 50.25, top: 5.2, width: 49.25, height: 46.3, z: 2 },
  },
  editor: {
    messy: { left: 5, top: 13, width: 37, height: 44, z: 3 },
    placed: { left: 5, top: 13, width: 37, height: 44, z: 3 },
    organized: { left: 50.25, top: 52.7, width: 49.25, height: 46.3, z: 3 },
  },
};

export const heroWindowMeta: Record<
  HeroWindowId,
  { app: string; title: string; wid: number; focused?: boolean; mapLabel: string }
> = {
  session: {
    app: "Terminal",
    title: "[lattices:tideline-5e354e] claude",
    wid: 4127,
    focused: true,
    mapLabel: "1 Terminal · tideline",
  },
  browser: { app: "Safari", title: "Tideline · Half Moon Bay", wid: 4129, mapLabel: "3 Safari · Tideline" },
  editor: { app: "Zed", title: "format.ts — tideline", wid: 4131, mapLabel: "2 Zed · format.ts" },
};

const heroWindowIds = Object.keys(heroWindowLayouts) as HeroWindowId[];

function overlaps(a: HeroWindowLayout, b: HeroWindowLayout) {
  return a.left < b.left + b.width && b.left < a.left + a.width && a.top < b.top + b.height && b.top < a.top + a.height;
}

/** Pairs of windows that cover part of each other, per phase. */
export const heroOverlapCount: Record<HeroDesktopPhase, number> = {
  messy: countOverlaps("messy"),
  placed: countOverlaps("placed"),
  organized: countOverlaps("organized"),
};

function countOverlaps(phase: HeroDesktopPhase) {
  let count = 0;
  heroWindowIds.forEach((id, index) => {
    for (const other of heroWindowIds.slice(index + 1)) {
      if (overlaps(heroWindowLayouts[id][phase], heroWindowLayouts[other][phase])) count++;
    }
  });
  return count;
}

/** Character dimensions of the rendered map, including the display border. */
const MAP_WIDTH = 68;
const MAP_HEIGHT = 15;

/** The area inside the display border that windows are placed into. */
const SCREEN_AREA = { x: 1, y: 1, w: MAP_WIDTH - 2, h: MAP_HEIGHT - 2 };

const DISPLAY_LABEL = " Display 0 · MacBook Pro · Space 1";

function buildHeroDesktopGrid(phase: HeroDesktopPhase): BoxGrid {
  const windows = heroWindowIds.map((id) => {
    const frame = heroWindowLayouts[id][phase];
    return rectFromPercent(frame, SCREEN_AREA, { label: heroWindowMeta[id].mapLabel, z: frame.z });
  });

  const display: BoxRect = { x: 0, y: 0, w: MAP_WIDTH, h: MAP_HEIGHT, label: DISPLAY_LABEL, z: -1 };

  return assertBoxGrid(buildBoxGrid([display, ...windows], MAP_WIDTH, MAP_HEIGHT), `hero desktop map "${phase}"`);
}

export const heroDesktopGrids: Record<HeroDesktopPhase, BoxGrid> = {
  messy: buildHeroDesktopGrid("messy"),
  placed: buildHeroDesktopGrid("placed"),
  organized: buildHeroDesktopGrid("organized"),
};

export const heroDesktopMaps: Record<HeroDesktopPhase, string> = {
  messy: gridToText(heroDesktopGrids.messy),
  placed: gridToText(heroDesktopGrids.placed),
  organized: gridToText(heroDesktopGrids.organized),
};

/**
 * What `lats search tideline --deep` prints for this desktop, ranked the way
 * `search.query` scores it: title +3, session +3, cwd +3, tmux +3, plus a
 * recency boost (+4 for the frontmost window, +3 within five minutes, +2
 * within the hour). The top result is the window `lats place` moves.
 */
export const heroSearchResults: Array<{
  id: HeroWindowId;
  score: number;
  reasons: string[];
  tab?: { cwd: string; tmux: string };
}> = [
  { id: "session", score: 16, reasons: ["title", "session", "cwd", "tmux"], tab: { cwd: "~/dev/tideline", tmux: "tideline-5e354e" } },
  { id: "editor", score: 6, reasons: ["title"] },
  { id: "browser", score: 5, reasons: ["title"] },
];
