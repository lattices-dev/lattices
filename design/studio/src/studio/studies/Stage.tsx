"use client";

/**
 * Stage — the things that appear over the desktop.
 *
 * One live desktop drives the whole system, then each choice from
 * StageLayout.swift / StageModeController.swift is drawn twice on the same
 * desktop: the behavior that ships today, and one other behavior. The study
 * does not pick between them.
 */

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Minus, Plus } from "lucide-react";
import type { LatticesPage } from "@/studio/studioRegistry";
import {
  Desktop,
  Island,
  IslandCount,
  PALETTE_WINDOW,
  SPACES,
  STAGE_KEYFRAMES,
  SpaceSwitcher,
  SpaceSwitcherInSlot,
  SuggestionCard,
  SuggestionPill,
  WINDOWS,
  Win,
  type DemoWindow,
} from "./stage/desktop";
import {
  engaged,
  fillFrame,
  gridHomes,
  gutterFrames,
  makeRoomFrames,
  shippedColumns,
  shippedFrames,
  shippedHomes,
  squareColumns,
  squareFrames,
  type Rect,
} from "./stage/layout";

const MAX = WINDOWS.length;

function shapeLabel(count: number, cols: number) {
  return `${cols}×${Math.ceil(count / cols)}`;
}

/** Windows on a stage: the forward one on top, the rest in grid order. */
function StageWindows({
  wins,
  frames,
  active,
  onPick,
}: {
  wins: DemoWindow[];
  frames: Rect[];
  active: number;
  onPick?: (index: number) => void;
}) {
  return (
    <>
      {wins.map((win, i) => (
        <Win
          key={win.app}
          win={win}
          frame={frames[i] ?? win.home}
          forward={i === active}
          z={i === active ? 20 : 2 + i}
          onClick={onPick ? () => onPick(i) : undefined}
        />
      ))}
    </>
  );
}

function Scattered({ wins }: { wins: DemoWindow[] }) {
  return (
    <>
      {wins.map((win, i) => (
        <Win key={win.app} win={win} frame={win.home} z={2 + i} />
      ))}
    </>
  );
}

// ── the live desktop ─────────────────────────────────────────────────────

/** How long the desk holds the switcher. The app's is shorter; this one has to be read. */
const SWITCHER_MS = 2600;

function useSwitcher() {
  const [space, setSpace] = useState(2);
  const [from, setFrom] = useState<number | null>(null);
  const [showing, setShowing] = useState(false);
  const [seq, setSeq] = useState(0);
  const go = useCallback(
    (delta: number) => {
      const next = Math.min(Math.max(space + delta, 0), SPACES.length - 1);
      setFrom(next === space ? null : space);
      setSpace(next);
      setShowing(true);
      setSeq((s) => s + 1);
      return { space: next, moved: next !== space };
    },
    [space],
  );
  useEffect(() => {
    if (!showing) return;
    const t = window.setTimeout(() => setShowing(false), SWITCHER_MS);
    return () => window.clearTimeout(t);
  }, [showing, seq]);
  return { space, from, showing, go };
}

type Switcher = ReturnType<typeof useSwitcher>;

function plural(n: number) {
  return `${n} ${n === 1 ? "window" : "windows"}`;
}

function LiveDesktop({
  count,
  active,
  setActive,
  setCount,
  switcher,
}: {
  count: number;
  active: number;
  setActive: (index: number) => void;
  setCount: (count: number) => void;
  switcher: Switcher;
}) {
  const [on, setOn] = useState(false);
  const [offered, setOffered] = useState(true);
  const wins = WINDOWS.slice(0, count);
  const cols = shippedColumns(count);
  const forward = wins[active]?.app ?? "A window";

  // The sentence next to the buttons says what the last thing you did changed.
  const [note, setNote] = useState("Stage is off. The card at the top is an offer: Tile turns Stage on, Not now removes it.");

  const enter = useCallback(
    (how: string) => {
      setOn(true);
      setOffered(false);
      setNote(`${how} Stage is on. ${forward} is forward. Click another window to bring it forward.`);
    },
    [forward],
  );
  const leave = useCallback(() => {
    setOn(false);
    setNote("Stage is off. Every window went back where it was.");
  }, []);
  const notNow = useCallback(() => {
    setOffered(false);
    setNote("Not now removed the card. Stage is still off. Offer again brings the card back.");
  }, []);
  const timedOut = useCallback(() => {
    setOffered(false);
    setNote("The offer ran out. Stage is still off. Offer again brings the card back.");
  }, []);
  const pick = useCallback(
    (index: number) => {
      setActive(index);
      setNote(
        index === active
          ? `${wins[index]?.app} is already forward.`
          : `${wins[index]?.app} came forward. ${wins[active]?.app} went back to its cell.`,
      );
    },
    [active, setActive, wins],
  );
  const desktop = useCallback(
    (delta: number) => {
      const { space, moved } = switcher.go(delta);
      const where = `Desktop ${space + 1} of ${SPACES.length}.`;
      setNote(
        moved
          ? `${where} The switcher shows it, then leaves on its own.`
          : `${where} There is no desktop ${delta < 0 ? "before" : "after"} it, so nothing moved.`,
      );
    },
    [switcher],
  );

  const recount = useCallback(
    (delta: number) => {
      const next = Math.min(Math.max(count + delta, 1), MAX);
      setCount(next);
      if (next === count) {
        setNote(`${plural(count)} is the ${delta < 0 ? "fewest" : "most"} this desk draws.`);
        return;
      }
      const shape = shapeLabel(next, shippedColumns(next));
      const what = delta > 0 ? `${WINDOWS[next - 1].app} opened` : `${WINDOWS[count - 1].app} closed`;
      setNote(
        on
          ? `${what}. Stage regrids ${plural(next)} ${shape}.`
          : offered
            ? `${what}. The card now offers ${plural(next)} in a ${shape} grid.`
            : `${what}. ${plural(next)} on the desk. Stage is off.`,
      );
    },
    [count, on, offered, setCount],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLElement && /input|textarea/i.test(e.target.tagName)) return;
      if (e.key === "Escape" && on) leave();
      if (e.key === "x" || e.key === "X") (on ? leave() : enter("X pressed."));
      if (!on) return;
      if (e.key === "ArrowRight") pick((active + 1) % count);
      if (e.key === "ArrowLeft") pick((active - 1 + count) % count);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [on, active, count, enter, leave, pick]);

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-2 font-mono text-[11px] text-studio-ink-faint">
        <Button onClick={() => (on ? leave() : enter(""))}>{on ? "Leave Stage" : "Enter Stage"} · X</Button>
        {!on && !offered ? (
          <Button
            onClick={() => {
              setOffered(true);
              setNote("The card is back. Tile turns Stage on, Not now removes it.");
            }}
          >
            Offer again
          </Button>
        ) : null}
        <span className="mx-1 h-4 w-px bg-studio-rule" />
        <Button onClick={() => desktop(-1)}>‹ desktop</Button>
        <Button onClick={() => desktop(1)}>desktop ›</Button>
        <span className="mx-1 h-4 w-px bg-studio-rule" />
        <span>windows</span>
        <Button onClick={() => recount(-1)} label="Fewer windows">
          <Minus size={12} />
        </Button>
        <span className="w-4 text-center text-[13px] text-studio-ink-strong">{count}</span>
        <Button onClick={() => recount(1)} label="More windows">
          <Plus size={12} />
        </Button>
      </div>
      <p aria-live="polite" className="mb-3 min-h-[1.6em] text-[14px] text-studio-ink-strong">
        {note.trim()}
      </p>
      <Desktop
        overlay={
          <>
            {on ? (
              <Island
                count={count}
                forward={forward}
                onHover={(hovering) => {
                  if (hovering) setNote(`The island opened: ${plural(count)}, ${forward} forward, and Esc or Hyper+X leaves.`);
                }}
              />
            ) : offered ? (
              <SuggestionCard
                key={count}
                names={wins.map((w) => w.app)}
                cells={shippedHomes(count)}
                shape={shapeLabel(count, cols)}
                onTile={() => enter("Tile applied the plan.")}
                onDismiss={notNow}
                onTimeout={timedOut}
              />
            ) : null}
            {switcher.showing ? <SpaceSwitcher current={switcher.space} from={switcher.from} /> : null}
          </>
        }
      >
        {on ? (
          <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} onPick={pick} />
        ) : (
          <Scattered wins={wins} />
        )}
      </Desktop>
    </div>
  );
}

// ── the choices ──────────────────────────────────────────────────────────

function Choice({
  n,
  title,
  decides,
  source,
  children,
}: {
  n: number;
  title: string;
  decides: string;
  source?: string;
  children: ReactNode;
}) {
  return (
    <section className="border-t border-studio-rule py-9">
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-[11px] text-studio-ink-faint">{String(n).padStart(2, "0")}</span>
        <h2 className="text-[20px] font-medium text-studio-ink-strong">{title}</h2>
        {source ? <code className="ml-auto font-mono text-[10.5px] text-studio-ink-faint">{source}</code> : null}
      </div>
      <p className="mt-2 max-w-[72ch] text-[14px] leading-[1.65] text-studio-ink">{decides}</p>
      <div className="mt-5 grid gap-6 lg:grid-cols-2">{children}</div>
    </section>
  );
}

function Panel({ label, caption, children }: { label: string; caption: ReactNode; children: ReactNode }) {
  return (
    <figure className="m-0">
      <div className="mb-2 font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">{label}</div>
      {/* A drawing: it follows the desk above and takes no clicks, hovers or focus. */}
      <div inert>{children}</div>
      <figcaption className="mt-2.5 max-w-[60ch] text-[13px] leading-[1.6] text-studio-ink-faint">{caption}</figcaption>
    </figure>
  );
}

const TODAY = "Ships today";
const OTHER = "Another behavior";
const SPEC = "As specified";

/** The offer, drawn: no timer, the line stopped part way. */
function OfferDrawing({ count, variant }: { count: number; variant: "card" | "pill" }) {
  const wins = WINDOWS.slice(0, count);
  return (
    <Desktop
      overlay={
        variant === "card" ? (
          <SuggestionCard
            still
            names={wins.map((w) => w.app)}
            cells={shippedHomes(count)}
            shape={shapeLabel(count, shippedColumns(count))}
          />
        ) : (
          <SuggestionPill count={count} />
        )
      }
    >
      <Scattered wins={wins} />
    </Desktop>
  );
}

/** The switcher, drawn over a stage, on the desk's current desktop. */
function SwitcherDrawing({
  count,
  active,
  space,
  variant,
}: {
  count: number;
  active: number;
  space: number;
  variant: "moment" | "slot";
}) {
  const wins = WINDOWS.slice(0, count);
  return (
    <Desktop
      overlay={
        variant === "slot" ? (
          <SpaceSwitcherInSlot current={space} />
        ) : (
          <>
            <Island count={count} forward={wins[active]?.app ?? ""} />
            <SpaceSwitcher current={space} from={null} />
          </>
        )
      }
    >
      <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
    </Desktop>
  );
}

const MOMENTS = [
  {
    id: "stage",
    name: "Stage",
    kind: "A mode you turn on",
    you: "You press Hyper+X because you want to work in one window without losing the others.",
    lattices: "The window you are in grows and comes forward. The rest stay in a grid behind it. A small island at the top says Stage.",
    leave: "Hyper+X or Escape puts every window back where it was. The island goes away.",
  },
  {
    id: "offer",
    name: "Suggestion",
    kind: "An offer, not a mode",
    you: "You did not ask for a new layout. A window landed on top of another, or one opened or closed.",
    lattices: "While Stage is off, a card draws the tidy it would do and waits. Nothing moves.",
    leave: "Tile applies that drawing. Not now, or letting the coral line run out, drops it.",
  },
  {
    id: "spaces",
    name: "Space switcher",
    kind: "A reply to a key you already pressed",
    you: "You moved to another desktop. This is about Spaces, not about arranging the windows on one screen.",
    lattices: "A strip shows which desktop you are on, and the ones beside it, then it leaves on its own.",
    leave: "You do not accept or dismiss it. At the first desktop, previous does nothing. At the last, next does nothing.",
  },
] as const;

function Tutorial() {
  const [id, setId] = useState<(typeof MOMENTS)[number]["id"]>("stage");
  const moment = MOMENTS.find((item) => item.id === id) ?? MOMENTS[0];
  return (
    <section className="max-w-[820px] py-8">
      <h2 className="text-[18px] font-medium text-studio-ink-strong">Three different jobs</h2>
      <p className="mt-2 max-w-[66ch] text-[14px] leading-[1.65] text-studio-ink">
        Only Stage is a mode. The suggestion and the space switcher are not other settings of
        Stage. One slot at the top of the screen holds either the Stage island or the suggestion,
        never both. The switcher is its own moment and does not sit in that slot.
      </p>
      <div className="mt-5 flex flex-wrap gap-2">
        {MOMENTS.map((item) => (
          <button
            key={item.id}
            type="button"
            onClick={() => setId(item.id)}
            className="rounded-full border px-3 py-1.5 text-[13px]"
            style={{
              borderColor: item.id === id ? "#ef6a47" : "var(--color-studio-rule, #333)",
              color: item.id === id ? "#ef6a47" : "inherit",
            }}
          >
            {item.name}
          </button>
        ))}
      </div>
      <div className="mt-4 rounded-md border border-studio-rule px-5 py-4">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">{moment.kind}</div>
        <h3 className="mt-2 text-[20px] font-medium text-studio-ink-strong">{moment.name}</h3>
        <dl className="mt-4 space-y-3 text-[14px] leading-[1.6]">
          <div>
            <dt className="text-studio-ink-faint">You</dt>
            <dd className="text-studio-ink">{moment.you}</dd>
          </div>
          <div>
            <dt className="text-studio-ink-faint">Lattices</dt>
            <dd className="text-studio-ink">{moment.lattices}</dd>
          </div>
          <div>
            <dt className="text-studio-ink-faint">How it ends</dt>
            <dd className="text-studio-ink">{moment.leave}</dd>
          </div>
        </dl>
      </div>
    </section>
  );
}

function Button({ onClick, label, children }: { onClick: () => void; label?: string; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className="flex items-center rounded-md border border-studio-rule px-2.5 py-1 font-mono text-[11px] text-studio-ink hover:bg-studio-chip-bg"
    >
      {children}
    </button>
  );
}

// ── page ─────────────────────────────────────────────────────────────────

export function StageStudy({ page }: { page: LatticesPage }) {
  const [count, setCount] = useState(5);
  const [activeRaw, setActive] = useState(1);
  const active = Math.min(activeRaw, count - 1);
  const wins = WINDOWS.slice(0, count);
  const switcher = useSwitcher();

  // Who joins: today every titled window on the display; the palette never does.
  const joinedToday = wins;
  const joinedLayer = wins.filter((w) => w.layer);
  const layerActive = Math.min(active, Math.max(0, joinedLayer.length - 1));

  return (
    <main className="w-full px-6 py-10 lg:px-7">
      <style>{STAGE_KEYFRAMES}</style>

      <header className="max-w-[980px] border-b border-studio-rule pb-7">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-studio-ink-faint">
          {page.bucket} / {page.surface}
        </div>
        <h1 className="mt-4 text-[36px] font-medium leading-tight text-studio-ink-strong">{page.label}</h1>
        <p className="mt-4 max-w-[66ch] text-[15px] leading-[1.7] text-studio-ink">
          The desk below is a drawing with invented windows: it is not your Mac, and it is not
          /studio/live. Click <b className="font-medium text-studio-ink-strong">Enter Stage</b> first.
        </p>
      </header>

      <section className="py-6">
        <div className="max-w-[1180px]">
          <LiveDesktop count={count} active={active} setActive={setActive} setCount={setCount} switcher={switcher} />
        </div>
        <p className="mt-3 max-w-[72ch] text-[13px] leading-[1.6] text-studio-ink-faint">
          While Stage is on, click a window, or use the arrow keys, to bring another one forward.
          Hover the island at the top for the count and how to leave. Escape or X leaves. With
          Stage off, the card at the top is the suggestion. The desktop buttons show the space switcher.
        </p>
      </section>

      <section className="max-w-[820px] py-8">
        <div className="font-mono text-[10px] uppercase tracking-eyebrow text-[#ef6a47]">Direction</div>
        <h2 className="mt-2 text-[18px] font-medium text-studio-ink-strong">Several layouts, around the window you just took</h2>
        <p className="mt-3 max-w-[66ch] text-[14px] leading-[1.65] text-studio-ink">
          Add a window or move one, and Lattices offers a few layouts right then. You pick one.
          Throw the focus onto a window and that window stays frontmost. The others move around
          it. A useful proposal keeps the windows that belong with that one close to it, and lets
          the rest sit farther out.
        </p>
        <p className="mt-3 max-w-[66ch] text-[14px] leading-[1.65] text-studio-ink">
          One card that appears and then expires is not this. A fixed grid that treats every
          window the same is not this. The rows below are the pieces that combination is made of.
        </p>
      </section>

      <Tutorial />

      <div className="max-w-[1180px]">
        <h2 className="text-[18px] font-medium text-studio-ink-strong">Choices inside Stage</h2>
        <p className="mt-2 mb-2 max-w-[66ch] text-[14px] leading-[1.65] text-studio-ink">
          These rows are not more modes. They are the rules Stage uses once it is on. The left
          frame is what the app does today. The right frame is another way that rule could work.
          The study does not pick. The frames are drawings: they follow the desk above (its window
          count, forward window and desktop) and take no clicks.
        </p>
        <Choice
          n={1}
          title="Columns"
          source="StageLayout.columns(for:)"
          decides="How many columns the set gets for a given count, and where a short last row sits. Dashed outlines are the home cells."
        >
          <Panel label={TODAY} caption="1 window is 1 column; 2 or 4 are 2 columns; every other count is 3. A short last row is centered.">
            <Desktop grid={shippedHomes(count)}>
              <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
          <Panel
            label={OTHER}
            caption={`Columns are ⌈√n⌉, so the grid stays near square (${shapeLabel(count, squareColumns(count))} here). A short last row stretches to the edges instead of centering.`}
          >
            <Desktop grid={gridHomes(count, squareColumns(count), "stretch")}>
              <StageWindows wins={wins} frames={squareFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={2}
          title="Engaged window"
          source="StageLayout.engaged(around:)"
          decides="How big the window you are in becomes, and what happens to the windows next to it."
        >
          <Panel label={TODAY} caption="Always 40% of the display wide and 86% tall, centered on its cell and kept on screen. It covers its neighbors.">
            <Desktop grid={shippedHomes(count)}>
              <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
          <Panel label={OTHER} caption="Its column widens to half the display and its row to 70%. The neighbors give up that room, so nothing is covered.">
            <Desktop>
              <StageWindows wins={wins} frames={makeRoomFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={3}
          title="Resting windows"
          source="StageLayout.restScale"
          decides="How much of its cell a window keeps while another one is forward."
        >
          <Panel label={TODAY} caption="84% of their cell, centered in it. The gap grows with the cell.">
            <Desktop grid={shippedHomes(count)}>
              <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
          <Panel label={OTHER} caption="The whole cell less a fixed gutter, the same at every count. Resting windows stay as large as the grid allows.">
            <Desktop grid={shippedHomes(count)}>
              <StageWindows wins={wins} frames={gutterFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={4}
          title="Who joins"
          source="StageModeController.isStageWindow"
          decides="Which windows Stage takes into the grid when it starts. The small untitled panel top right is a color picker."
        >
          <Panel
            label={TODAY}
            caption="Every titled window on that display, 200×160 or larger. The untitled picker stays where it was."
          >
            <Desktop>
              <Win win={PALETTE_WINDOW} frame={PALETTE_WINDOW.home} z={1} />
              <StageWindows wins={joinedToday} frames={shippedFrames(joinedToday.length, active)} active={active} />
            </Desktop>
          </Panel>
          <Panel
            label={OTHER}
            caption={`Only the windows in the active layer, tideline: ${joinedLayer.map((w) => w.app).join(", ") || "none at this count"}. The rest stay where they were, behind the stage.`}
          >
            <Desktop>
              <Win win={PALETTE_WINDOW} frame={PALETTE_WINDOW.home} z={1} />
              {wins
                .filter((w) => !w.layer)
                .map((win) => (
                  <Win key={win.app} win={win} frame={win.home} muted z={1} />
                ))}
              <StageWindows
                wins={joinedLayer}
                frames={shippedFrames(joinedLayer.length, layerActive)}
                active={layerActive}
              />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={5}
          title="One window"
          source="StageLayout.columns(for: 1)"
          decides="What Stage does when the display holds a single window."
        >
          <Panel label={TODAY} caption="Still the 40% by 86% tile, centered. The rest of the display stays empty.">
            <Desktop overlay={<Island count={1} forward={WINDOWS[0].app} />}>
              <StageWindows wins={[WINDOWS[0]]} frames={[engaged({ x: 0, y: 0, w: 1, h: 1 })]} active={0} />
            </Desktop>
          </Panel>
          <Panel label={OTHER} caption="The window fills the visible frame less a margin. One window has no neighbors to make room for.">
            <Desktop overlay={<Island count={1} forward={WINDOWS[0].app} />}>
              <StageWindows wins={[WINDOWS[0]]} frames={[fillFrame()]} active={0} />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={6}
          title="The island"
          source="StageIndicatorPanel"
          decides="What the top slot says while Stage is on. The left frame is drawn hovered; hover the island on the desk above to open it there."
        >
          <Panel
            label={SPEC}
            caption="At rest, the word Stage and a coral dot. On hover, the count, which window is forward, and that Escape or Hyper+X leaves. The running build draws the rest state only and ignores the pointer."
          >
            <Desktop overlay={<Island count={count} forward={wins[active]?.app ?? ""} expanded />}>
              <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
          <Panel label={OTHER} caption="The position is always on the island, 2 of 5, and hovering does nothing. Leaving is not written anywhere.">
            <Desktop overlay={<IslandCount index={active} count={count} />}>
              <StageWindows wins={wins} frames={shippedFrames(count, active)} active={active} />
            </Desktop>
          </Panel>
        </Choice>

        <Choice
          n={7}
          title="The suggestion card"
          decides="How Stage is offered before you ask for it. Only while Stage is off, in the island's top slot, so the two never stack."
        >
          <Panel
            label={SPEC}
            caption="A one-line decision, the map of where each window lands, Tile and Not now. Tile applies the plan. Not now drops it. The coral line drains as the offer times out, and holds while the pointer is on the card. Not in the running build; the frames are in docs/designs/layout-suggestions. The card on the desk above is the live one."
          >
            <OfferDrawing count={count} variant="card" />
          </Panel>
          <Panel label={OTHER} caption="The offer is the island, unlit: a hollow coral ring and the count. A click on it applies the plan. There is no map and no Not now; it fades on its own.">
            <OfferDrawing count={count} variant="pill" />
          </Panel>
        </Choice>

        <Choice
          n={8}
          title="The space switcher"
          source="SpaceSwitchBezel.swift"
          decides="Where the desktop switcher appears while Stage is on, and how it relates to the island."
        >
          <Panel
            label={SPEC}
            caption="Its own moment: centered, in the same ink and coral, gone within a second (the desk above holds it 2.6 s so you can read it). The island holds the top slot the whole time. The running build still draws the gray filmstrip with a cyan edge."
          >
            <SwitcherDrawing count={count} active={active} space={switcher.space} variant="moment" />
          </Panel>
          <Panel label={OTHER} caption="The switcher takes the top slot. The island steps aside while it shows and comes back when it leaves. One slot holds everything.">
            <SwitcherDrawing count={count} active={active} space={switcher.space} variant="slot" />
          </Panel>
        </Choice>

        <p className="border-t border-studio-rule pt-5 font-mono text-[11px] leading-relaxed text-studio-ink-faint">
          Windows are drawn to scale on a 1440×900 display. In the smaller frames the overlays are drawn larger than scale so their type stays readable.
        </p>
      </div>
    </main>
  );
}
