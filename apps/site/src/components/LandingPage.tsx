import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { motion, useReducedMotion } from "motion/react";
import { ThemeToggle } from "./ThemeToggle";
import { GestureMatrix } from "./GestureMatrix";
import { LatticesMark } from "./LatticesMark";
import { ProductsMenu, SiteFooter } from "./SiteChrome";
import { heroDesktopMaps, heroLayer, heroOverlapCount, heroWindowLayouts, heroWindowMeta } from "./heroDesktopMap";
import type { HeroDesktopPhase, HeroWindowId } from "./heroDesktopMap";
import { tideNow, tidePaths, tideToday, tideTomorrowFirstHigh } from "./heroTide";
import { latticesDownloadUrl as latticesDownloadURL, latticesAppVersion } from "../seo/routes";

const latticesCliVersion = "0.15.0";
const latticesDownloadMeta = `Apple Silicon · .dmg · ${latticesAppVersion}`;

declare global {
  interface Window {
    gtag?: (...args: unknown[]) => void
  }
}

function trackCta(action: string, destination: string) {
  if (typeof window !== 'undefined' && typeof window.gtag === 'function') {
    window.gtag('event', 'cta_click', {
      cta_action: action,
      cta_destination: destination,
    })
  }
}

// 12x12 pixel cat: solid body, eyes cut as negative space, tail drawn separately
// so it can flick without disturbing the silhouette.
const MASCOT_BODY = [
  "#....#......",
  "##..##......",
  "######......",
  "#.##.#......",
  "######......",
  ".####.......",
  ".#####......",
  ".######.....",
  ".######.....",
  ".#######....",
  ".#######....",
  ".##..##.....",
];

// Eye holes, filled in to close the lids on a blink.
const MASCOT_EYES: Array<[number, number]> = [
  [1, 3],
  [4, 3],
];

// Tail poses, low to high. Base pixel stays welded to the haunch.
const MASCOT_TAILS: Array<Array<[number, number]>> = [
  [[8, 10], [9, 10], [10, 10], [10, 9]],
  [[8, 10], [9, 10], [10, 9], [10, 8]],
  [[8, 10], [9, 9], [10, 8], [10, 7], [10, 6]],
];

const MASCOT_W = MASCOT_BODY[0].length;
const MASCOT_H = MASCOT_BODY.length;

function PixelMascot() {
  const wrapRef = useRef<HTMLSpanElement>(null);
  const reducedMotion = useReducedMotion() ?? false;
  const [blinking, setBlinking] = useState(false);
  const [tail, setTail] = useState(0);

  // Pointer lean — a few pixels, capped hard on the right so the cat stays
  // on the plinth.
  useEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap || reducedMotion) return;

    const maxLeft = 8;
    const maxRight = 2;
    const maxY = 4;
    const ease = 0.14;
    let targetX = 0;
    let targetY = 0;
    let currentX = 0;
    let currentY = 0;
    let raf = 0;

    const tick = () => {
      currentX += (targetX - currentX) * ease;
      currentY += (targetY - currentY) * ease;
      wrap.style.setProperty("--cat-x", `${currentX.toFixed(2)}px`);
      wrap.style.setProperty("--cat-y", `${currentY.toFixed(2)}px`);
      wrap.style.setProperty("--cat-rotate", `${(currentX * 0.4).toFixed(2)}deg`);
      if (Math.abs(targetX - currentX) > 0.04 || Math.abs(targetY - currentY) > 0.04) {
        raf = requestAnimationFrame(tick);
      } else {
        raf = 0;
      }
    };

    const kick = () => {
      if (!raf) raf = requestAnimationFrame(tick);
    };

    const onMove = (event: PointerEvent) => {
      const rect = wrap.getBoundingClientRect();
      const nx = (event.clientX - (rect.left + rect.width / 2)) / Math.max(window.innerWidth * 0.5, 1);
      const ny = (event.clientY - (rect.top + rect.height / 2)) / Math.max(window.innerHeight * 0.5, 1);
      targetX = Math.max(-maxLeft, Math.min(maxRight, nx * 7));
      targetY = Math.max(-maxY, Math.min(maxY, ny * maxY));
      kick();
    };

    window.addEventListener("pointermove", onMove, { passive: true });
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("pointermove", onMove);
    };
  }, [reducedMotion]);

  // Idle blink — irregular gaps, occasional double blink.
  useEffect(() => {
    if (reducedMotion) return;
    let timer: ReturnType<typeof setTimeout>;
    const queue = (delay: number, fn: () => void) => {
      timer = setTimeout(fn, delay);
    };
    const shut = (remaining: number) => {
      setBlinking(true);
      queue(110, () => {
        setBlinking(false);
        if (remaining > 0) queue(150, () => shut(remaining - 1));
        else schedule();
      });
    };
    const schedule = () => {
      queue(3200 + Math.random() * 5600, () => shut(Math.random() < 0.18 ? 1 : 0));
    };
    schedule();
    return () => clearTimeout(timer);
  }, [reducedMotion]);

  // Idle tail — mostly still, then a short flick back down to rest.
  useEffect(() => {
    if (reducedMotion) return;
    let timer: ReturnType<typeof setTimeout>;
    const run = (steps: Array<[number, number]>, i: number) => {
      if (i >= steps.length) {
        schedule();
        return;
      }
      const [pose, hold] = steps[i];
      setTail(pose);
      timer = setTimeout(() => run(steps, i + 1), hold);
    };
    const schedule = () => {
      timer = setTimeout(() => {
        const big = Math.random() < 0.45;
        run(
          big
            ? [[1, 130], [2, 210], [1, 120], [2, 170], [1, 150], [0, 0]]
            : [[1, 190], [0, 0]],
          0,
        );
      }, 4200 + Math.random() * 7000);
    };
    schedule();
    return () => clearTimeout(timer);
  }, [reducedMotion]);

  return (
    <span ref={wrapRef} className="pixel-mascot-wrap" aria-hidden="true">
      <svg
        className="pixel-mascot"
        viewBox={`0 0 ${MASCOT_W} ${MASCOT_H}`}
        shapeRendering="crispEdges"
        fill="currentColor"
      >
        {MASCOT_BODY.flatMap((row, y) =>
          [...row].map((cell, x) =>
            cell === "#" ? <rect key={`b${x}-${y}`} x={x} y={y} width={1} height={1} /> : null,
          ),
        )}
        {blinking
          ? MASCOT_EYES.map(([x, y]) => <rect key={`e${x}`} x={x} y={y} width={1} height={1} />)
          : null}
        {MASCOT_TAILS[tail].map(([x, y]) => (
          <rect key={`t${x}-${y}`} x={x} y={y} width={1} height={1} />
        ))}
      </svg>
    </span>
  );
}

function GitHubIcon() {
  return (
    <svg viewBox="0 0 16 16" fill="currentColor">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

function AppleIcon() {
  return (
    <svg viewBox="0 0 384 512" fill="currentColor" width="14" height="14">
      <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184 4 273.5c0 26.2 4.8 53.3 14.4 81.2 12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} width="14" height="14">
      <path d="M12 3v12" />
      <path d="m7 10 5 5 5-5" />
      <path d="M5 21h14" />
    </svg>
  );
}

type PaneLayout = 1 | 2 | 3;
type CuaStepId = "observe" | "stage" | "execute" | "verify";

const configExamples: Record<PaneLayout, string> = {
  1: `{
  <span class="hl-key">"panes"</span>: [
    { <span class="hl-key">"cmd"</span>: <span class="hl-str">"claude"</span> }
  ]
}`,
  2: `{
  <span class="hl-key">"ensure"</span>: <span class="hl-num">true</span>,
  <span class="hl-key">"panes"</span>: [
    { <span class="hl-key">"name"</span>: <span class="hl-str">"claude"</span>, <span class="hl-key">"cmd"</span>: <span class="hl-str">"claude"</span>, <span class="hl-key">"size"</span>: <span class="hl-num">60</span> },
    { <span class="hl-key">"name"</span>: <span class="hl-str">"dev"</span>,    <span class="hl-key">"cmd"</span>: <span class="hl-str">"bun dev"</span> }
  ]
}`,
  3: `{
  <span class="hl-key">"ensure"</span>: <span class="hl-num">true</span>,
  <span class="hl-key">"panes"</span>: [
    { <span class="hl-key">"name"</span>: <span class="hl-str">"claude"</span>, <span class="hl-key">"cmd"</span>: <span class="hl-str">"claude"</span>, <span class="hl-key">"size"</span>: <span class="hl-num">60</span> },
    { <span class="hl-key">"name"</span>: <span class="hl-str">"dev"</span>,    <span class="hl-key">"cmd"</span>: <span class="hl-str">"bun dev"</span> },
    { <span class="hl-key">"name"</span>: <span class="hl-str">"test"</span>,   <span class="hl-key">"cmd"</span>: <span class="hl-str">"bun test --watch"</span> }
  ]
}`,
};

const agentExample = `<span class="hl-kw">import</span> { daemonCall } <span class="hl-kw">from</span> <span class="hl-str">'@lattices/lattices'</span>

<span class="hl-cmt">// Find a window by title, app, session, or cwd</span>
<span class="hl-kw">const</span> [match] = <span class="hl-kw">await</span> daemonCall(<span class="hl-str">'lattices.search'</span>, {
  query: <span class="hl-str">'tideline'</span>
})
<span class="hl-kw">await</span> daemonCall(<span class="hl-str">'window.focus'</span>, {
  wid: match.wid
})

<span class="hl-cmt">// Bring up the project's layer</span>
<span class="hl-kw">await</span> daemonCall(<span class="hl-str">'layer.activate'</span>, {
  name: <span class="hl-str">'tideline'</span>,
  mode: <span class="hl-str">'launch'</span>,
})

<span class="hl-cmt">// Or move one window, by app and title</span>
<span class="hl-kw">await</span> daemonCall(<span class="hl-str">'window.place'</span>, {
  app: <span class="hl-str">'Safari'</span>,
  title: <span class="hl-str">'Tideline'</span>,
  placement: <span class="hl-str">'right'</span>,
})`;

const cuaSteps: Array<{
  id: CuaStepId;
  number: string;
  title: string;
  heading: string;
  caption: string;
  filename: string;
  code: string;
}> = [
  {
    id: "observe",
    number: "01",
    title: "Observe",
    heading: "Read the app before acting",
    caption: "Read the Accessibility tree and optional screenshot so the agent chooses from stable element ids.",
    filename: "observe.ts",
    code: `<span class="hl-kw">const</span> ui = <span class="hl-kw">await</span> daemonCall(<span class="hl-str">'computer.windowState'</span>, {
  app: <span class="hl-str">'Safari'</span>,
  title: <span class="hl-str">'Tideline'</span>,
  mode: <span class="hl-str">'ax'</span>,
})`,
  },
  {
    id: "stage",
    number: "02",
    title: "Stage",
    heading: "Prepare a reviewable action",
    caption: "Bind the next move to a snapshot element while nothing has run yet.",
    filename: "stage.ts",
    code: `<span class="hl-kw">await</span> daemonCall(<span class="hl-str">'computer.elementAction'</span>, {
  snapshotId: ui.snapshotId,
  elementId: <span class="hl-str">'e14'</span>, <span class="hl-cmt">// "Tomorrow"</span>
  action: <span class="hl-str">'press'</span>,
  treatment: <span class="hl-str">'stage'</span>,
})`,
  },
  {
    id: "execute",
    number: "03",
    title: "Execute",
    heading: "Run the exact staged command",
    caption: "Click, type, hotkey, or set a value on-device after the same safety checks.",
    filename: "execute.ts",
    code: `<span class="hl-kw">await</span> daemonCall(<span class="hl-str">'computer.elementAction'</span>, {
  snapshotId: ui.snapshotId,
  elementId: <span class="hl-str">'e14'</span>, <span class="hl-cmt">// "Tomorrow"</span>
  action: <span class="hl-str">'press'</span>,
  treatment: <span class="hl-str">'execute'</span>,
})`,
  },
  {
    id: "verify",
    number: "04",
    title: "Verify",
    heading: "Check the result on-device",
    caption: "Confirm the outcome with OCR or AX, then feed that receipt into the next observation.",
    filename: "verify.ts",
    code: `<span class="hl-kw">const</span> receipt = <span class="hl-kw">await</span> daemonCall(<span class="hl-str">'computer.verify'</span>, {
  app: <span class="hl-str">'Safari'</span>,
  title: <span class="hl-str">'Tideline'</span>,
  mode: <span class="hl-str">'ocr'</span>,
  contains: <span class="hl-str">'${tideTomorrowFirstHigh}'</span>,
})`,
  },
];

const showLatsDevTeaser = import.meta.env.PUBLIC_SHOW_LATS_DEV_TEASER === "true";

function HeroWindowContent({ id }: { id: HeroWindowId }) {
  if (id === "session") {
    // One tmux session split the way `lattices` splits two panes: claude on the
    // left 60%, the dev server beside it, as in the two-pane .lattices.json
    // example further down the page. The claude pane shows the tail of a
    // longer session, pinned to its input box the way a terminal scrolls.
    return (
      <div className="desktop-tmux">
        <div className="desktop-terminal-lines desktop-claude-pane">
          <span className="agent-prompt"><b>&gt;</b> draw today&apos;s tides as a curve</span>
          <div className="claude-block">
            <span><i>⏺</i> Read(src/tides.ts)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> Read 67 lines</span>
          </div>
          <div className="claude-block">
            <span><i>⏺</i> Write(src/chart.ts)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> Wrote 58 lines to src/chart.ts</span>
          </div>
          <span><i>⏺</i> Drew a half-cosine between each high and low.</span>
          <span className="agent-prompt"><b>&gt;</b> mark where the tide is right now</span>
          <div className="claude-block">
            <span><i>⏺</i> Update(src/chart.ts)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> Updated src/chart.ts with 1 addition</span>
            <span className="terminal-diff terminal-added"><b>51</b> +   markNow(svg, now);</span>
          </div>
          <span><i>⏺</i> A dashed line and a dot now mark the time.</span>
          <span className="agent-prompt"><b>&gt;</b> tide times are showing in UTC</span>
          <div className="claude-block">
            <span><i>⏺</i> Read(src/format.ts)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> Read 42 lines</span>
          </div>
          <div className="claude-block">
            <span><i>⏺</i> Update(src/format.ts)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> Updated src/format.ts with 1 addition</span>
            <span className="terminal-diff"><b>14</b>       hour: &quot;numeric&quot;,</span>
            <span className="terminal-diff"><b>15</b>       minute: &quot;2-digit&quot;,</span>
            <span className="terminal-diff terminal-added"><b>16</b> +     timeZone: station.tz,</span>
            <span className="terminal-diff"><b>17</b>     {"})"}</span>
          </div>
          <div className="claude-block">
            <span><i>⏺</i> Bash(bun test format)</span>
            <span className="terminal-out terminal-dim"><b>⎿</b> 9 pass · 0 fail</span>
          </div>
          <span><i>⏺</i> Times now follow each station&apos;s time zone.</span>
          <div className="claude-block">
            <span className="claude-input"><b>&gt;</b><i className="claude-cursor" /></span>
            <span className="terminal-out terminal-dim">? for shortcuts</span>
          </div>
        </div>
        <div className="desktop-terminal-lines desktop-dev-pane">
          <span><b>~/dev/tideline</b> bun dev</span>
          <span className="terminal-out"><strong>VITE</strong> v7.3.3 <span className="terminal-dim">ready in 488 ms</span></span>
          <span className="terminal-out terminal-gap"><i>➜</i> Local: http://localhost:5173/</span>
          <span className="terminal-out terminal-dim"><i>➜</i> Network: use --host to expose</span>
          <span className="terminal-out terminal-dim"><i>➜</i> press h + enter to show help</span>
          <span className="terminal-dim">9:41:07 AM [vite] (client) hmr update /src/format.ts</span>
        </div>
      </div>
    );
  }

  if (id === "editor") {
    return (
      <div className="desktop-editor">
        <div className="desktop-editor-sidebar">
          <strong>TIDELINE</strong>
          <span>src</span>
          <span className="is-nested">chart.ts</span>
          <span className="is-nested is-active">format.ts</span>
          <span className="is-nested">stations.ts</span>
          <span className="is-nested">tides.ts</span>
        </div>
        <div className="desktop-code-lines" aria-hidden="true">
          <span><i>export function</i> tideTime(tide: Tide, station: Station) {'{'}</span>
          <span className="indent"><i>return</i> tide.at.toLocaleTimeString(<b>&quot;en-US&quot;</b>, {'{'}</span>
          <span className="indent-2">hour: <b>&quot;numeric&quot;</b>,</span>
          <span className="indent-2">minute: <b>&quot;2-digit&quot;</b>,</span>
          <span className="indent-2 is-changed">timeZone: station.tz,</span>
          <span className="indent">{'})'}</span>
          <span>{'}'}</span>
        </div>
      </div>
    );
  }

  // tideline itself, open in Safari: the day's tide curve with the reading now.
  return (
    <div className="desktop-tide">
      <div className="desktop-tide-head">
        <span className="desktop-tide-place">
          <strong>Tideline</strong>
          <span>Half Moon Bay, CA</span>
        </span>
        <span className="desktop-tide-days">
          <span className="is-active">Today</span>
          <span>Tomorrow</span>
        </span>
      </div>
      <p className="desktop-tide-reading">
        <b>{tideNow.feet.toFixed(1)} ft</b> {tideNow.falling ? "falling" : "rising"} · {tideNow.time}
      </p>
      <div className="desktop-tide-chart">
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          <defs>
            <linearGradient id="hero-tide-water" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stopColor="currentColor" stopOpacity="0.3" />
              <stop offset="1" stopColor="currentColor" stopOpacity="0.03" />
            </linearGradient>
          </defs>
          {[25, 50, 75].map((x) => (
            <line key={x} className="desktop-tide-grid" x1={x} x2={x} y1={0} y2={100} vectorEffect="non-scaling-stroke" />
          ))}
          <path d={tidePaths.area} fill="url(#hero-tide-water)" />
          <path className="desktop-tide-line" d={tidePaths.line} vectorEffect="non-scaling-stroke" />
          <line className="desktop-tide-now" x1={tideNow.x} x2={tideNow.x} y1={0} y2={100} vectorEffect="non-scaling-stroke" />
        </svg>
        {tideToday.map((extreme) => (
          <span
            key={extreme.minute}
            className={`desktop-tide-extreme is-${extreme.kind.toLowerCase()}${extreme.x > 90 ? " is-end" : ""}`}
            style={{ left: `${extreme.x}%`, top: `${extreme.y}%` }}
          >
            <b>{extreme.time}</b> {extreme.feet.toFixed(1)} ft
          </span>
        ))}
        <i className="desktop-tide-dot" style={{ left: `${tideNow.x}%`, top: `${tideNow.y}%` }} />
      </div>
      <div className="desktop-tide-axis">
        <span>12 AM</span>
        <span>6 AM</span>
        <span>12 PM</span>
        <span>6 PM</span>
        <span>12 AM</span>
      </div>
    </div>
  );
}

function HeroDesktopWindow({
  id,
  phase,
  reducedMotion,
  children,
}: {
  id: HeroWindowId;
  phase: HeroDesktopPhase;
  reducedMotion: boolean;
  children: ReactNode;
}) {
  const layout = heroWindowLayouts[id][phase];
  const meta = heroWindowMeta[id];

  return (
    <motion.div
      className={`hero-desktop-window hero-window-${id}${meta.focused ? " is-focused" : ""}`}
      style={{ zIndex: layout.z }}
      initial={false}
      animate={{
        left: `${layout.left}%`,
        top: `${layout.top}%`,
        width: `${layout.width}%`,
        height: `${layout.height}%`,
      }}
      transition={{ duration: reducedMotion ? 0 : 0.74, ease: [0.16, 1, 0.3, 1] }}
    >
      <div className="hero-window-bar">
        <span className="hero-window-lights"><i /><i /><i /></span>
        <span className="hero-window-title">{meta.title}</span>
        <span className="hero-window-app">{meta.app}</span>
      </div>
      <div className="hero-window-body">{children}</div>
    </motion.div>
  );
}

/** The app's layer bezel: the pill Lattices shows on every layer switch. */
function HeroLayerBezel() {
  return (
    <>
      <svg className="hero-layer-bezel-icon" viewBox="0 0 16 16" aria-hidden="true">
        <path d="M8 1.8 14.2 5 8 8.2 1.8 5Z" />
        <path d="m1.8 8 6.2 3.2L14.2 8M1.8 11l6.2 3.2 6.2-3.2" fill="none" />
      </svg>
      <span className="hero-layer-bezel-dots">
        {Array.from({ length: heroLayer.total }, (_, index) => (
          <i key={index} className={index === heroLayer.index ? "is-active" : undefined} />
        ))}
      </span>
      <span className="hero-layer-bezel-rule" />
      <span className="hero-layer-bezel-name">{heroLayer.name}</span>
      <span className="hero-layer-bezel-tag">Lattices</span>
    </>
  );
}

const heroWindowIds = Object.keys(heroWindowMeta) as HeroWindowId[];

function HeroWorkspaceStage() {
  const prefersReducedMotion = useReducedMotion() ?? false;
  const [phaseChoice, setPhaseChoice] = useState<HeroDesktopPhase>("messy");
  // The loop alternates who restores the layer: your shortcut, then the agent.
  const [driver, setDriver] = useState<"you" | "agent">("you");
  const [autoPlay, setAutoPlay] = useState(true);
  const [inView, setInView] = useState(true);
  // Counts layer switches, so the bezel plays once for each.
  const [layerSwitches, setLayerSwitches] = useState(0);
  const stageRef = useRef<HTMLDivElement | null>(null);
  // Reduced-motion visitors land on the organized result instead of the loop.
  const phase = prefersReducedMotion && autoPlay ? "organized" : phaseChoice;
  const organized = phase === "organized";
  const agentTurn = driver === "agent";
  const keycastOn = !organized && autoPlay && driver === "you";
  // The agent ran `lattices map` before it asked for the layer, so its map
  // stays the scattered one. On your turn the map follows the desktop.
  const mapPhase: HeroDesktopPhase = agentTurn ? "messy" : phase;

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      ([entry]) => setInView(entry.isIntersecting),
      { threshold: 0.35 },
    );
    observer.observe(stage);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!autoPlay || prefersReducedMotion || !inView) return;
    // Linger on the organized result, longest after the agent's turn so the
    // tiled desktop and the full transcript sit together. The scattered beat
    // holds long enough to read, and longer on the agent's turn, where the
    // request and the command appear before the switch.
    const delay = organized
      ? agentTurn ? 7200 : 4600
      : agentTurn ? 4200 : 3000;
    const timer = window.setTimeout(() => {
      if (organized) {
        setDriver(agentTurn ? "you" : "agent");
        setPhaseChoice("messy");
      } else {
        setPhaseChoice("organized");
        setLayerSwitches((count) => count + 1);
      }
    }, delay);
    return () => window.clearTimeout(timer);
  }, [autoPlay, organized, agentTurn, prefersReducedMotion, inView]);

  const selectPhase = (next: HeroDesktopPhase) => {
    setAutoPlay(false);
    setDriver("you");
    if (next === "organized" && !organized) setLayerSwitches((count) => count + 1);
    setPhaseChoice(next);
  };

  return (
    <div className="hero-desktop-demo" id="workspace-demo">
      <div className="hero-stage-bar">
        <span className="hero-stage-label">
          <i aria-hidden="true" />
          Simulated desktop · {heroLayer.name}
        </span>
        <div className="hero-desktop-comparison" role="group" aria-label="Compare the desktop without and with Lattices">
          <button
            type="button"
            className={!organized ? "is-active" : ""}
            aria-pressed={!organized}
            onClick={() => selectPhase("messy")}
          >
            <span aria-hidden="true">○</span>
            Without Lattices
          </button>
          <button
            type="button"
            className={organized ? "is-active" : ""}
            aria-pressed={organized}
            onClick={() => selectPhase("organized")}
          >
            <span aria-hidden="true">●</span>
            With Lattices
          </button>
        </div>
      </div>

      <div
        ref={stageRef}
        className={`hero-workspace-stage is-${phase}`}
        role="img"
        aria-label={organized
          ? "A simulated Mac desktop with the tideline layer applied: a tmux session running Claude and a dev server on the left half, the tide chart in Safari and format.ts in Zed stacked on the right"
          : "A simulated Mac desktop with three overlapping windows: a tmux session running Claude, the tideline tide chart in Safari, and format.ts in Zed"}
      >
        <div className="hero-desktop-screen">
          <div className="hero-macos-bar">
            <span className="hero-macos-brand"><span className="hero-macos-apple" aria-hidden="true"><AppleIcon /></span> Terminal</span>
            <span className="hero-macos-menu">Shell&nbsp;&nbsp; Edit&nbsp;&nbsp; View&nbsp;&nbsp; Window</span>
            <span className="hero-macos-status">
              <LatticesMark theme="light" className="hero-macos-mark" size={12} />
              9:41 AM
            </span>
          </div>

          {heroWindowIds.map((id) => (
            <HeroDesktopWindow key={id} id={id} phase={phase} reducedMotion={prefersReducedMotion}>
              <HeroWindowContent id={id} />
            </HeroDesktopWindow>
          ))}

          <motion.div
            className="hero-keycast"
            aria-hidden="true"
            initial={false}
            animate={{ opacity: keycastOn ? 1 : 0 }}
            transition={keycastOn ? { duration: 0.26, delay: 1.4 } : { duration: 0.18 }}
          >
            <kbd>⌘</kbd>
            <kbd>⌥</kbd>
            <kbd>1</kbd>
            <span>switch layer</span>
          </motion.div>

          {!prefersReducedMotion && layerSwitches > 0 && (
            <motion.div
              key={layerSwitches}
              className="hero-layer-bezel"
              aria-hidden="true"
              initial={{ opacity: 0, scale: 0.96 }}
              animate={{ opacity: [0, 1, 1, 0], scale: [0.96, 1, 1, 1] }}
              // The app's timing: 0.15s in, a 1.5s hold, 0.3s out.
              transition={{ duration: 1.95, times: [0, 0.077, 0.846, 1], ease: "easeOut" }}
            >
              <HeroLayerBezel />
            </motion.div>
          )}
        </div>
      </div>

      <div className="hero-understage">
        <div className="hero-agent-harness" role="group" aria-label="A coding agent reading the same desktop through Lattices">
          <div className="hero-harness-head">
            <span className="hero-harness-dot" aria-hidden="true" />
            <span>claude</span>
            <span className="hero-harness-cwd">~/dev/{heroLayer.name}</span>
            <span className="hero-harness-transport">ws://127.0.0.1:9399</span>
          </div>
          <div className="hero-harness-body">
            <span className="hero-harness-user">
              <b>&gt;</b> what&apos;s on my screen?
            </span>
            <span className="hero-harness-tool">
              <i aria-hidden="true">⏺</i> Bash(lattices map)
            </span>
            <motion.div
              key={agentTurn ? "agent" : phase}
              className="hero-harness-result hero-harness-map-result"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ duration: prefersReducedMotion ? 0 : 0.3, delay: prefersReducedMotion ? 0 : 0.6 }}
            >
              <span className="hero-harness-summary">
                <b aria-hidden="true">⎿</b> {heroWindowIds.length} windows · {heroOverlapCount[mapPhase]} overlaps ·{" "}
                {mapPhase === "organized" ? `layer: ${heroLayer.name}` : "focused: Terminal"}
              </span>
              <pre className="hero-harness-map" aria-hidden="true">{heroDesktopMaps[mapPhase]}</pre>
            </motion.div>
            <motion.span
              className="hero-harness-user"
              initial={false}
              animate={{ opacity: agentTurn ? 1 : 0 }}
              transition={{ duration: agentTurn ? 0.3 : 0.2, delay: agentTurn ? 0.9 : 0 }}
              style={{ visibility: agentTurn ? "visible" : "hidden" }}
              aria-hidden={!agentTurn}
            >
              <b>&gt;</b> put my {heroLayer.name} layer back
            </motion.span>
            <motion.span
              className="hero-harness-tool"
              initial={false}
              animate={{ opacity: agentTurn ? 1 : 0 }}
              transition={{ duration: agentTurn ? 0.3 : 0.2, delay: agentTurn ? 2.1 : 0 }}
              style={{ visibility: agentTurn ? "visible" : "hidden" }}
              aria-hidden={!agentTurn}
            >
              <i aria-hidden="true">⏺</i> Bash(lattices layer {heroLayer.name})
            </motion.span>
            <motion.span
              className="hero-harness-result"
              initial={false}
              animate={{ opacity: agentTurn && organized ? 1 : 0 }}
              transition={{
                duration: agentTurn && organized ? 0.3 : 0.2,
                delay: agentTurn && organized ? 0.9 : 0,
              }}
              style={{ visibility: agentTurn && organized ? "visible" : "hidden" }}
              aria-hidden={!agentTurn || !organized}
            >
              <b aria-hidden="true">⎿</b> Activated layer &quot;{heroLayer.name}&quot;
            </motion.span>
          </div>
        </div>
        <HeroGestureDemo />
      </div>

      <div className="hero-stage-foot" aria-hidden="true">
        <span>Lattices engine</span>
        <span className="hero-plinth-state">
          {organized
            ? `layer ${heroLayer.index + 1} · ${heroLayer.name}`
            : `${heroWindowIds.length} windows · ${heroOverlapCount.messy} overlaps`}
        </span>
        <PixelMascot />
      </div>
    </div>
  );
}

const gesturePreviewStart = 9.25;
const gesturePreviewEnd = 11.65;

function HeroGestureDemo() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const reducedMotion = useReducedMotion() ?? false;

  const playPreview = () => {
    if (reducedMotion) return;
    const video = videoRef.current;
    if (!video) return;
    if (
      video.currentTime < gesturePreviewStart ||
      video.currentTime >= gesturePreviewEnd
    ) {
      video.currentTime = gesturePreviewStart;
    }
    void video.play();
  };

  const resetPreview = () => {
    const video = videoRef.current;
    if (!video) return;
    video.pause();
    video.currentTime = gesturePreviewStart;
  };

  const loopPreview = () => {
    const video = videoRef.current;
    if (!video || video.currentTime < gesturePreviewEnd) return;
    video.currentTime = gesturePreviewStart;
    void video.play();
  };

  return (
    <a
      className="hero-demo-peek"
      href="/blog/gesture-completion-matrix"
      aria-label="Watch the mouse gesture demo"
      onMouseEnter={playPreview}
      onMouseLeave={resetPreview}
      onFocus={playPreview}
      onBlur={resetPreview}
    >
      <video
        ref={videoRef}
        className="hero-demo-peek-media"
        muted
        playsInline
        preload="metadata"
        poster="/blog/gesture-completion-matrix-poster.png"
        aria-hidden="true"
        onLoadedMetadata={resetPreview}
        onTimeUpdate={loopPreview}
      >
        <source src="/blog/gesture-completion-matrix.mp4" type="video/mp4" />
      </video>
      <span className="hero-demo-peek-copy">
        <span className="hero-demo-peek-label">Gesture preview</span>
        <strong>Draw a gesture. Lattices does the rest.</strong>
        <span className="hero-demo-peek-link">Watch the demo &rarr;</span>
      </span>
    </a>
  );
}

const handsShortcuts: Array<{ keys: string[]; action: string }> = [
  { keys: ["⌃", "⌥", "← / →"], action: "Tile halves" },
  { keys: ["⌃", "⌥", "G"], action: "4×4 grid on the front window" },
  { keys: ["⌃", "⌥", "V"], action: "Fill the next 3×2 cell" },
  { keys: ["⌘", "⌥", "1 / 2 / 3"], action: "Switch workspace layer" },
  { keys: ["⌘", "⇧", "M"], action: "Command palette" },
  { keys: ["Hyper", "L"], action: "Studio / screen map" },
];

// The ⌃⌥ placement HUD, drawn offscreen by the app's own view code. It plays
// while on screen; reduced-motion visitors keep the poster.
function PlacementFilm() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const reducedMotion = useReducedMotion() ?? false;
  const [inView, setInView] = useState(false);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      ([entry]) => setInView(entry.isIntersecting),
      { threshold: 0.35 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    if (inView && !reducedMotion) void video.play().catch(() => undefined);
    else video.pause();
  }, [inView, reducedMotion]);

  return (
    <figure className="hands-gesture-figure">
      <video
        ref={videoRef}
        className="hands-gesture-film hands-placement-film"
        muted
        loop
        playsInline
        preload="metadata"
        poster="/hands/placement-hud-poster.png"
        aria-label="The placement matrix: the pointer turns toward each side and corner, then becomes the knob over the centre"
      >
        <source src="/hands/placement-hud.mp4" type="video/mp4" />
      </video>
      <figcaption>
        Hold ⌃⌥ and point at a side or a corner, then let go to put the front
        window there. The centre fills the screen; dead centre cancels.
      </figcaption>
    </figure>
  );
}

function HandsOnSection() {
  return (
    <section className="home-sec fade-in" id="hands">
      <SectionHead title="Shortcuts and mouse gestures, not just the palette.">
        <p className="sec-lede">
          Caps Lock is Hyper. ⌃⌥ tiles halves and grids. Hold a mouse button,
          draw a direction or a shape, release. The app replays that path in
          a 3×3 <em>matrix</em> — the same completer as the logo.
        </p>
        <div className="hands-links">
          <a href="/docs/app">Shortcut reference &rarr;</a>
          <a href="/docs/mouse-gestures">Mouse gestures &rarr;</a>
        </div>
      </SectionHead>

      <div className="hands-stage">
        <div className="hands-panel">
          <h3>Keyboard</h3>
          <PlacementFilm />
          <ul className="hands-list">
            {handsShortcuts.map((row) => (
              <li key={row.action}>
                <span className="hands-chords">
                  {row.keys.map((key) => (
                    <kbd key={key}>{key}</kbd>
                  ))}
                </span>
                <span>{row.action}</span>
              </li>
            ))}
          </ul>
          <p className="hands-note">Hold Caps Lock for Hyper. Defaults — change them in Settings.</p>
        </div>

        <div className="hands-panel">
          <h3>The matrix</h3>
          <GestureMatrix />
        </div>
      </div>
    </section>
  );
}

function SectionHead({ kicker, title, children }: { kicker?: string; title: string; children?: ReactNode }) {
  return (
    <header className="sec-head">
      {kicker && <p className="sec-kicker">{kicker}</p>}
      <h2 className="sec-title">{title}</h2>
      {children}
    </header>
  );
}

const tickerMethods = [
  "agent api · ws://127.0.0.1:9399",
  "lattices.search",
  "windows.search",
  "terminals.search",
  "ocr.snapshot",
  "window.focus",
  "window.place",
  "layer.activate",
  "space.optimize",
  "desktop.snapshot",
  "session.launch",
  "tabStacks.create",
  "computer.windowState",
  "computer.elementAction",
  "computer.verify",
];

export default function App() {
  const brewCommand = "brew tap arach/tap\nbrew trust arach/tap\nbrew install --cask arach/tap/lattices";
  const [brewCopy, setBrewCopy] = useState("Copy");
  async function copyBrew() {
    try {
      await navigator.clipboard.writeText(brewCommand);
      setBrewCopy("Copied");
      window.setTimeout(() => setBrewCopy("Copy"), 2000);
    } catch { setBrewCopy("Select to copy"); }
  }
  const [installCopy, setInstallCopy] = useState("Copy");
  async function copyInstall() {
    try {
      await navigator.clipboard.writeText("bun install -g @lattices/lattices");
      setInstallCopy("Copied");
      window.setTimeout(() => setInstallCopy("Copy"), 2000);
    } catch { setInstallCopy("Select to copy"); }
  }
  const [paneLayout, setPaneLayout] = useState<PaneLayout>(2);
  const [cuaStep, setCuaStep] = useState<CuaStepId>("observe");
  // Initial theme is set synchronously by the inline script in index.html
  // (saved choice → system preference → dark). This re-syncs on toggle.
  const [theme, setTheme] = useState<"light" | "dark">(() => {
    if (typeof document === "undefined") return "dark";
    return (document.documentElement.getAttribute("data-theme") as "light" | "dark") || "dark";
  });
  const activeCuaStep = cuaSteps.find((step) => step.id === cuaStep) ?? cuaSteps[0];

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("theme", theme);
  }, [theme]);

  return (
    <>
      {/* Nav */}
      <nav className="nav home-nav" aria-label="Main navigation">
        <div className="nav-inner">
          <a href="/" className="nav-brand">
            <LatticesMark />
            <span className="nav-name">lattices</span>
          </a>
          <div className="nav-links">
            <ProductsMenu />
            <a href="/learn" className="nav-link">Learn</a>
            <a href="/blog" className="nav-link nav-blog-link">
              Blog
            </a>
            <a href="/docs/overview" className="nav-link">
              Docs
            </a>
            <a
              href="https://github.com/lattices-dev/lattices"
              target="_blank"
              rel="noopener noreferrer"
              className="nav-github"
            >
              <GitHubIcon />
              <span className="github-label">GitHub</span>
            </a>
            <ThemeToggle
              theme={theme}
              onToggle={() => setTheme(theme === "dark" ? "light" : "dark")}
            />
          </div>
        </div>
      </nav>

      {/* Hero */}
      <main>
        <section className="hero fade-in">
          <div className="hero-inner">

            <h1>Workspaces for agents (and you)</h1>
            <p className="hero-sub">
              Organize windows, run your tools, and automate your workflow.
              Control your Mac by shortcut, mouse gesture, or code.
            </p>
            <div className="hero-actions">
              <a
                href={latticesDownloadURL}
                className="hero-primary-cta"
                onClick={() => trackCta('download_dmg_hero', latticesDownloadURL)}
              >
                <DownloadIcon />
                Download for macOS
              </a>
              <a href="/docs/overview" className="hero-secondary-cta">
                Read the docs
              </a>
            </div>
            <ul className="hero-meta">
              <li>5,500+ installs</li>
              <li>Local first</li>
              <li>API driven</li>
              <li>Built for macOS</li>
            </ul>
          </div>

          <div className="hero-stage">
            <HeroWorkspaceStage />
          </div>
        </section>

        <div className="home-ticker" aria-hidden="true">
          <div className="home-ticker-track">
            {[0, 1].map((copy) => (
              <div className="home-ticker-seq" key={copy}>
                {tickerMethods.map((method) => (
                  <span className="home-ticker-item" key={method}>
                    {method}
                    <i aria-hidden="true" />
                  </span>
                ))}
              </div>
            ))}
          </div>
        </div>

        <section className="section shared-state-section" id="shared-state">
         <div className="shared-state-inner">
          <div className="shared-state-copy fade-in">
            <h2>Same desktop, whether you drive or your agent does.</h2>
            <p>
              Agents can write code and run tests, but arranging the Mac around
              that work is still brittle. Lattices gives you and your agents
              the same workspace controls, from one-window moves to
              multi-window layouts. Every change lands visibly on the desktop
              with a receipt.
            </p>
          </div>
          <div className="operator-rows fade-in fade-in-delay-1" aria-label="The same workspace request from a person or an agent">
            <div className="operator-row is-you">
              <span className="operator-row-label">You</span>
              <span className="operator-row-action">
                <span>&ldquo;Put the tide chart on the right half.&rdquo;</span>
              </span>
            </div>
            <div className="operator-row is-agent">
              <span className="operator-row-label">Your agent</span>
              <span className="operator-row-action">
                <code>window.place {'{'} app: &apos;Safari&apos;, title: &apos;Tideline&apos;, placement: &apos;right&apos; {'}'}</code>
              </span>
            </div>
            <p className="operator-result">
              <i aria-hidden="true" /> Chart on the right half — one live state.
            </p>
          </div>
         </div>
        </section>

        <div className="shell">
        <HandsOnSection />

        {/* Computer use (CUA) */}
        <section className="home-sec" id="cua">
          <div className="fade-in">
            <SectionHead title="Computer use you can control">
              <p className="sec-lede">
                Action is the focused computer-use product in the Lattices family.
                Observe the screen, stage each action for review, execute on-device,
                then verify the result.
              </p>
            </SectionHead>
          </div>

          <div className="cua-showcase fade-in fade-in-delay-1">
            <div className="cua-loop-rail" aria-label="Computer use safety loop">
              {cuaSteps.map((step) => (
                <button
                  key={step.id}
                  type="button"
                  className={`cua-stage-chip${cuaStep === step.id ? " active" : ""}`}
                  onClick={() => setCuaStep(step.id)}
                  aria-pressed={cuaStep === step.id}
                >
                  <span className="cua-stage-number">{step.number}</span>
                  <span className="cua-stage-chip-copy">
                    <span>{step.title}</span>
                  </span>
                </button>
              ))}
            </div>

            <div className="cua-stage-panel">
              <div className="cua-stage-copy">
                <h3>{activeCuaStep.heading}</h3>
                <p>{activeCuaStep.caption}</p>
              </div>

              <div className="code-block">
                <div className="code-header">
                  <span className="code-dot code-dot-red" />
                  <span className="code-dot code-dot-yellow" />
                  <span className="code-dot code-dot-green" />
                  <span className="code-filename">{activeCuaStep.filename}</span>
                </div>
                <pre
                  className="code-pre"
                  dangerouslySetInnerHTML={{ __html: activeCuaStep.code }}
                />
              </div>

              <div className="cua-stage-footer">
                <div className="cua-action-tags" aria-label="Supported computer use actions">
                  <span>mouse</span>
                  <span>keyboard</span>
                  <span>browser</span>
                  <span>local verify</span>
                </div>
                <div className="cua-stage-links">
                  <a href="/action" className="agent-api-link cua-stage-api-link">
                    Meet Action &rarr;
                  </a>
                  <a href="/docs/api" className="agent-api-link cua-stage-api-link cua-stage-api-secondary">
                    Computer-use API &rarr;
                  </a>
                </div>
              </div>
            </div>
          </div>
        </section>

        {showLatsDevTeaser && (
          <section className="home-sec next-section fade-in fade-in-delay-2">
            <div className="next-card">
              <div className="next-copy">
                <h2>Lats.dev for iPad</h2>
                <p>
                  Opening for TestFlight. A new app and domain for controlling
                  your Mac workspace from beside the keyboard: trackpad gestures,
                  window actions, live state, and shortcuts tuned for iPad.
                </p>
              </div>
              <div className="next-preview" aria-hidden="true">
                <div className="deck-shell">
                  <div className="deck-top">
                    <span>lats.dev</span>
                    <span>mac · live</span>
                  </div>
                  <div className="deck-trackpad">
                    <div className="deck-crosshair" />
                  </div>
                  <div className="deck-actions">
                    {["tile", "focus", "voice", "agent", "spaces", "keys"].map((label) => (
                      <div className="deck-action" key={label}>{label}</div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </section>
        )}

        {/* macOS app */}
        <section className="home-sec" id="app">
          <div className="app-grid">
            <div className="app-copy">
              <div className="app-title-row">
                <h2 className="app-title">The whole workspace, visible.</h2>
                <a
                  href={latticesDownloadURL}
                  className="app-download-icon"
                  aria-label="Download Lattices for macOS"
                  title="Download Lattices for macOS"
                  onClick={() => trackCta('download_dmg', latticesDownloadURL)}
                >
                  <DownloadIcon />
                </a>
              </div>
              <p className="app-desc">
                Keep the windows for coding, research, or deep work together.
                Switch workspace layers when it’s time to change focus.
              </p>
              <ul className="app-features">
                <li>See every project and live session</li>
                <li>Launch, attach, or detach with a click</li>
                <li>Tile with ⌃⌥ chords, a 4×4 grid, or a mouse drag</li>
                <li>Search windows, terminals, and screen text</li>
                <li>Middle-drag for Spaces, Screen Map, and dictation</li>
              </ul>
            </div>
            <div className="app-demo-reel" aria-label="Animated preview of lattices arranging windows, layers, search, and voice commands">
              <img
                src="/app-latest.png"
                alt="lattices app showing screen map with dual displays, layers, and inspector"
                className="app-screenshot"
                width="1172"
                height="764"
                loading="lazy"
              />
              <div className="app-demo-cursor" aria-hidden="true" />
              <div className="app-demo-focus app-demo-focus-one" aria-hidden="true" />
              <div className="app-demo-focus app-demo-focus-two" aria-hidden="true" />
              <div className="app-demo-tile app-demo-tile-left" aria-hidden="true" />
              <div className="app-demo-tile app-demo-tile-right" aria-hidden="true" />
            </div>
          </div>
        </section>

        {/* Product spine */}
        <section className="home-sec fade-in fade-in-delay-2" id="features">
          <SectionHead title="See your workspace. Put it to work." />
          <div className="home-spine">
            <article>
              <span className="home-spine-num">01</span>
              <h3>Window manager</h3>
              <h2>Tame your windows.</h2>
              <p>
                Tile windows, group them into layers, launch whole projects,
                and switch contexts from the app, a shortcut, or a mouse
                gesture.
              </p>
            </article>
            <article>
              <span className="home-spine-num">02</span>
              <h3>Tools and terminals</h3>
              <h2>Run your tools.</h2>
              <p>
                Launch your editor, browser, and terminal commands as a project.
                Keep your development server, tests, and coding agents
                ready in their own panes.
              </p>
            </article>
            <article>
              <span className="home-spine-num">03</span>
              <h3>Configuration</h3>
              <h2>Make it yours.</h2>
              <p>
                Define your tools and layouts in a config file. Add scripts
                and agent workflows through the same API that controls
                your desktop.
              </p>
            </article>
          </div>
        </section>

        {/* Config */}
        <section className="home-sec" id="config">
          <div className="fade-in fade-in-delay-2">
            <SectionHead kicker="Configuration" title="Do more with less friction.">
              <p className="sec-lede">
                Set up your terminals, browser, editor, and commands once.
                Bring the project back in one step, with each tool
                in its place.
              </p>
            </SectionHead>
          </div>

          <div className="config-grid fade-in fade-in-delay-2">
            <div>
              <div className="layouts">
                <button type="button" className={`layout-card${paneLayout === 1 ? " active" : ""}`} onClick={() => setPaneLayout(1)} aria-pressed={paneLayout === 1}>
                  <h3>1 pane</h3>
                  <p>Single focus</p>
                  <div className="layout-diagram layout-1">
                    <div className="layout-pane main">claude</div>
                  </div>
                </button>
                <button type="button" className={`layout-card${paneLayout === 2 ? " active" : ""}`} onClick={() => setPaneLayout(2)} aria-pressed={paneLayout === 2}>
                  <h3>2 panes</h3>
                  <p>Side-by-side</p>
                  <div className="layout-diagram layout-2">
                    <div className="layout-pane main">claude</div>
                    <div className="layout-pane">server</div>
                  </div>
                </button>
                <button type="button" className={`layout-card${paneLayout === 3 ? " active" : ""}`} onClick={() => setPaneLayout(3)} aria-pressed={paneLayout === 3}>
                  <h3>3+ panes</h3>
                  <p>Main-vertical</p>
                  <div className="layout-diagram layout-3">
                    <div className="layout-pane main">claude</div>
                    <div className="layout-pane">server</div>
                    <div className="layout-pane">tests</div>
                  </div>
                </button>
              </div>
            </div>

            <div className="code-block">
              <div className="code-header">
                <span className="code-dot code-dot-red" />
                <span className="code-dot code-dot-yellow" />
                <span className="code-dot code-dot-green" />
                <span className="code-filename">.lattices.json</span>
              </div>
              <pre
                className="code-pre"
                dangerouslySetInnerHTML={{ __html: configExamples[paneLayout] }}
              />
            </div>
          </div>
        </section>

        {/* Agent-managed workspaces */}
        <section className="home-sec" id="agents">
          <div className="config-grid fade-in fade-in-delay-2">
            <div>
              <p className="sec-kicker">Agent API</p>
              <h2 className="sec-title">
                A foundation for builders.
              </h2>
              <p className="sec-lede">
                Build custom workflows with an open-source app and a documented
                local API. Give scripts and agents the tools to find windows,
                arrange layouts, act on the screen, and verify the result.
              </p>
              <ul className="agent-methods">
                <li><code>lattices.search</code> — title, app, session, or cwd</li>
                <li><code>window.place</code> — tile by session, app, or window id</li>
                <li><code>layer.activate</code> — launch or focus a workspace</li>
                <li><code>space.optimize</code> — rebalance visible windows</li>
                <li><code>computer.windowState</code> — AX snapshot, element ids</li>
                <li><code>computer.elementAction</code> — stage or execute those ids</li>
                <li><code>computer.verify</code> — confirm via OCR or AX</li>
              </ul>
              <a href="/docs/api" className="agent-api-link">
                Full API reference &rarr;
              </a>
            </div>

            <div className="code-block">
              <div className="code-header">
                <span className="code-dot code-dot-red" />
                <span className="code-dot code-dot-yellow" />
                <span className="code-dot code-dot-green" />
                <span className="code-filename">agent-example.js</span>
              </div>
              <pre
                className="code-pre"
                dangerouslySetInnerHTML={{ __html: agentExample }}
              />
            </div>
          </div>
        </section>

        <section className="home-sec" id="local-first">
          <div className="local-trust fade-in">
            <div>
              <h2>Your workspace, under your control.</h2>
            </div>
            <p>
              Arrange windows, switch projects, and see what your agents do.
              Workspace control and action history stay on your Mac.
              Optional vision-model features may send screen context to the
              provider you choose. Lattices is open source, so you can inspect
              how it works.
            </p>
          </div>
        </section>

        <section className="home-sec install-chooser fade-in" id="install">
          <div className="install-chooser-head">
            <h2>Make yourself at home.</h2>
            <p>Get Lattices for your Mac. Everything else is optional.</p>
          </div>
          <div className="install-main">
            <div className="install-download">
              <div className="install-app-mark"><LatticesMark width={48} height={48} aria-hidden="true" /></div>
              <h3>Lattices for Mac</h3>
              <p>Your windows, projects, and tools. A little more together.</p>
              <a className="install-primary" href={latticesDownloadURL}
                onClick={() => trackCta('download_dmg_install', latticesDownloadURL)}>
                <DownloadIcon /> Download for Mac
              </a>
              <small>{latticesDownloadMeta}</small>
              <p className="install-directions">Open the download. Drag Lattices into Applications.</p>
            </div>
            <div className="install-brew">
              <div className="install-brew-title"><h3>Prefer Homebrew?</h3></div>
              <p>The same Mac app, installed from your terminal.</p>
              <div className="install-command install-copy-command">
                <code style={{ whiteSpace: "pre-wrap" }}>{brewCommand}</code>
                <button type="button" onClick={copyBrew} aria-label="Copy Homebrew install commands">{brewCopy}</button>
              </div>
              <small>Apple Silicon · macOS 26 or later</small>
              <span className="sr-only" role="status">{brewCopy === "Copied" ? "Homebrew commands copied" : ""}</span>
            </div>
            <div className="install-npm">
              <h3>Install with Bun</h3>
              <p>The command line for your workspace.</p>
              <div className="install-command install-copy-command">
                <code>bun install -g @lattices/lattices</code>
                <button type="button" onClick={copyInstall} aria-label="Copy Bun install command">{installCopy}</button>
              </div>
              <small>CLI {latticesCliVersion} · <a href="/docs/quickstart">Setup guide</a></small>
              <span className="sr-only" role="status">{installCopy === "Copied" ? "Command copied" : ""}</span>
            </div>
          </div>
          <details className="install-developer">
            <summary>Developer setup <span>Agent skills &amp; API</span></summary>
            <div className="install-developer-options">
              <div><h3>Agent skills</h3><code>npx skills add lattices-dev/lattices</code><p>Teach your coding agent to use Lattices.</p><a href="/docs/agents">Agent setup →</a></div>
              <div><h3>Typed API</h3><code>npm i @lattices/lattices</code><p>Build scripts and integrations for your workspace.</p><a href="/docs/api">API reference →</a></div>
            </div>
          </details>
        </section>

        {/* CTA */}
        <section className="cta">
          <h2>Put your whole desktop to work.</h2>
          <p>Free and open source. Running on your Mac in seconds.</p>
          <div className="cta-download-row">
            <a
              href={latticesDownloadURL}
              className="cta-download-button"
              onClick={() => trackCta('download_dmg', latticesDownloadURL)}
            >
              <span className="cta-download-icon">
                <AppleIcon />
              </span>
              <span className="cta-download-copy">
                <span>Download for macOS</span>
                <span className="cta-download-meta">{latticesDownloadMeta}</span>
              </span>
              <span className="cta-download-go" aria-hidden="true">
                <DownloadIcon />
              </span>
            </a>
          </div>
          <div className="cta-actions">
            <a
              href="https://github.com/lattices-dev/lattices"
              target="_blank"
              rel="noopener noreferrer"
              className="btn btn-secondary"
              onClick={() => trackCta('view_github', 'https://github.com/lattices-dev/lattices')}
            >
              View on GitHub
            </a>
            <a
              href="https://www.npmjs.com/package/@lattices/lattices"
              target="_blank"
              rel="noopener noreferrer"
              className="btn btn-secondary"
              onClick={() => trackCta('view_npm', 'https://www.npmjs.com/package/@lattices/lattices')}
            >
              CLI package
            </a>
            <a
              href="/docs/api"
              className="btn btn-secondary"
              onClick={() => trackCta('view_api', '/docs/api')}
            >
              API Reference
            </a>
          </div>
        </section>

        </div>
      </main>
      <SiteFooter current="/" className="site-footer-content-rail" />
    </>
  );
}
