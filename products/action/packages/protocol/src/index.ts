export const sessionStates = [
  "created",
  "preflight",
  "ready",
  "running",
  "paused",
  "completing",
  "completed",
  "failed",
  "cancelled",
] as const;

export type SessionState = (typeof sessionStates)[number];

export const sessionModes = [
  "capture",
  "inspection",
  "hybrid",
] as const;

export type SessionMode = (typeof sessionModes)[number];

export const targetResolutionModes = [
  "semantic",
  "accessibility",
  "dom",
  "textual",
  "anchor",
  "coordinate",
] as const;

export type TargetResolutionMode = (typeof targetResolutionModes)[number];

export interface SessionId {
  value: string;
}

export interface Point {
  x: number;
  y: number;
}

export interface Bounds extends Point {
  width: number;
  height: number;
}

export interface SurfaceRef {
  id: string;
  kind: "desktop" | "window" | "browser-tab" | "region";
  label: string;
  bounds?: Bounds;
}

export interface TargetQuery {
  semanticId?: string;
  text?: string;
  role?: string;
  surfaceId?: string;
  anchorId?: string;
  point?: Point;
}

export interface ResolvedTarget {
  /** Global screen point retained by coordinate resolution. */
  point?: Point;
  id: string;
  mode: TargetResolutionMode;
  confidence: number;
  label: string;
  surfaceId?: string;
  bounds?: Bounds;
  ambiguousWith?: string[];
}

export type AdapterActionChannel =
  | "ax"
  | "dom"
  | "tmux"
  | "editor"
  | "native"
  | "process"
  | "hid";

export type AdapterCapability =
  | "observe"
  | "resolve"
  | "act"
  | "extract"
  | "capture-hints"
  | "verify";

export interface AdapterMatch {
  matched: boolean;
  confidence: number;
  reason: string;
  evidence?: Record<string, unknown>;
}

export interface NativeWindowState {
  bundleId?: string;
  appName?: string;
  windowTitle?: string;
  bounds?: Bounds;
  isFrontmost?: boolean;
  processId?: number;
}

export interface AXNodeSnapshot {
  role: string;
  title?: string;
  detail?: string;
  value?: string;
  identifier?: string;
  frame?: Bounds;
  depth?: number;
  actions?: string[];
  settableAttributes?: string[];
  enabled?: boolean;
  focused?: boolean;
}

export interface AXSnapshot {
  source: "accessibility";
  capturedAt: string;
  nodes: AXNodeSnapshot[];
}

export interface SemanticElement {
  id: string;
  role?: string;
  label?: string;
  text?: string;
  selector?: string;
  rect?: Bounds;
  attributes?: Record<string, string>;
  metadata?: Record<string, unknown>;
}

export interface BrowserPageState {
  kind: "browser-page";
  browser: "chrome" | "safari" | "firefox" | "unknown";
  url?: string;
  title?: string;
  loading?: boolean;
  elements?: SemanticElement[];
  metadata?: Record<string, unknown>;
}

export interface TerminalState {
  kind: "terminal";
  host?: "terminal" | "iterm" | "ghostty" | "warp" | "unknown";
  sessions?: SemanticElement[];
  panes?: SemanticElement[];
  metadata?: Record<string, unknown>;
}

export interface EditorState {
  kind: "editor";
  editor?: "cursor" | "vscode" | "codex" | "conductor" | "unknown";
  workspacePath?: string;
  activeFile?: string;
  selection?: Record<string, unknown>;
  panels?: SemanticElement[];
  metadata?: Record<string, unknown>;
}

export type SurfaceSemanticState = BrowserPageState | TerminalState | EditorState | Record<string, unknown>;

export interface ScreenshotReflection {
  provider: string;
  summary: string;
  imagePath?: string;
  findings?: InspectionFinding[];
  metadata?: Record<string, unknown>;
}

export interface SurfaceObservation {
  surface: SurfaceRef;
  ax: AXSnapshot;
  native: NativeWindowState;
  semantic?: SurfaceSemanticState;
  vision?: ScreenshotReflection;
  freshness: {
    axCapturedAt: string;
    semanticCapturedAt?: string;
    screenshotCapturedAt?: string;
  };
}

export interface ObserveContext {
  surface: SurfaceRef;
  native?: NativeWindowState;
  ax?: AXSnapshot;
  now?: string;
  options?: Record<string, unknown>;
}

export interface TargetEvidence {
  source: "ax" | "dom" | "tmux" | "editor" | "native" | "vision" | "recipe";
  summary: string;
  nodeId?: string;
  rect?: Bounds;
  confidence?: number;
  metadata?: Record<string, unknown>;
}

export interface TargetCandidate {
  id: string;
  label: string;
  role?: string;
  rect?: Bounds;
  confidence: number;
  stabilityKey?: string;
  evidence: TargetEvidence[];
  preferredActionChannel: AdapterActionChannel;
  fallbackChannels: AdapterActionChannel[];
}

export interface ExtractionQuery {
  id?: string;
  kind?: string;
  text?: string;
  role?: string;
  schema?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
}

export interface ExtractionResult {
  id: string;
  at: string;
  data: Record<string, unknown>;
  evidence?: TargetEvidence[];
}

export interface CaptureHint {
  id: string;
  label: string;
  rect: Bounds;
  reason: string;
  padding?: number;
  preferredAspectRatio?: "1:1" | "4:3" | "16:9" | "free";
  evidence?: TargetEvidence[];
}

export interface ActionResult {
  id: string;
  at: string;
  status: "succeeded" | "failed" | "skipped" | "needs-user";
  channel: AdapterActionChannel;
  detail?: string;
  metadata?: Record<string, unknown>;
}

export interface VerifyContext {
  observation?: SurfaceObservation;
  before?: SurfaceObservation;
  after?: SurfaceObservation;
  action?: RuntimeAction;
  target?: TargetCandidate;
  artifacts?: RuntimeArtifact[];
}

export interface VerificationResult {
  ok: boolean;
  confidence: number;
  summary: string;
  evidence?: TargetEvidence[];
  metadata?: Record<string, unknown>;
}

export interface Observation {
  kind:
    | "window"
    | "accessibility"
    | "dom"
    | "cursor"
    | "recording"
    | "audio"
    | "vision"
    | "analysis";
  source: "engine" | "browser" | "runtime";
  at: string;
  surfaceId?: string;
  data: Record<string, unknown>;
}

export type ActionKind =
  | "click"
  | "type"
  | "press-key"
  | "focus-window"
  | "open-app"
  | "drag"
  | "scroll"
  | "start-recording"
  | "stop-recording"
  | "show-cue"
  | "wait-for-condition";

export interface RuntimeAction {
  id: string;
  kind: ActionKind;
  description: string;
  target?: TargetQuery;
  input?: Record<string, unknown>;
}

export interface Cue {
  id: string;
  kind: "label" | "chapter" | "subtitle" | "callout" | "caption";
  text: string;
  atMs?: number;
  durationMs?: number;
}

export type ArtifactKind =
  | "screenshot"
  | "raw-capture"
  | "trace"
  | "ax-snapshot"
  | "ocr-snapshot"
  | "vision-analysis"
  | "inspection-request"
  | "inspection-response"
  | "findings"
  | "focus-metadata"
  | "subtitle"
  | "render-manifest"
  | "final-video"
  | "drive-lease";

/** How an automation client intends to interact with the Mac. */
export const driveModes = ["background", "attention"] as const;
export type DriveMode = (typeof driveModes)[number];

/** Active and terminal states for an operator-visible drive lease. */
export const driveLeaseStates = [
  "driving",
  "done",
  "failed",
  "cancelled",
  "expired",
  "denied",
] as const;
export type DriveLeaseState = (typeof driveLeaseStates)[number];

export const driveOutcomes = ["done", "failed", "cancelled"] as const;
export type DriveOutcome = (typeof driveOutcomes)[number];

export const driveAggregateStates = ["idle", "driving"] as const;
export type DriveAggregateState = (typeof driveAggregateStates)[number];

export type AxActionTier =
  | "observe"
  | "semantic"
  | "target-focus"
  | "app-api"
  /** Click/type/key into the agent layer: save cursor + frontmost app, act, restore. */
  | "blink"
  | "attention";

export interface DriveLease {
  leaseId: string;
  agent: string;
  task: string;
  mode: DriveMode;
  status: DriveLeaseState;
  sessionId: string;
  startedAt: string;
  lastActAt: string;
  releasedAt?: string;
  outcome?: DriveOutcome | "expired";
  summary?: string;
  implicit?: boolean;
  showSupervisionLabel?: boolean;
  pointerControl?: boolean;
  stopFile: string;
  lastAxTier?: AxActionTier;
  /** What the caller named itself, e.g. "Action MCP". */
  client?: string;
  /** The process the agent saw on the socket, e.g. "bun 41250 ← claude 41012". */
  clientProcess?: string;
  /** Acts recorded against this lease. */
  actCount?: number;
}

export interface DriveStatusSnapshot {
  state: DriveAggregateState;
  leases: DriveLease[];
  activeCount: number;
}

export interface RuntimeArtifact {
  kind: ArtifactKind;
  path: string;
  metadata?: Record<string, unknown>;
}

export type PermissionState = "granted" | "denied" | "unknown";

export type CaptureProfile = "draft" | "final";

export interface EngineDiagnostics {
  accessibility: PermissionState;
  screenRecording: PermissionState;
  notes?: string[];
  /** Set by engines that drive another machine (LAT-013), e.g. "linux". */
  platform?: string;
  /** The remote host's name, for remote engines. */
  host?: string;
  /** The remote host's advertised capabilities (host.describe). */
  capabilities?: string[];
}

export const guidedSessionPhases = [
  "created",
  "staging",
  "observing",
  "analyzing",
  "awaiting-decision",
  "acting",
  "countdown",
  "recording",
  "paused",
  "completing",
  "completed",
  "failed",
  "cancelled",
] as const;

export type GuidedSessionPhase = (typeof guidedSessionPhases)[number];

export type BackdropPreset = "neutral" | "spotlight" | "studio" | "gradient" | "matte";

/**
 * How Action stages the screen for a take.
 *
 * - `drape`: a flat color sheet at ordinary window level. AXRaise the listed
 *   subjects and they land above it; everything else stays buried. Same level
 *   is what makes AXRaise able to beat the sheet. Wallpaper is never written.
 * - `space`: same sheet, but it stays on the current Space only. Other Spaces
 *   are untouched. Instantiate subjects on this Space rather than adopting
 *   windows that live elsewhere.
 */
export type StageMode = "drape" | "space";

export type StageDrapeLevel = "normal" | "desktop";

export interface StageSubject {
  bundleId: string;
  title?: string;
}

export interface StageWorld {
  mode: StageMode;
  color: string;
  level: StageDrapeLevel;
  bounds?: Bounds;
  subjects: StageSubject[];
  /**
   * Wall-clock lifetime in seconds. The drape dismisses itself when it expires.
   * Omitted means the drape stays up until `stage.clear` or until its owner dies,
   * which is only a real backstop when the owner outlives the call (see `owner`).
   */
  seconds?: number;
}

/**
 * Who the drape dies with.
 *
 * - `caller`: the drape watches the calling process and dismisses itself when that
 *   process goes away. Correct for a long-lived host such as the MCP server.
 * - `detached`: nothing to watch. Correct for a one-shot CLI invocation, which exits
 *   the moment it has put the drape up — a `caller`-owned drape would take itself
 *   down within one poll interval. Pair it with `seconds` so a forgotten drape still
 *   expires on its own.
 */
export type StageOwner = "caller" | "detached";

export interface StageWindowInfo {
  bundleId?: string;
  title: string;
  owner: string;
  pid: number;
  layer: number;
  bounds: Bounds;
}

export type StageSceneIntruderReason = "above-subject" | "in-rect" | "subject-buried";

/**
 * What is actually on top of the sheet after raise.
 * `ok` is false when a non-subject occupies the scene or a listed subject is still buried.
 */
export interface StageSceneReport {
  ok: boolean;
  bounds?: Bounds;
  tops: StageWindowInfo[];
  subjects: StageWindowInfo[];
  drapes: StageWindowInfo[];
  intruders: Array<StageWindowInfo & { reason: StageSceneIntruderReason }>;
}

export interface StageWorldStatus extends StageWorld {
  active: boolean;
  pid?: number;
  owner: StageOwner;
  ownerPid?: number;
  stopFile?: string;
  raised: Array<StageSubject & { title: string }>;
  scene?: StageSceneReport;
}

/**
 * Who an agent layer dies with. Same contract as `StageOwner`: `caller` passes this
 * process as `--parent-pid`; `detached` leaves teardown to `layer.close`.
 */
export type AgentLayerOwner = "caller" | "detached";

/** The app whose windows live on the agent layer. One of the two is set. */
export interface AgentLayerSubject {
  bundleId?: string;
  pid?: number;
}

export interface AgentLayerWindow {
  pid: number;
  bundleId: string | null;
  title: string | null;
  /** Frame before the window moved onto the layer. Restored at teardown. */
  original: Bounds;
  /**
   * Opened after the layer went up (launched for it, ⌘N, a pop-up). Never on the
   * operator's screen, so teardown closes it rather than restoring it.
   */
  born?: boolean;
}

/**
 * State file written by the native `agent-layer` process. `bounds` is global,
 * top-left origin, in points.
 */
export interface AgentLayerState {
  workspace?: string;
  previewDisplayId?: number | null;
  previewFull?: boolean;
  pid: number;
  displayId: number;
  bounds: Bounds;
  pip: boolean;
  /** The operator paused the agent from the viewer; acts are refused until they resume. */
  paused?: boolean;
  /** Movie path while a take is being recorded off the layer's feed. */
  recording?: string | null;
  windows: AgentLayerWindow[];
  startedAt: string;
}

export interface AgentLayerStatus {
  workspace?: string;
  active: boolean;
  owner: AgentLayerOwner;
  ownerPid?: number;
  subject?: AgentLayerSubject;
  stopFile?: string;
  stateFile?: string;
  /** Present while the layer is up. */
  layer?: AgentLayerState;
  /** Set when `close` gave up waiting and the process may still be alive. */
  pid?: number;
}

export interface TargetApp {
  name: string;
  bundleId: string;
}

export interface StageViewport {
  id: string;
  bounds: Bounds;
  surfaceId?: string;
  dimming: "none" | "surround";
  /** Center the requested size inside the selected display with edge clearance. */
  placement?: "absolute" | "centered-safe";
  /** Edge clearance used by centered-safe placement. Defaults to 72 points. */
  safeAreaInset?: number;
}

export interface StageInputOverlay {
  kind: "keys" | "typing";
  keys?: string[];
  text?: string;
  style?: "default" | "notes" | "terminal" | "code";
}

export interface StageScene {
  backdrop: BackdropPreset;
  viewport?: StageViewport;
  targetApp?: TargetApp;
}

export interface StagePresentation {
  sessionId: string;
  phase: GuidedSessionPhase;
  backdrop: BackdropPreset;
  viewport?: StageViewport;
  targetApp?: string;
  summary: string;
  detail?: string;
  countdownRemaining?: number;
  elapsedMs?: number;
  isRecording: boolean;
  stepCurrent?: number;
  stepTotal?: number;
  stepLabel?: string;
  inputOverlay?: StageInputOverlay;
  recentLogs?: string[];
}

export type HudControl =
  | "start"
  | "pause"
  | "stop"
  | "replay-last-run"
  | "quit";

export interface HudControlState {
  control: HudControl;
  enabled: boolean;
  label?: string;
}

export interface HudLogEntry {
  id: string;
  at: string;
  level: "info" | "warning" | "error";
  eventType: string;
  message: string;
}

export interface HudSnapshot {
  sessionId: string;
  mode: SessionMode;
  state: SessionState;
  phase: GuidedSessionPhase;
  targetApp?: string;
  elapsedMs: number;
  isRecording: boolean;
  diagnostics?: EngineDiagnostics;
  controls: HudControlState[];
  logs: HudLogEntry[];
  artifacts: RuntimeArtifact[];
  stage: StageScene;
}

export interface InspectionFinding {
  id: string;
  source: string;
  summary: string;
  severity: "info" | "warning" | "error";
  kind: "ui-critique" | "qa-issue" | "target-hint" | "observation" | "action-suggestion";
  bounds?: Bounds;
  targetHint?: TargetQuery;
  evidence?: string;
  recommendedAction?: RuntimeAction;
  metadata?: Record<string, unknown>;
}

export interface InspectionRequest {
  sessionId: string;
  provider: string;
  prompt: string;
  imagePath: string;
  surfaceId?: string;
  contextArtifacts?: string[];
  metadata?: Record<string, unknown>;
}

export interface InspectionResult {
  sessionId: string;
  provider: string;
  summary: string;
  findings: InspectionFinding[];
  rawResponsePath?: string;
  metadata?: Record<string, unknown>;
}

export interface SessionSnapshot {
  id: string;
  mode: SessionMode;
  state: SessionState;
  createdAt: string;
  updatedAt: string;
  traceCount: number;
  artifactCount: number;
}

export interface SessionArtifactEntry {
  kind: RuntimeArtifact["kind"];
  path: string;
  relativePath: string;
  metadata?: Record<string, unknown>;
}

export interface SessionArtifactManifest {
  sessionId: string;
  mode: SessionMode;
  generatedAt: string;
  outputDir: string;
  tracePath: string;
  artifacts: SessionArtifactEntry[];
}

export interface PersistedRuntimeSession {
  id: string;
  mode: SessionMode;
  state: SessionState;
  phase: GuidedSessionPhase;
  createdAt: string;
  updatedAt: string;
  targetApp?: string;
  outputDir: string;
  tracePath: string;
  manifestPath: string;
  artifactCount: number;
  traceCount: number;
  artifacts: SessionArtifactEntry[];
  stage: StageScene;
}

export interface TransitionOptions {
  reason?: string;
  at?: string;
}

export interface ActionTrace {
  action: RuntimeAction;
  status: "planned" | "started" | "completed" | "failed";
  at: string;
  detail?: string;
}

export type TraceEvent =
  | {
      type: "session.state_changed";
      at: string;
      from: SessionState;
      to: SessionState;
      reason?: string;
    }
  | {
      type: "observation.recorded";
      at: string;
      observation: Observation;
    }
  | {
      type: "target.resolved";
      at: string;
      query: TargetQuery;
      result: ResolvedTarget;
    }
  | {
      type: "action.recorded";
      at: string;
      entry: ActionTrace;
    }
  | {
      type: "artifact.registered";
      at: string;
      artifact: RuntimeArtifact;
    }
  | {
      type: "drive.lease_began";
      at: string;
      leaseId: string;
      agent: string;
      task: string;
      mode: DriveMode;
      sessionId: string;
      implicit?: boolean;
    }
  | {
      type: "drive.lease_released";
      at: string;
      leaseId: string;
      outcome: DriveOutcome | "expired";
      summary?: string;
    }
  | {
      type: "drive.lease_expired";
      at: string;
      leaseId: string;
      reason: "idle" | "max-duration" | "stop-file" | "connection-closed";
    }
  | {
      type: "drive.act_tier";
      at: string;
      leaseId: string;
      axTier: AxActionTier;
      actionKind?: string;
    };

export interface CompiledTimelineStep {
  id: string;
  action: RuntimeAction;
  preconditions: string[];
  cueIds: string[];
  onAmbiguous: "pause" | "fail";
}

export interface CompiledTimeline {
  goal: string;
  cues: Cue[];
  steps: CompiledTimelineStep[];
}

export type GuidedSessionEventType =
  | "phase.changed"
  | "backdrop.selected"
  | "viewport.updated"
  | "app.launched"
  | "inspection.started"
  | "inspection.completed"
  | "finding.recorded"
  | "countdown.tick"
  | "recording.started"
  | "recording.paused"
  | "recording.resumed"
  | "recording.stopped"
  | "target.resolved"
  | "action.started"
  | "action.completed"
  | "action.failed"
  | "artifact.created"
  | "replay.requested";

export interface GuidedSessionEvent<TPayload extends Record<string, unknown> = Record<string, unknown>> {
  sessionId: string;
  at: string;
  type: GuidedSessionEventType;
  summary: string;
  payload: TPayload;
}

/**
 * Visible feedback for Action-driven clicks. Off by default: a recording shows nothing beyond the
 * normal macOS pointer unless the operator opts in here. Enabling it never replaces or hides the
 * system cursor — it adds one short pulse at the press point.
 */
export interface ClickFeedbackConfig {
  enabled: boolean;
  /** Only "pulse" exists today. */
  style?: "pulse";
  /** Lifetime of one pulse. Defaults to 320ms. */
  durationMs?: number;
  /** Outer radius the pulse expands to, in points. Defaults to 34. */
  radius?: number;
}

/** Phase of a pointer button transition. Intermediate drag motion is not a pointer event. */
export type PointerEventPhase = "down" | "up";

/**
 * One row of a recording's `<recordingId>.pointer-events.jsonl` artifact, written natively by the
 * same code path that posts the CGEvent. The visible pulse is rendered from these same rows, so
 * the metadata and the pixels describe one event rather than two.
 */
export interface PointerEventRecord {
  kind: "pointer";
  recordingId: string;
  sessionId?: string;
  /** Shared by the down and up of one gesture. */
  correlationId: string;
  gesture: "click" | "drag";
  phase: PointerEventPhase;
  button: "left" | "right";
  /** CoreGraphics global screen coordinates, origin top-left — the space the event was posted in. */
  x: number;
  y: number;
  /** Monotonic milliseconds since the recording's pointer log was opened. */
  recordingElapsedMs: number;
  /** Wall-clock ISO 8601 with fractional seconds. */
  at: string;
  /** Raw macOS system uptime at the post, so elapsed time can be re-derived. */
  uptime: number;
  /** Measured press duration; present on "up" only. */
  holdMs?: number;
  /** Which Action surface posted it, e.g. "click-point" or "drag". */
  source: string;
}

/** First line of the pointer event log. Carries the clock every later row is relative to. */
export interface PointerEventLogHeader {
  kind: "header";
  version: number;
  recordingId: string;
  sessionId?: string;
  startedAt: string;
  startedAtUptime: number;
  feedback: {
    enabled: boolean;
    style: string;
    durationMs: number;
    radius: number;
  };
}

export interface CaptureStartRequest {
  sessionId: string;
  outputPath: string;
  viewport?: StageViewport;
  profile?: CaptureProfile;
  /** Opt-in visible click feedback for this capture. Absent means off. */
  clickFeedback?: ClickFeedbackConfig;
}

export interface CaptureEngine {
  diagnostics(): Promise<EngineDiagnostics>;
  requestPermissions(): Promise<EngineDiagnostics>;
  openPermissionSettings(kind: "accessibility" | "screen-recording"): Promise<void>;
  presentStage(presentation: StagePresentation): Promise<void>;
  clearStage(): Promise<void>;
  setBackdrop(backdrop: BackdropPreset): Promise<void>;
  launchApp(app: TargetApp): Promise<SurfaceRef>;
  focusSurface(surfaceId: string): Promise<void>;
  configureViewport(viewport: StageViewport): Promise<StageViewport>;
  startCapture(request: CaptureStartRequest): Promise<void>;
  pauseCapture(): Promise<void>;
  resumeCapture(): Promise<void>;
  stopCapture(): Promise<RuntimeArtifact>;
  captureScreenshot(path: string): Promise<RuntimeArtifact>;
  captureFullScreenshot(path: string): Promise<RuntimeArtifact>;
  consumeStageControls(): Promise<string[]>;
  resolveTarget(query: TargetQuery): Promise<ResolvedTarget>;
  /** Resolves to how the act landed (the host detail, e.g. "via=ax"), when the engine knows. */
  performAction(action: RuntimeAction, target?: ResolvedTarget): Promise<string | undefined | void>;
  replayArtifact(path: string): Promise<void>;
}
