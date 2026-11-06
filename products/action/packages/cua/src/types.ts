/**
 * The computer-use backend seam (LAT-013). A backend is a delivery layer under
 * Action's observe/act: it lists targets, observes one, and acts on it. Policy
 * (drive lease, tier allow list, HUD, cursor, receipts) stays above, in Action.
 *
 * The contract is the one the arts-mini adapters were written against, so the
 * codex-cua and trycua-cua backends port without changes to their logic.
 */

export type BackendTier = "observe" | "semantic" | "target-focus" | "attention";

export type BackendPoint = { x: number; y: number };

export type BackendAction =
  | { kind: "press"; ref: string }
  | { kind: "setValue"; ref: string; value: string }
  | { kind: "type"; text: string; ref?: string }
  | { kind: "key"; combo: string }
  | { kind: "click"; point: BackendPoint; button?: "left" | "right"; count?: number }
  | { kind: "scroll"; ref?: string; point?: BackendPoint; direction: "up" | "down" | "left" | "right"; amount?: number }
  | { kind: "secondary"; ref: string; name: string };

export type BackendActionKind = BackendAction["kind"];

export type BackendAxNode = {
  ref: string;
  depth: number;
  role: string;
  label?: string;
  value?: string;
  actions?: string[];
  settable?: boolean;
  /** Screen-point frame, when the backend reports one. For action-cua it is also the click coordinate space. */
  frame?: { x: number; y: number; width: number; height: number };
};

export type BackendObservation = {
  observationId: string;
  targetId: string;
  at: number;
  bounds?: { x: number; y: number; width: number; height: number };
  scale?: number;
  ax?: BackendAxNode[];
  screenshot?: { path: string; width?: number; height?: number };
};

export type BackendTarget = {
  targetId: string;
  app: string;
  bundleId?: string;
  title?: string;
  pid?: number;
  focused?: boolean;
};

export type BackendCall = {
  requestId: string;
  caller: string;
  sessionId?: string;
  signal: AbortSignal;
  deadline: number;
  /** Live setup progress; normal computer-use calls do not emit these steps. */
  onSetupStep?: (step: BackendSetupStep) => void;
};

export type BackendActResult = {
  outcome: "dispatched";
  tierUsed: BackendTier;
  mechanism: string;
  observation?: BackendObservation;
  message?: string;
};

export type BackendNeed = {
  kind: "permission" | "install" | "config" | "approval";
  permission?: "accessibility" | "screen-recording" | "automation";
  /** Bundle id or path of the app that must hold the grant. */
  app?: string;
  detail: string;
  fix: string;
};

export type BackendAvailability = { ready: boolean; reason?: string; version?: string; needs?: BackendNeed[] };
export type BackendSetupStep = {
  step: string;
  status: "done" | "waiting-on-user" | "failed" | "skipped";
  detail?: string;
};
export type BackendSetupResult = { ready: boolean; steps: BackendSetupStep[]; needs?: BackendNeed[] };
export type BackendSetupOptions = { interactive: boolean };

/** The first five come from backends; tier-not-allowed is the host's own gate. */
export type BackendRefusalCode = "unsupported" | "stale-ref" | "unknown-target" | "invalid-action" | "unavailable" | "tier-not-allowed";

export type McpToolResult = {
  content?: Array<{ type: string; text?: string; data?: string; mimeType?: string }>;
  structuredContent?: unknown;
  isError?: boolean;
};

export type McpClient = {
  serverInfo: { name?: string; version?: string } | null;
  listTools(opts?: { signal?: AbortSignal; timeoutMs?: number }): Promise<Array<{ name: string; description?: string }>>;
  callTool(name: string, args?: Record<string, unknown>, opts?: { signal?: AbortSignal; timeoutMs?: number }): Promise<McpToolResult>;
  close(): void;
};

/** An answer to a server's elicitation/create, or null to decline it. */
export type ElicitationAnswer = { content?: Record<string, unknown>; _meta?: Record<string, unknown> } | null;

export type StdioMcpOptions = {
  command: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
  timeoutMs?: number;
  /** Cancels initial MCP negotiation; later requests supply their own signals. */
  signal?: AbortSignal;
  /** Present only for servers that ask the client questions (codex-cua's per-app approval). */
  onElicitation?: (params: Record<string, any>) => ElicitationAnswer;
};

export type BackendContext = {
  /** Changes every time the host starts; targets and observations of another generation are refused. */
  generation: string;
  options: Record<string, unknown>;
  /** Actual configuration source, for actionable setup instructions. */
  configPath?: string;
  stdioMcp(options: StdioMcpOptions): Promise<McpClient>;
  newestDir(pattern: string): string | null;
  shotsDir: string;
  log(...args: unknown[]): void;
  refuse(code: BackendRefusalCode, message: string, observation?: BackendObservation): Error;
};

export type Backend = {
  schema: 1;
  capabilities: {
    surfaces: ["computer"];
    observe: { ax: boolean; screenshot: boolean };
    actions: Partial<Record<BackendActionKind, BackendTier>>;
  };
  availability(call: BackendCall): Promise<BackendAvailability>;
  setup?(call: BackendCall, opts: BackendSetupOptions): Promise<BackendSetupResult>;
  targets(call: BackendCall): Promise<BackendTarget[]>;
  observe(call: BackendCall, targetId: string, opts: { screenshot?: boolean }): Promise<BackendObservation>;
  act(call: BackendCall, targetId: string, action: BackendAction, opts: { observationId: string; allowTiers: BackendTier[] }): Promise<BackendActResult>;
  dispose(): Promise<void>;
};

export type BackendFactory = (ctx: BackendContext) => Backend;

/** A refusal promises nothing was delivered. Any other error from act means the outcome is unknown. */
export class BackendRefusal extends Error {
  readonly code: BackendRefusalCode;
  readonly observation?: BackendObservation;

  constructor(code: BackendRefusalCode, message: string, observation?: BackendObservation) {
    super(message);
    this.name = "BackendRefusal";
    this.code = code;
    this.observation = observation;
  }
}
