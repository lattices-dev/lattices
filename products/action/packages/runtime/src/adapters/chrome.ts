import type {
  BrowserPageState,
  Bounds,
  ExtractionQuery,
  RuntimeAction,
  SemanticElement,
  SurfaceRef,
  TargetCandidate,
  TargetQuery,
} from "@action/protocol";
import {
  baseObservation,
  candidateFromSurface,
  defaultVerification,
  emptyExtractionResult,
  evidence,
  unsupportedActionResult,
} from "./helpers.js";
import type { SurfaceAdapter } from "./types.js";

const chromeBundleId = "com.google.Chrome";
const defaultCompanionBridgeURL = "http://127.0.0.1:4321";

type CompanionSurfaceTarget = {
  tabId?: number;
  url?: string;
  urlMatches?: string[];
  createUrl?: string;
  activate?: boolean;
};

type CompanionElementDescriptor = {
  selector: string | null;
  tagName: string;
  text: string;
  role: string | null;
  testId: string | null;
  name: string | null;
  value: string | null;
  rect: Bounds;
};

type CompanionObserveResult = {
  url: string;
  title: string;
  activeElement: CompanionElementDescriptor | null;
  elements: CompanionElementDescriptor[];
};

type CompanionMidjourneyResult = {
  href: string | null;
  imageUrl: string | null;
  text: string;
  rect: Bounds;
};

type CompanionMidjourneyState = {
  url: string;
  title: string;
  prompt: CompanionElementDescriptor | null;
  statusTexts: string[];
  results: CompanionMidjourneyResult[];
};

type CompanionActionResponse<T> =
  | { ok: true; result: T }
  | { ok: false; error: string };

type CompanionHealth = {
  ok: boolean;
  connected?: boolean;
  pending?: number;
  error?: string;
};

type CompanionMessage = {
  method: string;
  params?: Record<string, unknown>;
};

function surfaceLooksLikeChrome(surface: SurfaceRef): boolean {
  return surface.id.includes("com_google_chrome")
    || surface.label.toLowerCase().includes("chrome");
}

function companionBridgeURL(): string {
  return process.env.ACTION_CHROME_COMPANION_BRIDGE_URL ?? defaultCompanionBridgeURL;
}

async function companionHealth(): Promise<CompanionHealth> {
  try {
    const response = await fetch(`${companionBridgeURL()}/health`);
    return await response.json() as CompanionHealth;
  } catch (error) {
    return {
      ok: false,
      connected: false,
      error: errorMessage(error),
    };
  }
}

async function companionRPC<T>(message: CompanionMessage, timeoutMs?: number): Promise<T> {
  const response = await fetch(`${companionBridgeURL()}/rpc`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(message),
    ...(timeoutMs === undefined ? {} : { signal: AbortSignal.timeout(timeoutMs) }),
  });
  const payload = await response.json() as CompanionActionResponse<T>;
  if (!response.ok || !payload.ok) {
    throw new Error(payload.ok ? `Chrome Companion bridge returned ${response.status}.` : payload.error);
  }
  return payload.result;
}

function surfaceTargetFrom(input: Record<string, unknown> | undefined): CompanionSurfaceTarget | undefined {
  const rawSurface = input?.surface ?? input?.browserSurface ?? input?.tab;
  if (rawSurface && typeof rawSurface === "object") {
    const surface = rawSurface as Record<string, unknown>;
    return compactSurfaceTarget({
      tabId: numberValue(surface.tabId),
      url: stringValue(surface.url),
      urlMatches: stringArrayValue(surface.urlMatches),
      createUrl: stringValue(surface.createUrl),
      activate: booleanValue(surface.activate),
    });
  }

  return compactSurfaceTarget({
    tabId: numberValue(input?.tabId),
    url: stringValue(input?.url),
    urlMatches: stringArrayValue(input?.urlMatches),
    createUrl: stringValue(input?.createUrl),
    activate: booleanValue(input?.activate),
  });
}

function compactSurfaceTarget(target: CompanionSurfaceTarget): CompanionSurfaceTarget | undefined {
  const compacted = Object.fromEntries(
    Object.entries(target).filter(([, value]) => value !== undefined && (!Array.isArray(value) || value.length > 0)),
  ) as CompanionSurfaceTarget;
  return Object.keys(compacted).length > 0 ? compacted : undefined;
}

function browserPageStateFrom(result: CompanionObserveResult, metadata: Record<string, unknown>): BrowserPageState {
  return {
    kind: "browser-page",
    browser: "chrome",
    url: result.url,
    title: result.title,
    elements: result.elements.map(elementFromCompanion),
    metadata: {
      ...metadata,
      activeElement: result.activeElement ? elementFromCompanion(result.activeElement) : null,
    },
  };
}

function elementFromCompanion(element: CompanionElementDescriptor): SemanticElement {
  return {
    id: element.selector ?? `${element.tagName}:${element.text || element.name || "element"}`,
    role: element.role ?? element.tagName,
    label: element.name ?? element.text ?? element.tagName,
    text: element.text,
    selector: element.selector ?? undefined,
    rect: element.rect,
    attributes: {
      tagName: element.tagName,
      ...(element.testId ? { testId: element.testId } : {}),
      ...(element.value ? { value: element.value } : {}),
    },
  };
}

function candidateFromSemanticElement(surface: SurfaceRef, query: TargetQuery, element: SemanticElement, index: number): TargetCandidate {
  const label = element.label ?? element.text ?? element.selector ?? `DOM target ${index + 1}`;
  const confidence = element.rect ? 0.86 : 0.72;
  return {
    id: `${surface.id}:dom:${index}:${element.id}`,
    label,
    role: element.role,
    rect: element.rect,
    confidence,
    stabilityKey: element.selector,
    evidence: [
      evidence("dom", `Matched ${element.role ?? "element"} in Chrome DOM companion`, {
        rect: element.rect,
        confidence,
        metadata: {
          selector: element.selector,
          text: element.text,
          query,
        },
      }),
    ],
    preferredActionChannel: "dom",
    fallbackChannels: ["ax", "process", "hid"],
  };
}

function semanticElements(observation: { semantic?: unknown }): SemanticElement[] {
  const semantic = observation.semantic;
  if (!semantic || typeof semantic !== "object") {
    return [];
  }

  const page = semantic as { kind?: unknown; elements?: unknown };
  if (page.kind !== "browser-page" || !Array.isArray(page.elements)) {
    return [];
  }

  return page.elements.filter(isSemanticElement);
}

function matchesQuery(element: SemanticElement, query: TargetQuery): boolean {
  const text = query.text?.toLowerCase() ?? query.semanticId?.toLowerCase();
  const role = query.role?.toLowerCase();
  const haystack = [
    element.id,
    element.role,
    element.label,
    element.text,
    element.selector,
  ].filter(Boolean).join(" ").toLowerCase();

  if (role && element.role?.toLowerCase() !== role) {
    return false;
  }

  if (text && !haystack.includes(text)) {
    return false;
  }

  return true;
}

function queryForAction(action: RuntimeAction, target?: TargetCandidate): Record<string, unknown> {
  return {
    selector: stringValue(action.input?.selector) ?? target?.stabilityKey,
    text: stringValue(action.input?.targetText) ?? action.target?.text ?? action.target?.semanticId ?? target?.label,
    role: stringValue(action.input?.role) ?? action.target?.role ?? target?.role,
    testId: stringValue(action.input?.testId),
    index: numberValue(action.input?.index),
    surface: surfaceTargetFrom(action.input),
  };
}

function companionMethod(action: RuntimeAction): string | undefined {
  return stringValue(action.input?.companionMethod)
    ?? stringValue(action.input?.browserMethod)
    ?? stringValue(action.input?.method);
}

function actionText(action: RuntimeAction): string {
  return String(action.input?.text ?? action.input?.value ?? action.input?.prompt ?? "");
}

function stringValue(input: unknown): string | undefined {
  return typeof input === "string" && input.length > 0 ? input : undefined;
}

function numberValue(input: unknown): number | undefined {
  if (typeof input === "number" && Number.isFinite(input)) {
    return input;
  }
  if (typeof input === "string") {
    const parsed = Number(input);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function booleanValue(input: unknown): boolean | undefined {
  return typeof input === "boolean" ? input : undefined;
}

function stringArrayValue(input: unknown): string[] | undefined {
  if (!Array.isArray(input)) {
    return undefined;
  }
  const values = input.filter((value): value is string => typeof value === "string" && value.length > 0);
  return values.length > 0 ? values : undefined;
}

function isSemanticElement(input: unknown): input is SemanticElement {
  return Boolean(input && typeof input === "object" && typeof (input as { id?: unknown }).id === "string");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export const chromeAdapter: SurfaceAdapter = {
  id: "chrome",
  label: "Chrome",
  priority: 80,
  capabilities: ["observe", "resolve", "act", "extract", "capture-hints", "verify"],

  canHandle(surface: SurfaceRef) {
    const matched = surface.kind === "browser-tab" || (surface.kind === "window" && surfaceLooksLikeChrome(surface));
    return {
      matched,
      confidence: surface.kind === "browser-tab" ? 0.84 : matched ? 0.72 : 0,
      reason: matched
        ? "Chrome window detected; DOM companion can enrich AX observation when installed."
        : "Surface is not a Chrome window.",
      evidence: { bundleId: matched ? chromeBundleId : undefined },
    };
  },

  async observe(context) {
    const surface = surfaceTargetFrom(context.options);
    const health = await companionHealth();

    if (!health.connected) {
      return baseObservation(context.surface, context, {
        kind: "browser-page",
        browser: "chrome",
        elements: [],
        metadata: {
          status: "companion-unavailable",
          bridgeUrl: companionBridgeURL(),
          health,
          next: "Start the bridge and install/reload Action Chrome Companion.",
        },
      });
    }

    try {
      const result = await companionRPC<CompanionObserveResult>({
        method: "action.observe",
        params: {
          limit: numberValue(context.options?.limit) ?? 80,
          surface,
        },
      });

      return baseObservation(context.surface, context, browserPageStateFrom(result, {
        status: "companion",
        bridgeUrl: companionBridgeURL(),
        surface,
      }));
    } catch (error) {
      return baseObservation(context.surface, context, {
        kind: "browser-page",
        browser: "chrome",
        elements: [],
        metadata: {
          status: "companion-error",
          bridgeUrl: companionBridgeURL(),
          error: errorMessage(error),
        },
      });
    }
  },

  async resolve(query: TargetQuery, observation): Promise<TargetCandidate[]> {
    const candidates = semanticElements(observation)
      .filter((element) => matchesQuery(element, query))
      .slice(0, 12)
      .map((element, index) => candidateFromSemanticElement(observation.surface, query, element, index));

    if (candidates.length > 0) {
      return candidates;
    }

    return [
      {
        ...candidateFromSurface(observation.surface, query.text ?? query.semanticId ?? "Chrome page target", "dom"),
        confidence: 0.5,
        evidence: [
          evidence("dom", "No Chrome Companion DOM candidate matched; falling back to the Chrome surface.", {
            rect: observation.surface.bounds,
            confidence: 0.5,
          }),
        ],
        fallbackChannels: ["ax", "process", "hid"],
      },
    ];
  },

  async act(action: RuntimeAction, target?: TargetCandidate) {
    const explicitMethod = companionMethod(action);
    if (explicitMethod) {
      const params = {
        ...action.input,
        surface: surfaceTargetFrom(action.input),
      };
      const result = await companionRPC<unknown>({ method: explicitMethod, params });
      return {
        id: action.id,
        at: new Date().toISOString(),
        status: "succeeded",
        channel: "dom",
        detail: `Chrome Companion handled ${explicitMethod}.`,
        metadata: { result },
      };
    }

    if (action.kind === "type") {
      const result = await companionRPC<CompanionElementDescriptor>({
        method: "action.setValue",
        params: {
          ...queryForAction(action, target),
          value: actionText(action),
        },
      });
      return {
        id: action.id,
        at: new Date().toISOString(),
        status: "succeeded",
        channel: "dom",
        detail: "Chrome Companion set a DOM value without global keyboard input.",
        metadata: { result },
      };
    }

    if (action.kind === "click") {
      const result = await companionRPC<CompanionElementDescriptor>({
        method: "action.click",
        params: queryForAction(action, target),
      });
      return {
        id: action.id,
        at: new Date().toISOString(),
        status: "succeeded",
        channel: "dom",
        detail: "Chrome Companion clicked a DOM element without moving the OS pointer.",
        metadata: { result },
      };
    }

    return unsupportedActionResult(
      action.id,
      "dom",
      "Chrome Companion supports DOM type/click and explicit companionMethod actions for now.",
    );
  },

  async extract(query: ExtractionQuery) {
    const surface = surfaceTargetFrom(query.metadata);

    if (query.kind === "midjourney.results") {
      const result = await companionRPC<CompanionMidjourneyResult[]>({
        method: "midjourney.readResults",
        params: { surface },
      });
      return emptyExtractionResult(query, {
        status: "companion",
        results: result,
      });
    }

    if (query.kind === "midjourney.state" || query.kind === "midjourney.observe") {
      const result = await companionRPC<CompanionMidjourneyState>({
        method: "midjourney.observe",
        params: { surface },
      });
      return emptyExtractionResult(query, {
        status: "companion",
        ...result,
      });
    }

    const result = await companionRPC<CompanionObserveResult>({
      method: "action.observe",
      params: {
        selector: query.schema?.selector,
        text: query.text,
        role: query.role,
        surface,
        limit: query.schema?.limit,
      },
    });
    return emptyExtractionResult(query, {
      status: "companion",
      url: result.url,
      title: result.title,
      elements: result.elements.map(elementFromCompanion),
    });
  },

  async captureHints(target) {
    return target.rect
      ? [
          {
            id: `${target.id}:chrome-crop`,
            label: target.label,
            rect: target.rect,
            reason: "Chrome target candidate frame",
            padding: 32,
            preferredAspectRatio: "16:9",
            evidence: target.evidence,
          },
        ]
      : [];
  },

  async verify() {
    const health = await companionHealth();
    return defaultVerification(
      health.connected
        ? "Chrome Companion bridge is connected."
        : "Chrome Companion bridge is not connected.",
      Boolean(health.connected),
    );
  },
};

/** Explicit tab routing is required for the experimental observation-bound loop. */
export function chromeFastTransport(tabId: number, presentation: boolean | import("../../../chrome-companion/src/fast-presentation.js").FastPresentationPrefs = false): import("../fast-browser.js").FastTransport {
  const surface = { tabId, activate: Boolean(presentation) };
  return {
    observe: async () => {
      // Navigation destroys content-script contexts. Retry reads, never input.
      const deadline = Date.now() + 3000;
      while (true) {
        try { return await companionRPC<import("../../../chrome-companion/src/fast-actions.js").FastSnapshot>({ method: "action.fast.observe", params: { surface } }, 10_000); }
        catch (error) {
          if (Date.now() >= deadline || !/Receiving end does not exist|message port closed|frame.*removed/i.test(String(error))) throw error;
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    },
    act: choice => companionRPC({ method: "action.fast.act", params: { ...choice, surface } }, 10_000),
  };
}
