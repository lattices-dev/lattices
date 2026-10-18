/**
 * The tide chart in the hero desktop's Safari window: tideline's view of
 * Half Moon Bay on the morning the desktop is set, 9:41 AM.
 *
 * The curve runs through these highs and lows with a half-cosine between each
 * pair, the way tide tables are usually interpolated. The labels, the curve and
 * the "now" reading all come from the same extremes, so a label always sits on
 * the peak or trough it names.
 */

export type TideExtreme = { kind: "High" | "Low"; minute: number; feet: number };

const DAY = 24 * 60;

/**
 * Minutes after midnight. The first and last fall outside the day, so the
 * curve runs edge to edge; the last is tomorrow's first high.
 */
export const tideExtremes: TideExtreme[] = [
  { kind: "Low", minute: -60, feet: 2.2 },
  { kind: "High", minute: 5 * 60 + 12, feet: 6.1 },
  { kind: "Low", minute: 11 * 60 + 24, feet: 0.4 },
  { kind: "High", minute: 17 * 60 + 36, feet: 5.4 },
  { kind: "Low", minute: 23 * 60 + 48, feet: 2.1 },
  { kind: "High", minute: DAY + 6 * 60 + 3, feet: 5.9 },
];

const nowMinute = 9 * 60 + 41;

export function tideHeight(minute: number) {
  const next = tideExtremes.findIndex((extreme) => extreme.minute >= minute);
  if (next === 0) return tideExtremes[0].feet;
  if (next === -1) return tideExtremes[tideExtremes.length - 1].feet;
  const from = tideExtremes[next - 1];
  const to = tideExtremes[next];
  const t = (minute - from.minute) / (to.minute - from.minute);
  return from.feet + ((to.feet - from.feet) * (1 - Math.cos(Math.PI * t))) / 2;
}

export function formatTideTime(minute: number) {
  const time = ((minute % DAY) + DAY) % DAY;
  const hour = Math.floor(time / 60);
  return `${hour % 12 || 12}:${String(time % 60).padStart(2, "0")} ${hour < 12 ? "AM" : "PM"}`;
}

/** The chart's range in feet, top to bottom. Leaves room for labels above the highs and below the lows. */
const FEET_TOP = 8.2;
const FEET_BOTTOM = -1.6;

/** Where a moment sits on the chart: x runs 0–100 across the day, y 0–100 from the top. */
export function tidePoint(minute: number) {
  return {
    x: (minute / DAY) * 100,
    y: ((FEET_TOP - tideHeight(minute)) / (FEET_TOP - FEET_BOTTOM)) * 100,
  };
}

/** The day's curve, and the same curve closed along the bottom for the water fill. */
export const tidePaths = (() => {
  const points: string[] = [];
  for (let minute = 0; minute <= DAY; minute += 12) {
    const { x, y } = tidePoint(minute);
    points.push(`${x.toFixed(2)} ${y.toFixed(2)}`);
  }
  const line = `M${points.join("L")}`;
  return { line, area: `${line}L100 100L0 100Z` };
})();

/** Today's highs and lows, placed on the chart. */
export const tideToday = tideExtremes
  .filter((extreme) => extreme.minute >= 0 && extreme.minute < DAY)
  .map((extreme) => ({ ...extreme, time: formatTideTime(extreme.minute), ...tidePoint(extreme.minute) }));

export const tideNow = {
  time: formatTideTime(nowMinute),
  feet: tideHeight(nowMinute),
  falling: tideHeight(nowMinute + 1) < tideHeight(nowMinute),
  ...tidePoint(nowMinute),
};

/** Tomorrow's first high, as the page reads once "Tomorrow" is pressed. */
const tomorrowHigh = tideExtremes[tideExtremes.length - 1];
export const tideTomorrowFirstHigh = `${tomorrowHigh.kind} ${formatTideTime(tomorrowHigh.minute)}`;
