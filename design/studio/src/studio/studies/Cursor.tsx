"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode, type RefObject } from "react";
import { daemonCall } from "@/studio/lib/daemon";
import type { LatticesPage } from "@/studio/studioRegistry";
import { DaemonConnection } from "@/studio/lib/DaemonConnection";

const MARKER_STROKE = "#DDE2EA";
const GRAPHITE = "#0B0C0F";
const SAMPLE_TYPING_MESSAGE = "hello from lattices";

type StageKey = "terminal" | "canvas" | "light";
type CursorShapeId = "chevron" | "facet" | "shard" | "wedge" | "prism" | "notch";
type CursorSizeId = "small" | "regular" | "large";
type PreviewTreatment = "rest" | "click" | "typing";
type SimulationState = "idle" | "click" | "typing";
type TypingSound = "quiet" | "creamy" | "hard";
type ClickSound = "quiet" | "click";

interface CursorStudyProps {
  entry: LatticesPage;
}

interface CursorResponse {
  shown?: boolean;
  cursor?: { x?: number; y?: number };
  run?: { id?: string };
  appearance?: {
    style?: string;
    color?: string;
    durationMs?: number;
    label?: string;
    shape?: string;
    angleDeg?: number;
    size?: string;
    scale?: number;
  };
}

interface CursorSettingsResponse {
  shape?: string;
  angleDeg?: number;
  size?: string;
  scale?: number;
}

interface ShapeOption {
  id: CursorShapeId;
  label: string;
  detail: string;
  points: MarkerPoint[];
  path: string;
}

interface MarkerPoint {
  x: number;
  y: number;
  r: number;
}

const STAGES: { key: StageKey; label: string; detail: string }[] = [
  { key: "terminal", label: "Terminal", detail: "dark + dense" },
  { key: "canvas", label: "Canvas", detail: "studio dark" },
  { key: "light", label: "Light", detail: "bright surface" },
];

const DURATIONS = [2500, 5000, 10000];
const ANGLES = [-8, -16];
const SIZE_OPTIONS: { id: CursorSizeId; label: string; scale: number }[] = [
  { id: "small", label: "Small", scale: 0.78 },
  { id: "regular", label: "Regular", scale: 1 },
  { id: "large", label: "Large", scale: 1.16 },
];
const TYPING_SOUNDS: { id: TypingSound; label: string }[] = [
  { id: "quiet", label: "Quiet" },
  { id: "creamy", label: "Creamy" },
  { id: "hard", label: "Hard" },
];
const CLICK_SOUNDS: { id: ClickSound; label: string }[] = [
  { id: "quiet", label: "Quiet" },
  { id: "click", label: "Click" },
];

let sharedAudioContext: AudioContext | null = null;

function getAudioContext() {
  const audioWindow = window as Window & typeof globalThis & { webkitAudioContext?: typeof AudioContext };
  const AudioContextCtor = window.AudioContext ?? audioWindow.webkitAudioContext;
  if (!AudioContextCtor) return null;
  if (!sharedAudioContext || sharedAudioContext.state === "closed") {
    sharedAudioContext = new AudioContextCtor();
  }
  return sharedAudioContext;
}

function previewTypingSound(profile: TypingSound) {
  if (profile === "quiet") return;
  const context = getAudioContext();
  if (!context) return;
  void context.resume().then(() => {
    let offsetMs = 20;
    for (let index = 0; index < SAMPLE_TYPING_MESSAGE.length; index += 1) {
      const char = SAMPLE_TYPING_MESSAGE[index]!;
      offsetMs += typingDelayMs(SAMPLE_TYPING_MESSAGE, index);
      playKeyTap(context, profile, context.currentTime + offsetMs / 1000, index, char);
    }
  }).catch(() => {});
}

function playTypingTapNow(profile: TypingSound, index: number, char: string) {
  if (profile === "quiet") return;
  const context = getAudioContext();
  if (!context) return;
  void context.resume().then(() => {
    playKeyTap(context, profile, context.currentTime + 0.004, index, char);
  }).catch(() => {});
}

function previewClickSound(profile: ClickSound) {
  if (profile === "quiet") return;
  const context = getAudioContext();
  if (!context) return;
  void context.resume().then(() => {
    playNoiseBurst(context, context.currentTime + 0.01, 0.018, 0.08, "highpass");
    playTone(context, 520, context.currentTime + 0.012, 0.024, 0.028, "triangle");
  }).catch(() => {});
}

function typingDelayMs(message: string, index: number) {
  const char = message[index] ?? "";
  const previous = message[index - 1] ?? "";
  const next = message[index + 1] ?? "";
  const cadence = [96, 82, 106, 90, 118, 78, 100, 112, 86, 104, 94, 122];
  let delay = cadence[index % cadence.length]!;

  if (index === 0) delay += 60;
  if (previous === " ") delay += 24;
  if (next === " ") delay += 18;
  if (char === " ") delay += 86;
  if (/[.,;:!?]/.test(char)) delay += 118;
  if (/[A-Z]/.test(char)) delay += 22;

  return delay;
}

function playKeyTap(context: AudioContext, profile: TypingSound, start: number, index: number, char: string) {
  const isSpace = char === " ";
  if (profile === "creamy") {
    const frequency = (isSpace ? 148 : 176) + (index % 4) * 8;
    playTone(context, frequency, start, 0.058, isSpace ? 0.022 : 0.034, "triangle");
    playTone(context, frequency * 1.56, start + 0.006, 0.038, isSpace ? 0.007 : 0.012, "sine");
    playNoiseBurst(context, start, 0.026, isSpace ? 0.016 : 0.026, "lowpass");
    return;
  }

  const frequency = (isSpace ? 178 : 226) + (index % 3) * 7;
  playTone(context, frequency, start, 0.026, isSpace ? 0.008 : 0.014, "triangle");
  playTone(context, frequency * 1.38, start + 0.004, 0.018, isSpace ? 0.003 : 0.005, "sine");
  playNoiseBurst(context, start, 0.014, isSpace ? 0.01 : 0.017, "bandpass");
}

function playTone(
  context: AudioContext,
  frequency: number,
  start: number,
  duration: number,
  gainValue: number,
  type: OscillatorType,
) {
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  oscillator.type = type;
  oscillator.frequency.setValueAtTime(frequency, start);
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(gainValue, start + 0.006);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
  oscillator.connect(gain);
  gain.connect(context.destination);
  oscillator.start(start);
  oscillator.stop(start + duration + 0.01);
}

function playNoiseBurst(
  context: AudioContext,
  start: number,
  duration: number,
  gainValue: number,
  filterType: BiquadFilterType,
) {
  const sampleCount = Math.max(1, Math.floor(context.sampleRate * duration));
  const buffer = context.createBuffer(1, sampleCount, context.sampleRate);
  const data = buffer.getChannelData(0);
  for (let index = 0; index < sampleCount; index += 1) {
    const fade = 1 - index / sampleCount;
    data[index] = (Math.random() * 2 - 1) * fade * fade;
  }

  const source = context.createBufferSource();
  const filter = context.createBiquadFilter();
  const gain = context.createGain();
  filter.type = filterType;
  filter.frequency.setValueAtTime(filterType === "lowpass" ? 680 : filterType === "bandpass" ? 940 : 1800, start);
  filter.Q.setValueAtTime(filterType === "bandpass" ? 0.65 : 1, start);
  gain.gain.setValueAtTime(gainValue, start);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
  source.buffer = buffer;
  source.connect(filter);
  filter.connect(gain);
  gain.connect(context.destination);
  source.start(start);
}

function wait(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function makeShape(id: CursorShapeId, label: string, detail: string, points: MarkerPoint[]): ShapeOption {
  return {
    id,
    label,
    detail,
    points,
    path: roundedPolygonPath(points),
  };
}

function makeSymmetricShape(
  id: CursorShapeId,
  label: string,
  detail: string,
  leftPoints: MarkerPoint[],
  centerPoint?: MarkerPoint,
): ShapeOption {
  const points = [
    { x: 110, y: 112, r: 1.5 },
    ...leftPoints,
    ...(centerPoint ? [centerPoint] : []),
    ...[...leftPoints].reverse().map((point) => ({
      x: 220 - point.x,
      y: point.y,
      r: point.r,
    })),
  ];
  return makeShape(id, label, detail, points);
}

function roundedPolygonPath(points: MarkerPoint[]) {
  const corners = points.map((point, index) => {
    const previous = points[(index - 1 + points.length) % points.length]!;
    const next = points[(index + 1) % points.length]!;
    const previousDistance = distance(point, previous);
    const nextDistance = distance(point, next);
    const inset = Math.min(point.r, previousDistance * 0.44, nextDistance * 0.44);
    return {
      control: point,
      incoming: pointAlong(point, previous, inset),
      outgoing: pointAlong(point, next, inset),
    };
  });

  const first = corners[0]!;
  const commands = [`M${formatPoint(first.outgoing)}`];
  for (let index = 1; index < corners.length; index += 1) {
    const corner = corners[index]!;
    commands.push(`L${formatPoint(corner.incoming)}`);
    commands.push(`Q${formatPoint(corner.control)} ${formatPoint(corner.outgoing)}`);
  }
  commands.push(`L${formatPoint(first.incoming)}`);
  commands.push(`Q${formatPoint(first.control)} ${formatPoint(first.outgoing)}`);
  commands.push("Z");
  return commands.join(" ");
}

function pointAlong(from: MarkerPoint, to: MarkerPoint, amount: number) {
  const length = distance(from, to);
  if (length <= 0.001 || amount <= 0) return { x: from.x, y: from.y };
  return {
    x: from.x + ((to.x - from.x) / length) * amount,
    y: from.y + ((to.y - from.y) / length) * amount,
  };
}

function distance(a: Pick<MarkerPoint, "x" | "y">, b: Pick<MarkerPoint, "x" | "y">) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function formatPoint(point: Pick<MarkerPoint, "x" | "y">) {
  return `${formatNumber(point.x)} ${formatNumber(point.y)}`;
}

function formatNumber(value: number) {
  return Number(value.toFixed(2)).toString();
}

const SHAPES: ShapeOption[] = [
  makeSymmetricShape("chevron", "Chevron", "soft angle", [
    { x: 79, y: 158, r: 7 },
    { x: 99, y: 155, r: 4.5 },
  ], { x: 110, y: 163, r: 5 }),
  makeSymmetricShape("facet", "Facet", "round facet", [
    { x: 78, y: 154, r: 7 },
    { x: 94, y: 166, r: 7 },
  ], { x: 110, y: 160, r: 5 }),
  makeSymmetricShape("shard", "Shard", "low shard", [
    { x: 84, y: 160, r: 6 },
    { x: 102, y: 157, r: 4 },
  ], { x: 110, y: 170, r: 5 }),
  makeSymmetricShape("wedge", "Wedge", "flat wedge", [
    { x: 72, y: 155, r: 7 },
    { x: 96, y: 168, r: 7 },
  ]),
  makeSymmetricShape("prism", "Prism", "folded", [
    { x: 77, y: 159, r: 7 },
    { x: 96, y: 168, r: 6 },
  ], { x: 110, y: 160, r: 4.5 }),
  makeSymmetricShape("notch", "Notch", "split", [
    { x: 77, y: 162, r: 7 },
    { x: 100, y: 157, r: 4.5 },
  ], { x: 110, y: 165, r: 5 }),
];

const SHAPE_BY_ID = new Map(SHAPES.map((shape) => [shape.id, shape]));
const PRIMARY_SHAPE_IDS: CursorShapeId[] = ["shard", "chevron"];
const PRIMARY_SHAPES = PRIMARY_SHAPE_IDS.map((id) => SHAPE_BY_ID.get(id)).filter(
  (shape): shape is ShapeOption => Boolean(shape),
);

export function CursorStudy({ entry }: CursorStudyProps) {
  const typingInputRef = useRef<HTMLInputElement | null>(null);
  const [stage, setStage] = useState<StageKey>("terminal");
  const [shapeId, setShapeId] = useState<CursorShapeId>("shard");
  const [angleDeg, setAngleDeg] = useState(-8);
  const [sizeId, setSizeId] = useState<CursorSizeId>("regular");
  const [previewTreatment, setPreviewTreatment] = useState<PreviewTreatment>("rest");
  const [simulationState, setSimulationState] = useState<SimulationState>("idle");
  const [typingSound, setTypingSound] = useState<TypingSound>("quiet");
  const [clickSound, setClickSound] = useState<ClickSound>("click");
  const [previewCycle, setPreviewCycle] = useState(0);
  const [label, setLabel] = useState("");
  const [durationMs, setDurationMs] = useState(5000);
  const [pending, setPending] = useState(false);
  const [typingRunPending, setTypingRunPending] = useState(false);
  const [typingRunCycle, setTypingRunCycle] = useState(0);
  const [typingTargetValue, setTypingTargetValue] = useState("");
  const [typingMessages, setTypingMessages] = useState<string[]>([]);
  const [settingsPending, setSettingsPending] = useState(false);
  const [settingsNote, setSettingsNote] = useState<string | null>(null);
  const [result, setResult] = useState<CursorResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const activeShape = SHAPE_BY_ID.get(shapeId) ?? SHAPES[0]!;
  const activeSize = SIZE_OPTIONS.find((size) => size.id === sizeId) ?? SIZE_OPTIONS[1]!;

  useEffect(() => {
    let cancelled = false;
    daemonCall<CursorSettingsResponse>("settings.cursorAppearance.get", null, 5_000)
      .then((settings) => {
        if (cancelled) return;
        if (isPrimaryShape(settings.shape)) {
          setShapeId(settings.shape);
        }
        if (typeof settings.angleDeg === "number" && ANGLES.includes(settings.angleDeg)) {
          setAngleDeg(settings.angleDeg);
        }
        if (isCursorSize(settings.size)) {
          setSizeId(settings.size);
        }
      })
      .catch(() => {
        if (!cancelled) setSettingsNote("Using studio defaults.");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function showOnDesktop() {
    if (pending) return;
    setPending(true);
    setError(null);
    setResult(null);
    try {
      const trimmed = label.trim();
      const response = await daemonCall<CursorResponse>(
        "computer.showCursor",
        {
          style: "marker",
          shape: shapeId,
          angleDeg,
          size: sizeId,
          color: "white",
          durationMs,
          label: trimmed || undefined,
          treatment: "present",
          source: "studio",
        },
        15_000,
      );
      setResult(response);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setPending(false);
    }
  }

  async function saveDefaults() {
    if (settingsPending) return;
    setSettingsPending(true);
    setSettingsNote(null);
    try {
      const response = await daemonCall<CursorSettingsResponse>(
        "settings.cursorAppearance.set",
        { shape: shapeId, angleDeg, size: sizeId },
        10_000,
      );
      if (isPrimaryShape(response.shape)) setShapeId(response.shape);
      if (typeof response.angleDeg === "number" && ANGLES.includes(response.angleDeg)) {
        setAngleDeg(response.angleDeg);
      }
      if (isCursorSize(response.size)) setSizeId(response.size);
      setSettingsNote("Defaults saved.");
    } catch (err) {
      setSettingsNote(err instanceof Error ? err.message : String(err));
    } finally {
      setSettingsPending(false);
    }
  }

  function isPrimaryShape(value: unknown): value is CursorShapeId {
    return typeof value === "string" && PRIMARY_SHAPE_IDS.includes(value as CursorShapeId);
  }

  function isCursorSize(value: unknown): value is CursorSizeId {
    return typeof value === "string" && SIZE_OPTIONS.some((size) => size.id === value);
  }

  function chooseTypingSound(nextSound: TypingSound) {
    setTypingSound(nextSound);
    if (simulationState === "idle") {
      setPreviewCycle((cycle) => cycle + 1);
      previewTypingSound(nextSound);
    }
  }

  function chooseClickSound(nextSound: ClickSound) {
    setClickSound(nextSound);
    if (simulationState === "idle") {
      setPreviewCycle((cycle) => cycle + 1);
      previewClickSound(nextSound);
    }
  }

  function commitTypingMessage(raw = typingTargetValue) {
    const message = raw.trim();
    if (!message) return;
    setTypingMessages((messages) => [message, ...messages].slice(0, 4));
    setTypingTargetValue("");
  }

  async function runTypingSample() {
    if (typingRunPending) return;
    setTypingRunPending(true);
    setSimulationState("typing");
    setPreviewTreatment("typing");
    setPreviewCycle((cycle) => cycle + 1);
    setTypingRunCycle((cycle) => cycle + 1);
    setTypingTargetValue("");
    typingInputRef.current?.focus();

    for (let index = 0; index < SAMPLE_TYPING_MESSAGE.length; index += 1) {
      const char = SAMPLE_TYPING_MESSAGE[index]!;
      await wait(typingDelayMs(SAMPLE_TYPING_MESSAGE, index));
      playTypingTapNow(typingSound, index, char);
      setTypingTargetValue((value) => `${value}${char}`);
    }

    await wait(160);
    commitTypingMessage(SAMPLE_TYPING_MESSAGE);
    await wait(260);
    setSimulationState("idle");
    setPreviewTreatment("rest");
    setTypingRunPending(false);
  }

  async function runClickSample() {
    if (typingRunPending) return;
    setSimulationState("click");
    setPreviewTreatment("click");
    setPreviewCycle((cycle) => cycle + 1);
    previewClickSound(clickSound);
    await wait(620);
    setSimulationState("idle");
    setPreviewTreatment("rest");
  }

  return (
    <main className="max-w-6xl px-6 py-8">
      <CursorStudyStyles />
      <header>
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          studio / cursor
        </p>
        <h1 className="mt-2 font-sans text-4xl font-medium tracking-tight text-studio-ink sm:text-5xl">
          {entry.label}
        </h1>
        <p className="mt-4 max-w-2xl text-[15px] leading-relaxed text-studio-ink-faint">
          A compact marker treatment for agentic pointer actions: stemless
          cursor head, flat angular body, graphite and off-white only.
        </p>
      </header>

      <section className="mt-8">
        <DaemonConnection />
      </section>

      <div className="mt-8 grid gap-6 lg:grid-cols-[minmax(0,1fr)_340px]">
        <section className="min-w-0 border border-studio-edge bg-[color:var(--studio-canvas)]">
          <div className="flex items-baseline justify-between border-b border-studio-edge px-4 py-3">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              Marker preview
            </p>
            <p className="font-mono text-[10px] text-studio-ink-faint">
              {activeShape.id} / {formatAngle(angleDeg)} / {activeSize.id} / {simulationState}
            </p>
          </div>
          <CursorStage
            stage={stage}
            label={label}
            shape={activeShape}
            angleDeg={angleDeg}
            sizeScale={activeSize.scale}
            treatment={previewTreatment}
            previewCycle={previewCycle}
          />
          <TypingTargetPanel
            inputRef={typingInputRef}
            value={typingTargetValue}
            messages={typingMessages}
            running={typingRunPending}
            runCycle={typingRunCycle}
            simulationState={simulationState}
            typingSound={typingSound}
            clickSound={clickSound}
            shape={activeShape}
            angleDeg={angleDeg}
            sizeScale={activeSize.scale}
            onChange={setTypingTargetValue}
            onCommit={commitTypingMessage}
            onClickSoundChange={chooseClickSound}
            onTypingSoundChange={chooseTypingSound}
            onRunClick={runClickSample}
            onRunSample={runTypingSample}
          />
        </section>

        <aside className="flex flex-col gap-5 border border-studio-edge bg-[color:var(--studio-canvas)] p-5">
          <ControlGroup title="Shape">
            <div className="grid grid-cols-2 gap-2">
              {PRIMARY_SHAPES.map((shape) => (
                <button
                  key={shape.id}
                  type="button"
                  onClick={() => setShapeId(shape.id)}
                  className={[
                    "grid min-h-[76px] grid-cols-[48px_minmax(0,1fr)] items-center gap-2 rounded-sm border px-2 py-2 text-left transition-colors",
                    shapeId === shape.id
                      ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                      : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                  ].join(" ")}
                >
                  <ShapeIcon shape={shape} />
                  <span className="min-w-0">
                    <span className="block truncate font-mono text-[10.5px] uppercase tracking-[0.16em]">
                      {shape.label}
                    </span>
                    <span className="mt-1 block truncate font-mono text-[9.5px] text-studio-ink-faint">
                      {shape.detail}
                    </span>
                  </span>
                </button>
              ))}
            </div>
          </ControlGroup>

          <ControlGroup title="Rotation">
            <div className="grid grid-cols-2 gap-2">
              {ANGLES.map((deg) => (
                <button
                  key={deg}
                  type="button"
                  onClick={() => setAngleDeg(deg)}
                  className={[
                    "rounded-sm border px-2 py-2 font-mono text-[10.5px] uppercase tracking-[0.12em] transition-colors",
                    angleDeg === deg
                      ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                      : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                  ].join(" ")}
                >
                  {formatAngle(deg)}
                </button>
              ))}
            </div>
          </ControlGroup>

          <ControlGroup title="Size">
            <div className="grid grid-cols-3 gap-2">
              {SIZE_OPTIONS.map((size) => (
                <button
                  key={size.id}
                  type="button"
                  onClick={() => setSizeId(size.id)}
                  className={[
                    "rounded-sm border px-2 py-2 font-mono text-[10.5px] uppercase tracking-[0.12em] transition-colors",
                    sizeId === size.id
                      ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                      : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                  ].join(" ")}
                >
                  {size.label}
                </button>
              ))}
            </div>
          </ControlGroup>

          <ControlGroup title="Defaults">
            <button
              type="button"
              onClick={saveDefaults}
              disabled={settingsPending}
              className="w-full rounded-sm border border-studio-edge px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-studio-ink-faint transition-colors hover:border-studio-ink-faint hover:text-studio-ink disabled:cursor-wait disabled:opacity-55"
            >
              {settingsPending ? "saving..." : "save as default"}
            </button>
            {settingsNote ? (
              <p className="mt-2 break-words font-mono text-[10px] text-studio-ink-faint">
                {settingsNote}
              </p>
            ) : null}
          </ControlGroup>

          <ControlGroup title="Surface">
            <div className="grid gap-2">
              {STAGES.map((item) => (
                <button
                  key={item.key}
                  type="button"
                  onClick={() => setStage(item.key)}
                  className={[
                    "flex items-baseline justify-between gap-3 rounded-sm border px-3 py-2 text-left transition-colors",
                    stage === item.key
                      ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                      : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                  ].join(" ")}
                >
                  <span className="font-mono text-[11px] uppercase tracking-[0.18em]">
                    {item.label}
                  </span>
                  <span className="font-mono text-[10px]">{item.detail}</span>
                </button>
              ))}
            </div>
          </ControlGroup>

          <ControlGroup title="Label">
            <input
              value={label}
              onChange={(event) => setLabel(event.target.value)}
              className="w-full rounded-sm border border-studio-edge bg-transparent px-3 py-2 font-mono text-[13px] text-studio-ink outline-none focus:border-[color:var(--scout-accent)]"
              placeholder="optional"
            />
          </ControlGroup>

          <ControlGroup title="Duration">
            <div className="grid grid-cols-3 gap-2">
              {DURATIONS.map((ms) => (
                <button
                  key={ms}
                  type="button"
                  onClick={() => setDurationMs(ms)}
                  className={[
                    "rounded-sm border px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] transition-colors",
                    durationMs === ms
                      ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                      : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
                  ].join(" ")}
                >
                  {ms / 1000}s
                </button>
              ))}
            </div>
          </ControlGroup>

          <button
            type="button"
            onClick={showOnDesktop}
            disabled={pending}
            className="rounded-sm border border-[color:var(--scout-accent)] bg-[color:var(--studio-canvas)] px-4 py-3 font-mono text-[11px] uppercase tracking-[0.18em] text-[color:var(--scout-accent)] transition-colors hover:bg-[color:var(--studio-edge)] disabled:cursor-wait disabled:opacity-55"
          >
            {pending ? "showing..." : "show on desktop"}
          </button>

          <ResultPanel result={result} error={error} />

          <div className="mt-auto border-t border-studio-edge pt-4">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
              Treatment
            </p>
            <pre className="mt-2 overflow-x-auto rounded-sm border border-studio-edge bg-[color:var(--code-bg)] p-3 font-mono text-[11px] leading-[1.55] text-studio-ink">{`style: marker
shape: ${activeShape.id}
angleDeg: ${angleDeg}
size: ${activeSize.id}
palette: graphite + ${MARKER_STROKE}
simulation: ${simulationState}
typingSound: ${typingSound}
clickSound: ${clickSound}
resting: no halo`}</pre>
          </div>
        </aside>
      </div>

      <footer className="mt-16 border-t border-studio-edge pt-5">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
          source / MouseFinder.swift / ComputerUseController.swift / LatticesApi.swift
        </p>
      </footer>
    </main>
  );
}

function ControlGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <p className="mb-2 font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
        {title}
      </p>
      {children}
    </section>
  );
}

function ResultPanel({ result, error }: { result: CursorResponse | null; error: string | null }) {
  if (error) {
    return (
      <div className="rounded-sm border border-[color:var(--status-error-fg)] bg-[color:var(--status-error-bg)] p-3">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink">
          error
        </p>
        <p className="mt-1 break-words font-mono text-[11.5px] text-studio-ink-faint">
          {error}
        </p>
      </div>
    );
  }

  if (!result) {
    return (
      <div className="rounded-sm border border-studio-edge p-3">
        <p className="font-mono text-[11px] text-studio-ink-faint">
          No desktop run yet.
        </p>
      </div>
    );
  }

  const x = result.cursor?.x;
  const y = result.cursor?.y;
  const position =
    typeof x === "number" && typeof y === "number"
      ? `${Math.round(x)}, ${Math.round(y)}`
      : "current";

  return (
    <div className="rounded-sm border border-[color:var(--status-ok-fg)] bg-[color:var(--status-ok-bg)] p-3">
      <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink">
        desktop run
      </p>
      <dl className="mt-2 grid gap-1 font-mono text-[11.5px]">
        <Detail label="shown" value={result.shown ? "true" : "false"} />
        <Detail label="cursor" value={position} />
        <Detail label="run" value={result.run?.id ?? "-"} />
      </dl>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-studio-edge py-1 last:border-b-0">
      <dt className="font-mono text-[9.5px] uppercase tracking-[0.18em] text-studio-ink-faint">
        {label}
      </dt>
      <dd className="min-w-0 truncate text-right font-mono text-[11.5px] text-studio-ink">
        {value}
      </dd>
    </div>
  );
}

function TypingTargetPanel({
  inputRef,
  value,
  messages,
  running,
  runCycle,
  simulationState,
  typingSound,
  clickSound,
  shape,
  angleDeg,
  sizeScale,
  onChange,
  onCommit,
  onClickSoundChange,
  onTypingSoundChange,
  onRunClick,
  onRunSample,
}: {
  inputRef: RefObject<HTMLInputElement | null>;
  value: string;
  messages: string[];
  running: boolean;
  runCycle: number;
  simulationState: SimulationState;
  typingSound: TypingSound;
  clickSound: ClickSound;
  shape: ShapeOption;
  angleDeg: number;
  sizeScale: number;
  onChange: (value: string) => void;
  onCommit: () => void;
  onClickSoundChange: (sound: ClickSound) => void;
  onTypingSoundChange: (sound: TypingSound) => void;
  onRunClick: () => void;
  onRunSample: () => void;
}) {
  return (
    <div className="border-t border-studio-edge bg-black/10 px-4 py-4">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-studio-edge pb-3">
        <div className="flex items-baseline gap-3">
          <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-studio-ink-faint">
            Simulation
          </p>
          <p className="font-mono text-[10px] uppercase tracking-[0.16em] text-studio-ink">
            {simulationState}
          </p>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={onRunClick}
            disabled={running}
            className="rounded-sm border border-studio-edge px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.16em] text-studio-ink-faint transition-colors hover:border-studio-ink-faint hover:text-studio-ink disabled:cursor-wait disabled:opacity-55"
          >
            click
          </button>
          <button
            type="button"
            onClick={onRunSample}
            disabled={running}
            className="rounded-sm border border-[color:var(--scout-accent)] px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.16em] text-[color:var(--scout-accent)] transition-colors hover:bg-[color:var(--studio-edge)] disabled:cursor-wait disabled:opacity-55"
          >
            {running ? "typing..." : "type"}
          </button>
        </div>
      </div>

      <div className="mt-3 grid gap-2 md:grid-cols-2">
        <SoundPicker
          label="Typing"
          options={TYPING_SOUNDS}
          value={typingSound}
          onChange={onTypingSoundChange}
        />
        <SoundPicker
          label="Click"
          options={CLICK_SOUNDS}
          value={clickSound}
          onChange={onClickSoundChange}
        />
      </div>

      <div className="relative mt-3">
        {running ? (
          <div
            key={`typing-marker-${runCycle}`}
            className="pointer-events-none absolute -left-2 -top-10 z-10 h-14 w-14 lattices-agent-type-marker"
          >
            <div className="h-full w-full lattices-agent-type-marker-tap">
              <MiniCursorGlyph shape={shape} angleDeg={angleDeg} sizeScale={sizeScale} />
            </div>
          </div>
        ) : null}

        <input
          ref={inputRef}
          value={value}
          readOnly={running}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== "Enter") return;
            event.preventDefault();
            onCommit();
          }}
          className={[
            "h-11 w-full rounded-sm border bg-[color:var(--code-bg)] px-3 font-mono text-[13px] text-studio-ink outline-none transition-colors",
            running
              ? "border-[color:var(--scout-accent)]"
              : "border-studio-edge focus:border-[color:var(--scout-accent)]",
          ].join(" ")}
          placeholder="sample message"
        />
        {running ? (
          <div
            key={`typing-input-pulse-${runCycle}`}
            className="pointer-events-none absolute inset-x-0 bottom-0 h-px overflow-hidden rounded-full"
          >
            <span className="block h-full w-1/2 lattices-typing-input-pulse" />
          </div>
        ) : null}
      </div>

      <div className="mt-3 grid min-h-[68px] gap-1 border border-studio-edge bg-[color:var(--studio-canvas)] p-3">
        {messages.length ? (
          messages.map((message, index) => (
            <p
              key={`${message}-${index}`}
              className="truncate font-mono text-[11.5px] text-studio-ink"
            >
              <span className="mr-2 text-studio-ink-faint">enter</span>
              {message}
            </p>
          ))
        ) : (
          <p className="font-mono text-[11.5px] text-studio-ink-faint">
            No submitted samples yet.
          </p>
        )}
      </div>
    </div>
  );
}

function SoundPicker<T extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { id: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  return (
    <div className="grid grid-cols-[72px_minmax(0,1fr)] items-center gap-2">
      <span className="font-mono text-[9.5px] uppercase tracking-[0.16em] text-studio-ink-faint">
        {label}
      </span>
      <div className={["grid gap-1", options.length === 2 ? "grid-cols-2" : "grid-cols-3"].join(" ")}>
        {options.map((option) => (
          <button
            key={option.id}
            type="button"
            onClick={() => onChange(option.id)}
            className={[
              "rounded-sm border px-2 py-1.5 font-mono text-[9.5px] uppercase tracking-[0.1em] transition-colors",
              value === option.id
                ? "border-[color:var(--scout-accent)] bg-[color:var(--studio-edge)] text-studio-ink"
                : "border-studio-edge text-studio-ink-faint hover:border-studio-ink-faint hover:text-studio-ink",
            ].join(" ")}
          >
            {option.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function formatAngle(angleDeg: number) {
  if (angleDeg > 0) return `+${angleDeg}deg`;
  return `${angleDeg}deg`;
}

function CursorStage({
  stage,
  label,
  shape,
  angleDeg,
  sizeScale,
  treatment,
  previewCycle,
}: {
  stage: StageKey;
  label: string;
  shape: ShapeOption;
  angleDeg: number;
  sizeScale: number;
  treatment: PreviewTreatment;
  previewCycle: number;
}) {
  return (
    <div
      className="relative flex min-h-[520px] items-center justify-center overflow-hidden"
      style={stageStyle(stage)}
    >
      {stage === "terminal" ? <TerminalTexture treatment={treatment} previewCycle={previewCycle} /> : null}
      {stage === "canvas" ? <CanvasTexture /> : null}
      <div className="relative flex h-[320px] w-[320px] items-center justify-center">
        <CursorGlyph
          label={label.trim()}
          shape={shape}
          angleDeg={angleDeg}
          sizeScale={sizeScale}
          treatment={treatment}
          previewCycle={previewCycle}
        />
      </div>
    </div>
  );
}

function stageStyle(stage: StageKey): CSSProperties {
  if (stage === "light") {
    return {
      background:
        "linear-gradient(135deg, #f7f8fa 0%, #eceff3 100%)",
      color: GRAPHITE,
    };
  }
  if (stage === "canvas") {
    return {
      background: "var(--studio-canvas)",
    };
  }
  return {
    background:
      "linear-gradient(135deg, #071013 0%, #0a0c0f 48%, #101319 100%)",
  };
}

function CursorGlyph({
  label,
  shape,
  angleDeg,
  sizeScale,
  treatment,
  previewCycle,
}: {
  label: string;
  shape: ShapeOption;
  angleDeg: number;
  sizeScale: number;
  treatment: PreviewTreatment;
  previewCycle: number;
}) {
  return (
    <svg
      viewBox="0 0 220 220"
      className="h-[250px] w-[250px] overflow-visible"
      role="img"
      aria-label="Lattices cursor marker preview"
    >
      {treatment === "click" ? (
        <circle
          key={`click-${previewCycle}`}
          className="lattices-cursor-click-ring"
          cx="110"
          cy="112"
          r="38"
          fill="none"
          stroke={MARKER_STROKE}
          strokeWidth="2"
        />
      ) : null}

      <g
        key={`marker-${previewCycle}-${treatment}`}
        className={treatment === "click" ? "lattices-cursor-click-tap" : undefined}
        transform={`translate(110 112) rotate(${angleDeg}) scale(${sizeScale}) translate(-110 -112)`}
      >
        <path
          d={shape.path}
          fill={GRAPHITE}
          fillOpacity="0.88"
          stroke={MARKER_STROKE}
          strokeWidth="4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>

      {label ? (
        <g transform="translate(110 198)">
          <rect
            x={-Math.max(32, label.length * 4.6)}
            y="-13"
            width={Math.max(64, label.length * 9.2)}
            height="22"
            rx="2"
            fill="#000000"
            opacity="0.52"
          />
          <text
            y="2.5"
            textAnchor="middle"
            fill={MARKER_STROKE}
            fontFamily="JetBrains Mono, ui-monospace, monospace"
            fontSize="11"
            fontWeight="600"
          >
            {label}
          </text>
        </g>
      ) : null}
    </svg>
  );
}

function ShapeIcon({ shape }: { shape: ShapeOption }) {
  return (
    <svg
      viewBox="0 0 220 220"
      className="h-11 w-11 overflow-visible"
      aria-hidden
    >
      <path
        d={shape.path}
        fill={GRAPHITE}
        fillOpacity="0.9"
        stroke={MARKER_STROKE}
        strokeWidth="6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function MiniCursorGlyph({
  shape,
  angleDeg,
  sizeScale,
}: {
  shape: ShapeOption;
  angleDeg: number;
  sizeScale: number;
}) {
  return (
    <svg viewBox="0 0 220 220" className="h-full w-full overflow-visible" aria-hidden>
      <g transform={`translate(110 112) rotate(${angleDeg}) scale(${sizeScale}) translate(-110 -112)`}>
        <path
          d={shape.path}
          fill={GRAPHITE}
          fillOpacity="0.9"
          stroke={MARKER_STROKE}
          strokeWidth="6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </g>
    </svg>
  );
}

function TerminalTexture({
  treatment,
  previewCycle,
}: {
  treatment: PreviewTreatment;
  previewCycle: number;
}) {
  const rows = [
    "bun run build",
    "swift build --package-path apps/mac",
    "computer.showCursor",
    "run.completed",
    "artifact.created",
  ];

  return (
    <div className="pointer-events-none absolute inset-0 opacity-45">
      <div className="absolute left-[12%] top-[18%] w-[58%] rounded-sm border border-white/10 bg-black/20 p-4 font-mono text-[11px] leading-6 text-white/45">
        {rows.map((row, index) => (
          <p key={row}>
            <span className="text-white/25">{String(index + 1).padStart(2, "0")}</span>{" "}
            {row}
          </p>
        ))}
        {treatment === "typing" ? (
          <p key={`typing-${previewCycle}`} className="text-white/70">
            <span className="text-white/25">06</span>{" "}
            <span className="inline-block max-w-[26ch] overflow-hidden whitespace-nowrap align-bottom lattices-typing-line">
              agentic cursor treatment
            </span>
            <span className="lattices-typing-caret">|</span>
          </p>
        ) : null}
        {treatment === "click" ? (
          <p key={`click-row-${previewCycle}`} className="text-white/65 lattices-click-row">
            <span className="text-white/25">06</span> computer.click
          </p>
        ) : null}
      </div>
      <div className="absolute bottom-[18%] right-[14%] h-[26%] w-[34%] rounded-sm border border-white/10 bg-black/20" />
    </div>
  );
}

function CanvasTexture() {
  return (
    <div
      className="pointer-events-none absolute inset-0 opacity-70"
      style={{
        backgroundImage:
          "linear-gradient(var(--studio-edge) 1px, transparent 1px), linear-gradient(90deg, var(--studio-edge) 1px, transparent 1px)",
        backgroundSize: "36px 36px",
      }}
    />
  );
}

function CursorStudyStyles() {
  return (
    <style>{`
      @keyframes latticesCursorClickRing {
        0% { opacity: 0.65; transform: scale(0.68); }
        72% { opacity: 0.18; }
        100% { opacity: 0; transform: scale(1.55); }
      }

      @keyframes latticesCursorClickTap {
        0% { transform: translate(110px, 112px) scale(1) translate(-110px, -112px); }
        38% { transform: translate(110px, 112px) scale(0.94) translate(-110px, -112px); }
        100% { transform: translate(110px, 112px) scale(1) translate(-110px, -112px); }
      }

      @keyframes latticesTypingLine {
        from { width: 0; }
        to { width: 24ch; }
      }

      @keyframes latticesTypingCaret {
        0%, 42% { opacity: 1; }
        43%, 100% { opacity: 0; }
      }

      @keyframes latticesClickRow {
        0% { opacity: 0; transform: translateY(2px); }
        20%, 72% { opacity: 1; transform: translateY(0); }
        100% { opacity: 0.42; transform: translateY(0); }
      }

      @keyframes latticesAgentTypeMarkerIn {
        0% { opacity: 0; transform: translate(-42px, -20px) scale(0.72) rotate(-4deg); }
        18% { opacity: 1; }
        64% { opacity: 1; transform: translate(0, 0) scale(0.82) rotate(0deg); }
        100% { opacity: 0.92; transform: translate(0, 0) scale(0.78) rotate(0deg); }
      }

      @keyframes latticesAgentTypeMarkerTap {
        0%, 100% { transform: translateY(0) scale(1); }
        44% { transform: translateY(1.5px) scale(0.96); }
        68% { transform: translateY(-0.5px) scale(1.01); }
      }

      @keyframes latticesTypingInputPulse {
        0% { opacity: 0; transform: translateX(-44%) scaleX(0.18); }
        18%, 72% { opacity: 0.9; }
        100% { opacity: 0; transform: translateX(148%) scaleX(0.72); }
      }

      .lattices-cursor-click-ring {
        transform-box: fill-box;
        transform-origin: center;
        animation: latticesCursorClickRing 520ms ease-out both;
      }

      .lattices-cursor-click-tap {
        transform-box: fill-box;
        transform-origin: center;
      }

      .lattices-typing-line {
        animation: latticesTypingLine 920ms steps(24, end) both;
      }

      .lattices-typing-caret {
        animation: latticesTypingCaret 720ms step-end infinite;
      }

      .lattices-click-row {
        animation: latticesClickRow 560ms ease-out both;
      }

      .lattices-agent-type-marker {
        animation: latticesAgentTypeMarkerIn 520ms cubic-bezier(0.22, 1, 0.36, 1) both;
      }

      .lattices-agent-type-marker-tap {
        animation: latticesAgentTypeMarkerTap 520ms ease-in-out 520ms infinite;
        transform-origin: 50% 58%;
      }

      .lattices-typing-input-pulse {
        background: linear-gradient(90deg, transparent 0%, ${MARKER_STROKE} 42%, var(--scout-accent) 100%);
        box-shadow: 0 0 10px color-mix(in srgb, var(--scout-accent) 42%, transparent);
        animation: latticesTypingInputPulse 860ms ease-in-out infinite;
      }
    `}</style>
  );
}
