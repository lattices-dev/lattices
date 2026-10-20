import { BrowserTimeoutError, CDPSession, deadlineFetchJson, withDeadline, checkDeadline, boundedWait, deadlineSleep, remainingTimeout } from "./transport.ts";
import { localHTTPGet } from "../../../../packages/desktop-client/local-http.ts";
import { localEndpoint } from "../../../../packages/desktop-client/local-ipc.ts";

import { mkdir } from "node:fs/promises";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  assessNavigation,
  browserOpenMode,
  navigationIsReady,
  regularChromeLaunchArgs,
  shouldReuseCurrentTab,
} from "./navigation.ts";
import {
  DEFAULT_WINDOW_SIZE,
  MAX_DEVICE_SCALE_FACTOR,
  MAX_VIEWPORT_EDGE,
  MIN_DEVICE_SCALE_FACTOR,
  MIN_VIEWPORT_EDGE,
  measureDrift,
  parseResizeRequest,
  widthClass,
  windowBoundsFor,
  type ViewportOverride,
} from "./viewport.ts";
import {
  MAX_CAPTURE_EDGE,
  clipForRect,
  measureElementExpression,
  parseCaptureRequest,
  type CaptureRect,
} from "./capture.ts";
import {
  NAVIGATION_GRACE_MS,
  NETWORK_IDLE_QUIET_MS,
  NetworkIdleTracker,
  SETTLE_MODES,
  parseSettleRequest,
  parseWaitMs,
  POSTCONDITION_MARGIN_MS,
  selectorStateExpression,
  unsatisfiedNetworkIdleError,
  unsatisfiedSelectorError,
  type SettleRequest,
} from "./settle.ts";
import {
  CONSOLE_LEVELS,
  DEFAULT_CONSOLE_LIMIT,
  LOG_REPLAY_MS,
  MAX_CONSOLE_LIMIT,
  RECORDER_SOURCE,
  dedupeEntries,
  mergeAndDedupe,
  parseConsoleRequest,
  readRecorderExpression,
  selectEntries,
  summarize,
  toConsoleEntry,
  type ConsoleEntry,
  type ConsoleRequest,
} from "./console.ts";

type JsonObject = Record<string, unknown>;

type ChromeTarget = {
  id: string;
  type: string;
  title: string;
  url: string;
  webSocketDebuggerUrl?: string;
};

type ToolResult = {
  content: Array<
    | { type: "text"; text: string }
    | { type: "image"; data: string; mimeType: "image/png" }
  >;
  structuredContent?: JsonObject;
  isError?: boolean;
};

type BrowserClaim = {
  session: string;
  pid: number;
  ownerStartedAt: number;
  profile: string;
  profileDir: string;
  debugPort: number;
  claimedAt: string;
};

type ReleaseOutcome = {
  reason: string;
  closed: boolean;
  liveOwners: number;
};

const debugPort = Number(process.env.ACTION_BROWSER_DEBUG_PORT ?? "9334");
const profileRoot = process.env.ACTION_BROWSER_PROFILE_ROOT
  ?? process.env.ACTION_CHROME_COMPANION_PROFILE_ROOT
  ?? join(homedir(), "Library/Application Support/Action/ChromeProfiles");
const fixedProfileDir = process.env.ACTION_BROWSER_PROFILE_DIR
  ?? process.env.ACTION_CHROME_COMPANION_PROFILE_DIR;
let profileName = sanitizeProfileName(
  process.env.ACTION_BROWSER_PROFILE
    ?? process.env.ACTION_CHROME_COMPANION_PROFILE
    ?? "agent-browser",
);
let profileDir = fixedProfileDir ?? join(profileRoot, profileName);
const artifactRoot = process.env.ACTION_BROWSER_ARTIFACT_DIR
  ?? join(homedir(), "Library/Application Support/Action/BrowserArtifacts");
const sessionRoot = process.env.ACTION_BROWSER_SESSION_DIR
  ?? join(homedir(), "Library/Application Support/Action/BrowserSessions");
const sessionName = (process.env.ACTION_BROWSER_SESSION
  ?? `action-${process.pid}-${Math.random().toString(36).slice(2, 8)}`)
  .replace(/[^A-Za-z0-9._-]/g, "-");
const idleTimeoutMs = Math.max(0, Number(process.env.ACTION_BROWSER_IDLE_TIMEOUT_MS ?? "900000") || 0);
/**
 * Total deadlines for the interaction tools, matching browser_open's contract: a
 * budget for the whole call, not a per-step timeout. Shorter than open's 15s
 * because an interaction acts on a page that is already loaded.
 */
const CLICK_WAIT_MS = 10_000;
const FILL_WAIT_MS = 10_000;
const CONSOLE_WAIT_MS = 10_000;
const shutdownBudgetMs = Math.max(500, Number(process.env.ACTION_BROWSER_SHUTDOWN_TIMEOUT_MS ?? "4000") || 4_000);
const chromeAppName = process.env.ACTION_BROWSER_CHROME_APP ?? "Google Chrome";
const chromeBaseURL = `http://127.0.0.1:${debugPort}`;
const textDecoder = new TextDecoder();
let currentTargetId: string | undefined;
/**
 * Emulated viewports, keyed by tab id. A device-metrics override lives on the CDP
 * client session, so it would vanish with the socket every tool call closes. Keeping
 * it here and re-applying it per session is what makes a resize hold across a later
 * screenshot or snapshot. Nothing is written to the profile: quit Chrome and the
 * override is gone.
 */
const viewportOverrides = new Map<string, ViewportOverride>();
/**
 * Targets that already carry the page-side console recorder. The script is
 * installed with Page.addScriptToEvaluateOnNewDocument, which re-runs it on every
 * new document for the life of the tab, so it is installed once per target rather
 * than once per navigation.
 */
const consoleRecorderTargets = new Set<string>();
let claimHeld = false;
let ownsBrowser = false;
let shuttingDown = false;
let idleTimer: ReturnType<typeof setTimeout> | undefined;

function sanitizeProfileName(name: string): string {
  const cleaned = name.trim().replace(/[^A-Za-z0-9._-]/g, "-");
  if (!cleaned || cleaned === "." || cleaned === "..") {
    throw new Error(`Invalid Action profile name: ${name}`);
  }
  return cleaned;
}

/**
 * Where Action's own checkout lives, for the Chrome Companion extension paths
 * below. This used to be `../../..` back when the server sat inside Action's
 * plugin directory; now the server ships with the lattices CLI, so the Action
 * tree is a sibling of `bin/` rather than an ancestor of this file -- and in a
 * published npm install it is absent entirely. Companion features degrade to
 * "not installed" in that case, which is the honest answer.
 */
function resolveActionRoot(): string {
  if (process.env.ACTION_ROOT) return resolve(process.env.ACTION_ROOT);
  // bin/mcp/toolsets/browser -> lattices root
  const latticesRoot = resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
  return join(latticesRoot, "products/action");
}

function companionScriptsDir(): string {
  return join(resolveActionRoot(), "packages/chrome-companion/scripts");
}

function companionDistDir(): string {
  return join(resolveActionRoot(), "packages/chrome-companion/dist");
}

function writeProfileMeta(name: string, dir: string): void {
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, ".action-profile.json"),
      `${JSON.stringify({
        name,
        profileDir: dir,
        extensionDist: companionDistDir(),
        debugPort,
        updatedAt: new Date().toISOString(),
      }, null, 2)}\n`,
    );
  } catch {
    // Metadata is best-effort.
  }
}

function listActionProfilesOnDisk(): Array<{
  name: string;
  userDataDir: string;
  current: boolean;
  hasCookiesDb: boolean;
  meta: JsonObject | null;
}> {
  if (!existsSync(profileRoot)) return [];
  return readdirSync(profileRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => {
      const userDataDir = join(profileRoot, entry.name);
      const defaultDir = existsSync(join(userDataDir, "Cookies"))
        ? userDataDir
        : join(userDataDir, "Default");
      const metaPath = join(userDataDir, ".action-profile.json");
      let meta: JsonObject | null = null;
      if (existsSync(metaPath)) {
        try {
          meta = JSON.parse(readFileSync(metaPath, "utf8")) as JsonObject;
        } catch {
          meta = null;
        }
      }
      return {
        name: entry.name,
        userDataDir,
        current: userDataDir === profileDir,
        hasCookiesDb: existsSync(join(defaultDir, "Cookies")),
        meta,
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

async function loadCookieModule(): Promise<{
  importCookiesToActionProfile: (args: {
    into?: string;
    sourceProfile?: string;
    domains?: string[];
    selectors?: Array<{ hostKey?: string; name: string }>;
  }) => {
    into: string;
    sourceProfilePath: string;
    destUserDataDir: string;
    destProfilePath: string;
    cookies: string[];
    count: number;
  };
  listCookieEntries: (
    profileDir: string,
    opts: { domains?: string[]; selectors?: Array<{ hostKey?: string; name: string }> },
  ) => Array<{ hostKey: string; name: string }>;
  listPersonalProfiles: () => Array<{ dir: string; name: string; path: string }>;
  parseCookieSelectors: (specs: string[]) => Array<{ hostKey?: string; name: string }>;
  resolveSourceProfileDir: (profileDir?: string) => string;
}> {
  const modulePath = join(companionScriptsDir(), "chrome-cookies.mjs");
  if (!existsSync(modulePath)) {
    throw new Error(
      `Cookie tooling not found at ${modulePath}. ` +
      "Set ACTION_ROOT to the Action monorepo root when using the marketplace plugin outside the repo.",
    );
  }
  return await import(modulePath);
}

// The three browsers an agent can end up talking to. Keep this list, the tool
// descriptions, docs/browser-profiles.md, and the skill saying the same thing.
const BROWSER_SURFACES = [
  {
    id: "regular-chrome",
    label: "The user's regular Chrome",
    what: "Their everyday browser and its real profiles (Default, Profile 1 / \"Work\", ...), with their tabs, history, extensions, and logins.",
    reach: "browser_open with mode=regular opens a URL there and stops. No CDP, no DOM tools.",
    control: "Action native screen + accessibility control: action.observe.snapshot, action.resolve.target, action.act.execute.",
    why: "Chrome 136 and later ignore remote-debugging switches for the user's default data directory, and Action does not try to bypass that.",
  },
  {
    id: "action-browser",
    label: "An Action browser",
    what: "A real, non-headless Chrome that Action owns, running on its own user-data-dir. The default identity agent-browser starts blank and signed into nothing.",
    reach: "Full DOM tooling: browser_snapshot, browser_click, browser_fill, browser_screenshot, browser_tabs.",
    control: "CDP on a private debug port, plus the optional Chrome Companion extension for richer observe/act.",
    why: "Isolated from the user's browsing, so an agent can drive it without touching their session.",
  },
  {
    id: "action-identity",
    label: "An Action browser identity seeded from a regular Chrome profile",
    what: "The same Action-owned Chrome under a named identity (for example work), carrying cookies copied from one of the user's real Chrome profiles for an explicit domain allowlist.",
    reach: "Full DOM tooling, on pages the user is already signed in to.",
    control: "browser_import_cookies to seed, browser_use_profile or browser_open profile to drive.",
    why: "The way to get signed-in DOM control without automating the user's own browser.",
  },
] as const;

export const tools = [
  {
    name: "browser_profiles",
    title: "List Action Browser Identities",
    description: "List the Action browser identities on this machine (named Chrome profiles Action owns under ChromeProfiles) and which one is active. These are not the user's regular Chrome profiles. Only an Action browser can be driven with browser_snapshot / browser_click / browser_fill / browser_screenshot.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_use_profile",
    title: "Use Action Browser Identity",
    description: "Switch the active Action browser identity to a named profile. Any name is valid; an unknown name creates a fresh blank identity on first open. Closes the Action Chrome this session owned. This never attaches to the user's regular Chrome, which is driven through Action's native screen + accessibility tools instead.",
    inputSchema: {
      type: "object",
      properties: {
        profile: {
          type: "string",
          description: "Action browser identity name. agent-browser is the blank default. Use a descriptive name such as work for an identity seeded from a regular Chrome profile via browser_import_cookies.",
        },
      },
      required: ["profile"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: true },
  },
  {
    name: "browser_profile_info",
    title: "Current Browser Identity Info",
    description: "Report the active Action browser identity: profile name, user-data-dir, whether it already has a cookie store, CDP port, companion extension dist, and optional companion bridge health.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_import_cookies",
    title: "Seed Action Browser Identity From Regular Chrome",
    description: "Copy selected cookies from one of the user's regular Chrome profiles into an Action browser identity, so that identity is signed in for those domains and can still be driven with DOM tools. Dry-run unless confirm=true. Always scope with a domain allowlist; this never dumps the full cookie jar by default. Canonical example: source \"Profile 1\" (the directory behind the user's Work browser) into \"work\" with domains [\"github.com\"].",
    inputSchema: {
      type: "object",
      properties: {
        into: {
          type: "string",
          description: "Action browser identity to seed, e.g. work. Created on first open if it does not exist. Defaults to the active identity.",
        },
        source: {
          type: "string",
          description: "Regular Chrome profile DIRECTORY name, not its display name: Default, Profile 1, Profile 2, ... A browser the user calls \"Work\" is usually the Profile 1 directory. Call with listSourceProfiles=true to map display names to directories. Defaults to the most recently used.",
        },
        domains: {
          type: "array",
          items: { type: "string" },
          description: "Host suffixes to import, e.g. [\"github.com\", \"midjourney.com\"].",
        },
        only: {
          type: "array",
          items: { type: "string" },
          description: "Optional cookie names or host:name selectors.",
        },
        confirm: {
          type: "boolean",
          default: false,
          description: "When true, write cookies. When false/omitted, list matches only.",
        },
        listSourceProfiles: {
          type: "boolean",
          default: false,
          description: "When true, list the user's regular Chrome profiles (directory name plus display name) and return.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false },
  },
  {
    name: "browser_companion_status",
    title: "Chrome Companion Status",
    description: "Check whether the Action Chrome Companion extension dist exists and whether the localhost bridge reports a live connection for richer DOM act/observe.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_open",
    title: "Open Browser URL",
    description: "Open a URL in one of two different browsers. mode=action (default) uses an Action browser identity that this plugin can then snapshot, click, fill, and screenshot over CDP. mode=regular hands the URL to the user's own everyday Chrome: visible, already signed in as them, and deliberately not DOM-controllable — drive that window with Action's native screen + accessibility tools (action.observe.* then action.act.execute) instead. To get DOM control of a signed-in session, seed an Action identity with browser_import_cookies rather than reaching for mode=regular.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to open. https:// is added when no scheme is provided." },
        mode: {
          type: "string",
          enum: ["action", "regular"],
          default: "action",
          description: "action = Action browser identity with DOM tools (default). regular = open-only handoff to the user's normal Chrome; browser_snapshot / browser_click / browser_fill / browser_screenshot do not reach it.",
        },
        profile: {
          type: "string",
          description: "Action mode only. Action browser identity to use, e.g. agent-browser (blank) or work (seeded from a regular Chrome profile). Created on first use.",
        },
        background: { type: "boolean", default: true, description: "Action mode only: keep Chrome hidden in the background. Regular mode is always visible." },
        waitMs: { type: "number", minimum: 0, maximum: 2_147_483_647, default: 15_000, description: "Total deadline in milliseconds, including startup, connection, navigation, and readiness. Zero fails immediately." },
        newTab: { type: "boolean", default: false, description: "Action mode only: create a separate tab instead of reusing this session's current tab." },
      },
      required: ["url"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false },
  },
  {
    name: "browser_tabs",
    title: "List Action Browser Tabs",
    description: "List open page tabs in the active Action browser identity. Tabs in the user's regular Chrome are not visible here.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_snapshot",
    title: "Inspect Browser Page",
    description: "Read page metadata, visible text, and stable selectors for interactive elements in the active Action browser, plus a console summary saying whether the page logged any errors. Does not reach pages opened with mode=regular; use action.observe.snapshot for those.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id from browser_open or browser_tabs." },
        maxTextChars: { type: "number", default: 12_000, description: "Maximum visible-text characters." },
        maxElements: { type: "number", default: 80, description: "Maximum interactive elements." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_click",
    title: "Click Browser Element",
    description: "Click a DOM element by CSS selector or visible text in the active Action browser, and wait for a named result rather than guessing. Use settle and/or waitForSelector so the next tool call sees the page the click produced. Does not reach pages opened with mode=regular; use action.act.execute for those.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id." },
        selector: { type: "string", description: "Preferred CSS selector from browser_snapshot." },
        text: { type: "string", description: "Visible text fallback when a selector is unavailable." },
        waitMs: { type: "number", minimum: 0, maximum: 2_147_483_647, default: 10000, description: "Total deadline in milliseconds for the interaction and everything it waits for. Exceeding it fails with a message naming what never happened." },
        settle: {
          type: "string",
          enum: [...SETTLE_MODES],
          default: "paint",
          description: "What counts as done. none = return immediately. paint = wait for the next two frames (a re-render). navigation = if a navigation starts, wait for the new document to be ready; if none starts within 1.5s, stop waiting. network-idle = wait until no request has been in flight for 500ms.",
        },
        waitForSelector: { type: "string", description: "Additionally wait until this CSS selector is visible (or, with waitForSelectorGone, until it stops matching). This is the postcondition: if it never holds, the call fails saying so instead of returning a page that never changed." },
        waitForSelectorGone: { type: "boolean", default: false, description: "Invert waitForSelector: wait until it stops matching. Use for a spinner that must disappear or a dialog that must close." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false },
  },
  {
    name: "browser_fill",
    title: "Fill Browser Field",
    description: "Set the value of an input, textarea, select, or contenteditable element in the active Action browser and dispatch input/change events. Waits for nothing by default, because most fills do not navigate; pass settle or waitForSelector when this one triggers a search, a validation message, or a form submit. Does not reach pages opened with mode=regular.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id." },
        selector: { type: "string", description: "CSS selector for the field." },
        value: { type: "string", description: "Text value to enter." },
        waitMs: { type: "number", minimum: 0, maximum: 2_147_483_647, default: 10000, description: "Total deadline in milliseconds for the interaction and everything it waits for. Exceeding it fails with a message naming what never happened." },
        settle: {
          type: "string",
          enum: [...SETTLE_MODES],
          default: "none",
          description: "What counts as done. none = return immediately. paint = wait for the next two frames (a re-render). navigation = if a navigation starts, wait for the new document to be ready; if none starts within 1.5s, stop waiting. network-idle = wait until no request has been in flight for 500ms.",
        },
        waitForSelector: { type: "string", description: "Additionally wait until this CSS selector is visible (or, with waitForSelectorGone, until it stops matching). This is the postcondition: if it never holds, the call fails saying so instead of returning a page that never changed." },
        waitForSelectorGone: { type: "boolean", default: false, description: "Invert waitForSelector: wait until it stops matching. Use for a spinner that must disappear or a dialog that must close." },
      },
      required: ["selector", "value"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false },
  },
  {
    name: "browser_resize",
    title: "Resize Browser Viewport",
    description: "Set the viewport of an already-open Action browser tab to an explicit width and height, so responsive breakpoints can be exercised and screenshotted. target=tab (default) emulates the size for that one tab only and is exact, reversible, and invisible to every other tab; target=window resizes the real Chrome window hosting the tab, which moves every tab in it and may be clamped by the display. The size sticks across later browser_open / browser_snapshot / browser_screenshot calls on that tab until reset, and is dropped when the tab or the browser closes -- nothing is written to the profile. Send reset=true to restore the default size. Does not reach pages opened with mode=regular.",
    inputSchema: {
      type: "object",
      properties: {
        width: {
          type: "integer",
          minimum: MIN_VIEWPORT_EDGE,
          maximum: MAX_VIEWPORT_EDGE,
          description: `Viewport width in CSS pixels, ${MIN_VIEWPORT_EDGE}-${MAX_VIEWPORT_EDGE}. Required unless reset is true. Example breakpoints: 390 phone, 768 tablet, 1280 laptop, 1920 desktop.`,
        },
        height: {
          type: "integer",
          minimum: MIN_VIEWPORT_EDGE,
          maximum: MAX_VIEWPORT_EDGE,
          description: `Viewport height in CSS pixels, ${MIN_VIEWPORT_EDGE}-${MAX_VIEWPORT_EDGE}. Required unless reset is true.`,
        },
        target: {
          type: "string",
          enum: ["tab", "window"],
          default: "tab",
          description: "tab = emulate the size for this tab only (default, exact, reversible). window = resize the real Chrome window, which affects every tab in it, may be clamped by the display, and drops any emulated viewport on this tab first so the new window size is what the page actually sees.",
        },
        tabId: { type: "string", description: "Optional tab id from browser_open or browser_tabs. Defaults to this session's current tab." },
        deviceScaleFactor: {
          type: "number",
          minimum: MIN_DEVICE_SCALE_FACTOR,
          maximum: MAX_DEVICE_SCALE_FACTOR,
          default: 1,
          description: "target=tab only. Device pixel ratio. 1 makes screenshot pixels equal CSS pixels; use 2 for a retina-density capture.",
        },
        mobile: {
          type: "boolean",
          default: false,
          description: "target=tab only. Emulate a mobile device: honour the viewport meta tag and enable touch. False is desktop responsive mode.",
        },
        matchMedia: {
          type: "array",
          items: { type: "string" },
          description: "Optional media queries to evaluate after the resize, e.g. [\"(max-width: 768px)\"]. Returns which ones match, so a breakpoint can be asserted instead of eyeballed.",
        },
        reset: {
          type: "boolean",
          default: false,
          description: `When true, drop the override: target=tab returns the tab to the real window viewport, target=window restores the default ${DEFAULT_WINDOW_SIZE.width}x${DEFAULT_WINDOW_SIZE.height} window. Cannot be combined with width or height.`,
        },
      },
      // "width and height are required unless reset is true" is a real constraint
      // that a flat `required` list cannot say. Spelling it out here rejects an
      // empty call at the schema instead of at runtime.
      anyOf: [
        { required: ["width", "height"] },
        { required: ["reset"], properties: { reset: { const: true } } },
      ],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: true },
  },
  {
    name: "browser_screenshot",
    title: "Capture Browser Screenshot",
    description: "Capture the active Action browser page as a PNG, save it locally, and return the image to the agent. Four areas, one at a time: the viewport (default), one element via selector, an explicit clip, or fullPage. Prefer selector for reviewing a single component -- it is captured at scale 1, so the PNG needs no cropping and its pixels still correspond to CSS pixels. Does not reach pages opened with mode=regular; capture those with Action's native screen tools.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id." },
        outputPath: { type: "string", description: "Optional absolute PNG path." },
        selector: { type: "string", description: "Capture just this element, at its exact rendered size. Use a selector from browser_snapshot. Fails with the rendered size when the element has none, rather than returning a blank frame." },
        padding: { type: "number", minimum: 0, default: 0, description: "selector only. CSS pixels of breathing room around the element, clamped to the document edges." },
        clip: {
          type: "object",
          description: "Capture an explicit rectangle in document coordinates (page origin, not viewport origin).",
          properties: {
            x: { type: "number", minimum: 0 },
            y: { type: "number", minimum: 0 },
            width: { type: "number", exclusiveMinimum: 0 },
            height: { type: "number", exclusiveMinimum: 0 },
          },
          required: ["x", "y", "width", "height"],
          additionalProperties: false,
        },
        fullPage: { type: "boolean", default: false, description: `Capture the whole document instead of the viewport. Emitted at scale 1 like every other area, but a document past Chrome's ${MAX_CAPTURE_EDGE}px limit is cut off -- the result says so. Reach for selector or clip when the target is one component.` },
        includeImage: { type: "boolean", default: true, description: "Include image bytes in the MCP response." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, idempotentHint: false },
  },
  {
    name: "browser_console",
    title: "Read Browser Console",
    description: "Read what the active Action browser page logged: console calls, uncaught errors, unhandled rejections, and Chrome's own log (failed subresources, blocked requests, CSP violations). Ask this when a page looks blank or wrong -- a screenshot cannot say why it failed. History is complete for pages opened with browser_open; the reply's coverage field says so per call.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id. Defaults to this session's current tab." },
        levels: {
          type: "array",
          items: { type: "string", enum: [...CONSOLE_LEVELS] },
          minItems: 1,
          default: [...CONSOLE_LEVELS],
          description: "Levels to return. Narrow to [\"error\", \"warn\"] when triaging a broken page.",
        },
        limit: { type: "integer", minimum: 1, maximum: MAX_CONSOLE_LIMIT, default: DEFAULT_CONSOLE_LIMIT, description: "Most recent entries to return, newest last." },
        clear: { type: "boolean", default: false, description: "Empty the page-side buffer after reading, so the next call reports only what happened next." },
        waitMs: { type: "number", minimum: 0, maximum: 2_147_483_647, default: 10_000, description: "Total deadline in milliseconds." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, idempotentHint: true },
  },
  {
    name: "browser_close",
    title: "Close Browser Tab or Session",
    description: "Close a tab in the active Action browser identity, or release this session's browser entirely. Never closes anything in the user's regular Chrome.",
    inputSchema: {
      type: "object",
      properties: {
        tabId: { type: "string", description: "Optional tab id. Defaults to the current Action Browser tab." },
        scope: {
          type: "string",
          enum: ["tab", "browser"],
          default: "tab",
          description: "Close a single tab (default) or quit Chrome once no other live session still claims it.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false },
  },
];

function normalizeURL(value: string): string {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value) || value.startsWith("chrome://")) {
    return value;
  }
  return `https://${value}`;
}

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  return deadlineFetchJson<T>(`${chromeBaseURL}${path}`, init);
}

async function chromeIsReady(): Promise<boolean> {
  try {
    await fetchJson("/json/version");
    return true;
  } catch (error) {
    // A stalled endpoint may belong to a live Chrome; do not launch another.
    if (error instanceof BrowserTimeoutError) throw error;
    checkDeadline();
    return false;
  }
}

function probe(command: string[]): string {
  try {
    const result = Bun.spawnSync(command, { stdout: "pipe", stderr: "ignore", timeout: remainingTimeout(1_000), killSignal: "SIGKILL" });
    checkDeadline();
    return result.success ? textDecoder.decode(result.stdout).trim() : "";
  } catch {
    checkDeadline();
    return "";
  }
}

function note(event: string, detail: JsonObject = {}): void {
  try {
    process.stderr.write(`${JSON.stringify({ scope: "action-browser", session: sessionName, event, ...detail })}\n`);
  } catch {
    // A closed transport must never break shutdown.
  }
}

function processIsRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as { code?: string }).code === "EPERM";
  }
}

function processStartedAt(pid: number): number | undefined {
  const started = Date.parse(probe(["/bin/ps", "-p", String(pid), "-o", "lstart="]));
  return Number.isFinite(started) ? started : undefined;
}

function signalProcess(pid: number, signal: "SIGTERM" | "SIGKILL"): void {
  try {
    process.kill(pid, signal);
  } catch {
    // Already gone.
  }
}

const ownerStartedAt = processStartedAt(process.pid) ?? Date.now();

function pidFromSessionName(name: string): number {
  const match = /^action-(\d+)(?:-|$)/.exec(name);
  return match ? Number(match[1]) : 0;
}

function claimPath(session: string): string {
  return join(sessionRoot, `${session}.json`);
}

function readClaims(): BrowserClaim[] {
  let entries: string[];
  try {
    entries = readdirSync(sessionRoot);
  } catch {
    return [];
  }
  const claims: BrowserClaim[] = [];
  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const session = entry.slice(0, -".json".length);
    try {
      const claim = JSON.parse(readFileSync(join(sessionRoot, entry), "utf8")) as Partial<BrowserClaim>;
      const pid = Number.isInteger(claim.pid) ? Number(claim.pid) : pidFromSessionName(session);
      if (pid <= 0) throw new Error("Claim has no resolvable owner pid.");
      claims.push({
        session,
        pid,
        ownerStartedAt: Number(claim.ownerStartedAt),
        profile: String(claim.profile ?? profileName),
        profileDir: String(claim.profileDir ?? profileDir),
        debugPort: Number(claim.debugPort ?? debugPort),
        claimedAt: String(claim.claimedAt ?? ""),
      });
    } catch {
      try {
        unlinkSync(join(sessionRoot, entry));
      } catch {
        // Another session may have swept it already.
      }
    }
  }
  return claims;
}

function ownerIsAlive(claim: BrowserClaim): boolean {
  if (!processIsRunning(claim.pid)) return false;
  if (!Number.isFinite(claim.ownerStartedAt)) return true;
  const startedAt = processStartedAt(claim.pid);
  return startedAt === undefined || startedAt <= claim.ownerStartedAt + 2_000;
}

function claimTargetsThisBrowser(claim: BrowserClaim): boolean {
  return claim.profileDir === profileDir && claim.debugPort === debugPort;
}

function claimBrowser(): void {
  if (claimHeld || shuttingDown) return;
  const claim: BrowserClaim = {
    session: sessionName,
    pid: process.pid,
    ownerStartedAt,
    profile: profileName,
    profileDir,
    debugPort,
    claimedAt: new Date().toISOString(),
  };
  try {
    mkdirSync(sessionRoot, { recursive: true });
    const staging = join(sessionRoot, `.${sessionName}.tmp`);
    writeFileSync(staging, `${JSON.stringify(claim, null, 2)}\n`);
    renameSync(staging, claimPath(sessionName));
    claimHeld = true;
    ownsBrowser = true;
    note("claim", { pid: process.pid, profileDir, debugPort });
  } catch {
    // Losing the registry must not block browser work.
  }
}

function releaseClaim(): void {
  claimHeld = false;
  try {
    unlinkSync(claimPath(sessionName));
  } catch {
    // Nothing to release.
  }
}

function sweepClaims(): { liveOwners: number; staleOwners: number } {
  let liveOwners = 0;
  let staleOwners = 0;
  for (const claim of readClaims()) {
    if (claim.session === sessionName) continue;
    if (ownerIsAlive(claim)) {
      if (claimTargetsThisBrowser(claim)) liveOwners += 1;
      continue;
    }
    if (claimTargetsThisBrowser(claim)) staleOwners += 1;
    try {
      unlinkSync(claimPath(claim.session));
    } catch {
      // Another session may have swept it already.
    }
  }
  return { liveOwners, staleOwners };
}

function chromeProcessId(): number | undefined {
  let link: string;
  try {
    link = readlinkSync(join(profileDir, "SingletonLock"));
  } catch {
    return undefined;
  }
  const pid = Number(link.slice(link.lastIndexOf("-") + 1));
  if (!Number.isInteger(pid) || pid <= 1) return undefined;
  return probe(["/bin/ps", "-p", String(pid), "-o", "command="]).includes(`--user-data-dir=${profileDir}`)
    ? pid
    : undefined;
}

async function closeChrome(): Promise<boolean> {
  checkDeadline();
  const chromePid = chromeProcessId();
  try {
    const version = await fetchJson<{ webSocketDebuggerUrl?: string }>("/json/version");
    if (version.webSocketDebuggerUrl) {
      const session = await CDPSession.connect(version.webSocketDebuggerUrl);
      await Promise.race([session.call("Browser.close").catch(() => {}), Bun.sleep(1_500)]);
      session.close();
    }
  } catch {
    checkDeadline();
    // Chrome is unreachable; fall through to the signal ladder.
  }
  checkDeadline();
  if (chromePid === undefined) return !(await chromeIsReady());
  for (let attempt = 0; attempt < 24; attempt += 1) {
    if (!processIsRunning(chromePid)) return true;
    if (attempt === 2) signalProcess(chromePid, "SIGTERM");
    if (attempt === 16) signalProcess(chromePid, "SIGKILL");
    await deadlineSleep(125);
  }
  return !processIsRunning(chromePid);
}

async function releaseBrowser(reason: string): Promise<ReleaseOutcome> {
  releaseClaim();
  const { liveOwners } = sweepClaims();
  if (liveOwners > 0) {
    ownsBrowser = false;
    return { reason, closed: false, liveOwners };
  }
  const closed = await closeChrome();
  if (closed) ownsBrowser = false;
  return { reason, closed, liveOwners };
}

async function releaseOwnedBrowser(reason: string): Promise<ReleaseOutcome | undefined> {
  return ownsBrowser ? await releaseBrowser(reason) : undefined;
}

function releaseBrowserSync(): void {
  if (!ownsBrowser) return;
  releaseClaim();
  if (sweepClaims().liveOwners > 0) return;
  const chromePid = chromeProcessId();
  if (chromePid !== undefined) signalProcess(chromePid, "SIGTERM");
}

async function sweepOrphans(): Promise<void> {
  const { liveOwners, staleOwners } = sweepClaims();
  if (staleOwners === 0 || liveOwners > 0) return;
  if (chromeProcessId() === undefined && !(await chromeIsReady())) return;
  const closed = await closeChrome();
  note("sweep", { staleOwners, closed });
}

function scheduleIdleRelease(): void {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = undefined;
  if (idleTimeoutMs <= 0 || shuttingDown) return;
  const timer = setTimeout(() => {
    void releaseOwnedBrowser("idle").then((outcome) => {
      if (outcome) note("idle", outcome);
    });
  }, idleTimeoutMs);
  timer.unref();
  idleTimer = timer;
}

/**
 * Give Chrome up, within a budget. The router calls this and then exits; this
 * function deliberately does not exit itself, so a second toolset's shutdown is
 * not cut short by the first one finishing.
 */
async function shutdownBrowser(reason: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  if (idleTimer) clearTimeout(idleTimer);
  const owned = ownsBrowser;
  const outcome = await Promise.race([
    releaseOwnedBrowser(reason),
    Bun.sleep(shutdownBudgetMs).then(() => undefined),
  ]);
  note("shutdown", { reason, owned, closed: outcome?.closed ?? false, timedOut: owned && outcome === undefined });
}

/**
 * The last-resort release, run from a `process.on("exit")` handler where nothing
 * may await. Owner dies, browser dies -- even on a path that never reached the
 * graceful shutdown above.
 */
function shutdownBrowserSync(): void {
  releaseBrowserSync();
}

async function useProfile(nextName: string): Promise<{
  profile: string;
  profileDir: string;
  switched: boolean;
  closedPrevious: boolean;
}> {
  if (fixedProfileDir) {
    throw new Error(
      "ACTION_BROWSER_PROFILE_DIR is fixed for this MCP process; unset it to switch named profiles.",
    );
  }
  const name = sanitizeProfileName(nextName);
  const nextDir = join(profileRoot, name);
  if (name === profileName && nextDir === profileDir) {
    writeProfileMeta(profileName, profileDir);
    return { profile: profileName, profileDir, switched: false, closedPrevious: false };
  }
  let closedPrevious = false;
  if (ownsBrowser) {
    const outcome = await releaseBrowser("profile-switch");
    closedPrevious = outcome.closed;
    currentTargetId = undefined;
    viewportOverrides.clear();
  }
  checkDeadline();
  profileName = name;
  profileDir = nextDir;
  writeProfileMeta(profileName, profileDir);
  return { profile: profileName, profileDir, switched: true, closedPrevious };
}

async function companionStatus(): Promise<JsonObject> {
  const dist = companionDistDir();
  const distExists = existsSync(dist);
  const manifestPath = join(dist, "manifest.json");
  let bridge: JsonObject = { ok: false, connected: false };
  try {
    bridge = await localHTTPGet<JsonObject>("action-chrome", "/health", remainingTimeout(3000));
  } catch (error) {
    bridge = {
      ok: false,
      connected: false,
      error: error instanceof Error ? error.message : String(error),
      hint: "Start the bridge with: bun run chrome:companion:bridge",
    };
  }

  let extensionTargets: Array<{ type: string; title: string; url: string }> = [];
  let extensionIds: string[] = [];
  if (await chromeIsReady()) {
    try {
      const targets = await fetchJson<ChromeTarget[]>("/json/list");
      extensionTargets = targets
        .filter((target) => typeof target.url === "string" && target.url.includes("chrome-extension://"))
        .map((target) => ({ type: target.type, title: target.title, url: target.url }));
      extensionIds = [
        ...new Set(
          extensionTargets
            .map((target) => target.url.match(/^chrome-extension:\/\/([^/]+)\//)?.[1])
            .filter((id): id is string => Boolean(id)),
        ),
      ];
    } catch {
      // Chrome may not expose targets yet.
    }
  }

  return {
    profile: profileName,
    profileDir,
    companionDist: dist,
    companionDistExists: distExists,
    companionManifestExists: existsSync(manifestPath),
    bridgeSocketPath: localEndpoint("action-chrome").socketPath,
    bridge,
    extensionTargets,
    extensionIds,
    setupHint: distExists
      ? `Load unpacked extension once in this Action profile: ${dist}`
      : "Build companion first: bun run chrome:companion:build",
  };
}

async function ensureChrome(background = true): Promise<void> {
  if (await chromeIsReady()) {
    claimBrowser();
    return;
  }

  checkDeadline();
  await boundedWait(mkdir(profileDir, { recursive: true }), "Create Chrome profile");
  checkDeadline();
  writeProfileMeta(profileName, profileDir);
  const openArgs = [
    "/usr/bin/open",
    "-n",
    "-a",
    chromeAppName,
  ];
  if (background) {
    openArgs.push("-j", "-g");
  }
  openArgs.push(
    "--args",
    `--user-data-dir=${profileDir}`,
    `--remote-debugging-port=${debugPort}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    `--window-size=${DEFAULT_WINDOW_SIZE.width},${DEFAULT_WINDOW_SIZE.height}`,
    "about:blank",
  );

  checkDeadline();
  const launch = Bun.spawn(openArgs, { stdout: "ignore", stderr: "pipe" });
  const status = await boundedWait(launch.exited, "Launch Chrome", () => launch.kill());
  if (status !== 0) {
    const stderr = await boundedWait(new Response(launch.stderr).text(), "Read Chrome launch error");
    throw new Error(stderr.trim() || `Could not launch ${chromeAppName}.`);
  }

  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (await chromeIsReady()) {
      claimBrowser();
      return;
    }
    await deadlineSleep(250);
  }

  throw new Error(`Chrome did not expose its local debugging port at ${chromeBaseURL}.`);
}

async function listTargets(): Promise<ChromeTarget[]> {
  await ensureChrome();
  const targets = (await fetchJson<ChromeTarget[]>("/json/list"))
    .filter((target) => target.type === "page" && Boolean(target.webSocketDebuggerUrl));
  if (viewportOverrides.size > 0 || consoleRecorderTargets.size > 0) {
    const live = new Set(targets.map((target) => target.id));
    for (const id of viewportOverrides.keys()) {
      if (!live.has(id)) viewportOverrides.delete(id);
    }
    for (const id of consoleRecorderTargets) {
      if (!live.has(id)) consoleRecorderTargets.delete(id);
    }
  }
  return targets;
}

async function targetFor(tabId?: unknown): Promise<ChromeTarget> {
  const targets = await listTargets();
  const requestedId = typeof tabId === "string" ? tabId : currentTargetId;
  const target = requestedId
    ? targets.find((candidate) => candidate.id === requestedId)
    : targets.find((candidate) => !candidate.url.startsWith("chrome://")) ?? targets[0];
  if (!target?.webSocketDebuggerUrl) {
    throw new Error("No Action Browser tab is available. Call browser_open first.");
  }
  currentTargetId = target.id;
  return target;
}

async function withTarget<T>(tabId: unknown, work: (session: CDPSession, target: ChromeTarget) => Promise<T>): Promise<T> {
  const target = await targetFor(tabId);
  const session = await CDPSession.connect(target.webSocketDebuggerUrl!);
  try {
    await applyViewportOverride(session, target.id);
    return await work(session, target);
  } finally {
    session.close();
  }
}

/**
 * Re-apply this tab's emulated viewport on a fresh CDP session. Failure throws
 * rather than degrading quietly: a screenshot taken at the wrong width would look
 * like a verified breakpoint when nothing was verified.
 */
async function applyViewportOverride(session: CDPSession, targetId: string): Promise<void> {
  const override = viewportOverrides.get(targetId);
  if (!override) return;
  try {
    await session.call("Emulation.setDeviceMetricsOverride", {
      width: override.width,
      height: override.height,
      deviceScaleFactor: override.deviceScaleFactor,
      mobile: override.mobile,
    });
    await session.call("Emulation.setTouchEmulationEnabled", {
      enabled: override.mobile,
      maxTouchPoints: override.mobile ? 5 : 1,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Could not restore the ${override.width}x${override.height} viewport on tab ${targetId}: ${detail}. `
      + "Call browser_resize again, or browser_resize { reset: true } to drop the override.",
    );
  }
}

/** Read what the page actually got, which is the only number worth reporting. */
async function measureViewport(session: CDPSession, queries: string[] = []): Promise<JsonObject> {
  const expression = `(() => {
    const queries = ${JSON.stringify(queries)};
    return {
      width: window.innerWidth,
      height: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      documentWidth: document.documentElement.scrollWidth,
      documentHeight: document.documentElement.scrollHeight,
      ...(queries.length
        ? { matchMedia: Object.fromEntries(queries.map((query) => [query, window.matchMedia(query).matches])) }
        : {}),
    };
  })()`;
  return await evaluateValue(session, expression) as JsonObject;
}

/** Browser-scope CDP (window bounds, browser close) rather than a single page target. */
async function withBrowserSession<T>(work: (session: CDPSession) => Promise<T>): Promise<T> {
  await ensureChrome();
  const version = await fetchJson<{ webSocketDebuggerUrl?: string }>("/json/version");
  if (!version.webSocketDebuggerUrl) {
    throw new Error("Chrome did not expose a browser-level DevTools endpoint.");
  }
  const session = await CDPSession.connect(version.webSocketDebuggerUrl);
  try {
    return await work(session);
  } finally {
    session.close();
  }
}

/**
 * Drop a device-metrics override on a tab, including one left behind by a CDP
 * session that has already disconnected.
 *
 * An override belongs to the session that set it. A later session calling
 * clearDeviceMetricsOverride is accepted and silently does nothing, so Chrome keeps
 * serving the stale size forever once the owning socket is gone. Re-setting the
 * metrics first moves ownership to this session, which can then clear them for real.
 * Adopting the size already on screen makes the round trip invisible.
 */
async function clearViewportOverride(session: CDPSession): Promise<void> {
  const current = await measureViewport(session);
  await session.call("Emulation.setDeviceMetricsOverride", {
    width: Number(current.width) || DEFAULT_WINDOW_SIZE.width,
    height: Number(current.height) || DEFAULT_WINDOW_SIZE.height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await session.call("Emulation.clearDeviceMetricsOverride");
  // Touch emulation has the same session ownership rule, so take it the same way.
  await session.call("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 });
  await session.call("Emulation.setTouchEmulationEnabled", { enabled: false, maxTouchPoints: 1 });
}

/** Forget a tab's emulated viewport and put the real one back. */
async function dropViewportOverride(targetId: string): Promise<void> {
  viewportOverrides.delete(targetId);
  await withTarget(targetId, clearViewportOverride);
}

/**
 * Resize the real Chrome window hosting a tab.
 *
 * sizeIs="viewport" sizes the window so the *page* lands on the requested size:
 * window bounds carry the tab strip and omnibox, so the chrome inset is measured
 * live rather than hard-coded per Chrome version. sizeIs="bounds" sets the window
 * itself, which is what restoring the launch size means.
 *
 * Callers must drop any emulated viewport first. Emulation rewrites window.innerWidth,
 * which would both hide the new window size from the page and inflate the inset by
 * the difference between the emulated and real widths.
 */
async function resizeWindowForTab(
  targetId: string,
  size: { width: number; height: number },
  sizeIs: "viewport" | "bounds",
): Promise<JsonObject> {
  let inset = { width: 0, height: 0 };
  if (sizeIs === "viewport") {
    inset = await withTarget(targetId, async (session) => {
      const metrics = await evaluateValue(session, `({
        width: window.outerWidth - window.innerWidth,
        height: window.outerHeight - window.innerHeight,
      })`) as JsonObject;
      return { width: Number(metrics.width ?? 0) || 0, height: Number(metrics.height ?? 0) || 0 };
    });
  }
  const bounds = sizeIs === "viewport" ? windowBoundsFor(size, inset) : { ...size };
  await withBrowserSession(async (session) => {
    const window = await session.call("Browser.getWindowForTarget", { targetId });
    const windowId = window.windowId;
    const current = window.bounds as JsonObject | undefined;
    // Bounds are only writable from the normal window state.
    if (current?.windowState && current.windowState !== "normal") {
      await session.call("Browser.setWindowBounds", { windowId, bounds: { windowState: "normal" } });
    }
    await session.call("Browser.setWindowBounds", {
      windowId,
      bounds: { width: bounds.width, height: bounds.height },
    });
  });
  // The window manager applies asynchronously, and the page relayouts after it.
  await deadlineSleep(250);
  return { chromeInset: inset, windowBounds: bounds };
}

/** Let media queries settle and the page repaint before anything screenshots it. */
async function settleLayout(session: CDPSession): Promise<void> {
  try {
    await evaluateValue(session, `new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))`);
  } catch {
    // A page mid-navigation can drop the evaluation; the measurement below still reports truth.
  }
}

type PageReadiness = {
  readyState?: string;
  documentUrl?: string;
  title?: string;
  loaderId?: string;
  timedOut: boolean;
};

async function waitUntilReady(
  session: CDPSession,
  timeoutMs: number,
  expectedLoaderId?: string,
): Promise<PageReadiness> {
  const started = Date.now();
  let last: PageReadiness = { timedOut: true };
  while (true) {
    try {
      const frameTreeResult = await session.call("Page.getFrameTree");
      const result = await session.call("Runtime.evaluate", {
        expression: "({ readyState: document.readyState, documentUrl: location.href, title: document.title })",
        returnByValue: true,
      });
      const value = (result.result as JsonObject | undefined)?.value as JsonObject | undefined;
      const frameTree = frameTreeResult.frameTree as JsonObject | undefined;
      const frame = frameTree?.frame as JsonObject | undefined;
      last = {
        readyState: typeof value?.readyState === "string" ? value.readyState : undefined,
        documentUrl: typeof value?.documentUrl === "string" ? value.documentUrl : undefined,
        title: typeof value?.title === "string" ? value.title : undefined,
        loaderId: typeof frame?.loaderId === "string" ? frame.loaderId : undefined,
        timedOut: true,
      };
      if (navigationIsReady({
        ...last,
        expectedLoaderId,
        observedLoaderId: last.loaderId,
      })) return { ...last, timedOut: false };
    } catch {
      // Navigation may replace the execution context between polls.
    }
    if (Date.now() - started >= timeoutMs) return last;
    await deadlineSleep(Math.min(150, Math.max(1, timeoutMs - (Date.now() - started))));
  }
}

/**
 * Install the page-side console recorder on a tab, once. Failure is not fatal:
 * an older Chrome or a restricted page still gets the Log-domain half of
 * browser_console, and the result says which sources it actually has.
 */
async function installConsoleRecorder(session: CDPSession, targetId: string): Promise<boolean> {
  if (consoleRecorderTargets.has(targetId)) return true;
  try {
    await session.call("Page.addScriptToEvaluateOnNewDocument", { source: RECORDER_SOURCE });
    consoleRecorderTargets.add(targetId);
    return true;
  } catch {
    return false;
  }
}

type RecorderRead = {
  installed: boolean;
  fromDocumentStart: boolean;
  entries: ConsoleEntry[];
  url?: string;
};

/**
 * Read the in-page ring. If the recorder is absent -- the tab predates it, or it
 * could not be installed -- inject it now so the *next* call has history, and say
 * plainly that this call does not.
 */
async function readPageConsole(session: CDPSession, targetId: string, clear: boolean): Promise<RecorderRead> {
  let raw = await evaluateValue(session, readRecorderExpression(clear)) as JsonObject | undefined;
  if (raw?.installed !== true) {
    await installConsoleRecorder(session, targetId);
    try {
      // Seed the current document too, so a later read on this same page works.
      await evaluateValue(session, RECORDER_SOURCE);
      raw = await evaluateValue(session, readRecorderExpression(false)) as JsonObject | undefined;
    } catch {
      // A page mid-navigation can drop the evaluation.
    }
  }
  const entries = Array.isArray(raw?.entries) ? raw.entries as Record<string, unknown>[] : [];
  return {
    installed: raw?.installed === true,
    fromDocumentStart: raw?.fromDocumentStart === true,
    url: typeof raw?.url === "string" ? raw.url : undefined,
    entries: entries.map((entry) => toConsoleEntry(entry, "console")),
  };
}

/**
 * Collect what Chrome's Log domain has already stored. Enabling the domain
 * replays its buffer, which is where subresource 404s, blocked requests, and CSP
 * violations live -- the failures a page never told its own console about.
 */
async function readChromeLog(session: CDPSession): Promise<ConsoleEntry[]> {
  const collected: ConsoleEntry[] = [];
  const stopLog = session.on("Log.entryAdded", (params) => {
    const entry = params.entry as Record<string, unknown> | undefined;
    if (!entry) return;
    collected.push(toConsoleEntry({
      level: entry.level,
      source: entry.source,
      text: entry.text,
      at: typeof entry.timestamp === "number" ? entry.timestamp : undefined,
      url: entry.url,
    }, "chrome"));
  });
  const stopException = session.on("Runtime.exceptionThrown", (params) => {
    const details = params.exceptionDetails as Record<string, unknown> | undefined;
    if (!details) return;
    const thrown = details.exception as Record<string, unknown> | undefined;
    collected.push(toConsoleEntry({
      level: "error",
      source: "exception",
      text: thrown?.description ?? details.text,
      at: typeof params.timestamp === "number" ? params.timestamp : undefined,
      url: details.url,
    }, "exception"));
  });
  try {
    await session.call("Log.enable");
    await session.call("Runtime.enable");
    // The replay arrives as events, not as the enable response.
    await deadlineSleep(LOG_REPLAY_MS);
  } catch {
    // Neither domain is guaranteed; the page-side recorder still answers.
  } finally {
    stopLog();
    stopException();
  }
  return collected;
}

/** Everything both sources know about the current page, already merged. */
async function collectConsole(
  session: CDPSession,
  targetId: string,
  request: ConsoleRequest,
): Promise<{ entries: ConsoleEntry[]; all: ConsoleEntry[]; page: RecorderRead }> {
  const log = await readChromeLog(session);
  const page = await readPageConsole(session, targetId, request.clear);
  const all = mergeAndDedupe(page.entries, log);
  return { entries: selectEntries(all, request), all, page };
}

/**
 * Wait for the postcondition the caller named. Returns what actually happened, so
 * a click that did not navigate says so rather than looking the same as one that
 * did.
 */
async function settleInteraction(
  session: CDPSession,
  request: SettleRequest,
  label: string,
): Promise<JsonObject> {
  const detail: JsonObject = { requested: request.mode };

  switch (request.mode) {
    case "none":
      break;

    case "paint":
      await settleLayout(session);
      await deadlineSleep(250);
      break;

    case "navigation": {
      const before = await currentLoaderId(session);
      let navigated = false;
      const graceEnds = Date.now() + Math.min(NAVIGATION_GRACE_MS, Math.max(0, request.waitMs));
      // A click that navigates does so promptly. One that does not must not cost
      // the caller the whole deadline waiting to find that out.
      while (Date.now() < graceEnds) {
        const now = await currentLoaderId(session);
        if (now && now !== before) {
          navigated = true;
          break;
        }
        await deadlineSleep(100);
      }
      if (navigated) {
        const readiness = await waitUntilReady(session, remainingTimeout(request.waitMs));
        detail.readyState = readiness.readyState;
        detail.url = readiness.documentUrl;
        detail.timedOut = readiness.timedOut;
      } else {
        await settleLayout(session);
      }
      detail.navigated = navigated;
      break;
    }

    case "network-idle": {
      const tracker = new NetworkIdleTracker(Date.now());
      const stopStart = session.on("Network.requestWillBeSent", (params) => {
        if (typeof params.requestId === "string") tracker.started(params.requestId, Date.now());
      });
      const stopFinish = session.on("Network.loadingFinished", (params) => {
        if (typeof params.requestId === "string") tracker.settled(params.requestId, Date.now());
      });
      const stopFail = session.on("Network.loadingFailed", (params) => {
        if (typeof params.requestId === "string") tracker.settled(params.requestId, Date.now());
      });
      try {
        await session.call("Network.enable");
        while (!tracker.isIdle(Date.now())) {
          if (remainingTimeout(request.waitMs) <= POSTCONDITION_MARGIN_MS) {
            throw unsatisfiedNetworkIdleError(tracker.pending, request.waitMs, label);
          }
          await deadlineSleep(100);
        }
        detail.idle = true;
      } catch (error) {
        detail.idle = false;
        detail.pending = tracker.pending;
        if (error instanceof BrowserTimeoutError) throw unsatisfiedNetworkIdleError(tracker.pending, request.waitMs, label);
        throw error;
      } finally {
        stopStart();
        stopFinish();
        stopFail();
        detail.quietForMs = tracker.quietFor(Date.now());
        detail.quietThresholdMs = NETWORK_IDLE_QUIET_MS;
      }
      break;
    }
  }

  if (request.selector) {
    detail.waitForSelector = request.selector;
    detail.selectorState = request.selectorState;
    try {
      while (await evaluateValue(session, selectorStateExpression(request.selector, request.selectorState)) !== true) {
        // Answer before the outer deadline does, so the failure names the
        // postcondition instead of reading as a generic timeout.
        if (remainingTimeout(request.waitMs) <= POSTCONDITION_MARGIN_MS) {
          throw unsatisfiedSelectorError(request, label);
        }
        await deadlineSleep(100);
      }
    } catch (error) {
      if (error instanceof BrowserTimeoutError) throw unsatisfiedSelectorError(request, label);
      throw error;
    }
    detail.selectorSatisfied = true;
  }

  return detail;
}

async function currentLoaderId(session: CDPSession): Promise<string | undefined> {
  try {
    const frameTree = (await session.call("Page.getFrameTree")).frameTree as JsonObject | undefined;
    const frame = frameTree?.frame as JsonObject | undefined;
    return typeof frame?.loaderId === "string" ? frame.loaderId : undefined;
  } catch {
    // Navigation can replace the frame between polls; the next poll sees it.
    return undefined;
  }
}

async function evaluateValue(session: CDPSession, expression: string): Promise<unknown> {
  const response = await session.call("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  });
  const exception = response.exceptionDetails as JsonObject | undefined;
  if (exception) {
    throw new Error(String(exception.text ?? "Page evaluation failed."));
  }
  return (response.result as JsonObject | undefined)?.value;
}

function asString(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${label} is required.`);
  }
  return value.trim();
}

function stringValue(value: unknown, label: string): string {
  if (typeof value !== "string") {
    throw new Error(`${label} is required.`);
  }
  return value;
}

function optionalNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function textResult(data: JsonObject): ToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    structuredContent: data,
  };
}

function errorResult(data: JsonObject): ToolResult {
  return {
    isError: true,
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    structuredContent: data,
  };
}

/**
 * Tools that take a total deadline, and what it defaults to. A tool that can wait
 * on the page must be bounded, or an agent loop inherits the page's worst case.
 */
const TOTAL_DEADLINES: Record<string, number> = {
  browser_open: 15_000,
  browser_click: CLICK_WAIT_MS,
  browser_fill: FILL_WAIT_MS,
  browser_console: CONSOLE_WAIT_MS,
};

async function callTool(name: string, args: JsonObject): Promise<ToolResult> {
  const fallback = TOTAL_DEADLINES[name];
  if (fallback === undefined) return callToolImpl(name, args);
  const waitMs = parseWaitMs(args.waitMs, fallback, name);
  return withDeadline(waitMs, name, () => callToolImpl(name, args));
}

async function callToolImpl(name: string, args: JsonObject): Promise<ToolResult> {
  switch (name) {
    case "browser_profiles":
      return textResult({
        ok: true,
        profileRoot,
        current: { profile: profileName, profileDir, fixedProfileDir: Boolean(fixedProfileDir) },
        profiles: listActionProfilesOnDisk(),
        surfaces: BROWSER_SURFACES,
        policy: {
          default: "Action browser identities (named profiles under ChromeProfiles)",
          regularChrome: "open-only handoff via browser_open mode=regular; controlled with Action native screen + AX tools, never with CDP",
          cookies: "seed an identity with browser_import_cookies using domain allowlists",
          companion: "load packages/chrome-companion/dist unpacked once per identity",
        },
      });

    case "browser_use_profile": {
      const result = await useProfile(asString(args.profile, "profile"));
      return textResult({ ok: true, ...result });
    }

    case "browser_profile_info": {
      const defaultDir = existsSync(join(profileDir, "Cookies"))
        ? profileDir
        : join(profileDir, "Default");
      return textResult({
        ok: true,
        profile: profileName,
        profileDir,
        defaultDir,
        hasCookiesDb: existsSync(join(defaultDir, "Cookies")),
        debugPort,
        fixedProfileDir: Boolean(fixedProfileDir),
        companion: await companionStatus(),
      });
    }

    case "browser_companion_status":
      return textResult({ ok: true, ...(await companionStatus()) });

    case "browser_import_cookies": {
      const cookies = await loadCookieModule();
      if (args.listSourceProfiles === true) {
        return textResult({
          ok: true,
          sourceProfiles: cookies.listPersonalProfiles(),
          actionProfiles: listActionProfilesOnDisk(),
        });
      }
      const domains = Array.isArray(args.domains)
        ? args.domains.map((entry) => String(entry).trim()).filter(Boolean)
        : [];
      const only = Array.isArray(args.only)
        ? args.only.map((entry) => String(entry).trim()).filter(Boolean)
        : [];
      const selectors = cookies.parseCookieSelectors(only);
      if (!domains.length && !selectors.length) {
        throw new Error("browser_import_cookies requires domains and/or only.");
      }
      const into = typeof args.into === "string" && args.into.trim()
        ? sanitizeProfileName(args.into)
        : profileName;
      const source = typeof args.source === "string" && args.source.trim()
        ? args.source.trim()
        : undefined;
      const sourceProfilePath = cookies.resolveSourceProfileDir(source);
      const matches = cookies.listCookieEntries(sourceProfilePath, { domains, selectors });
      if (args.confirm !== true) {
        return textResult({
          ok: true,
          dryRun: true,
          into,
          sourceProfilePath,
          count: matches.length,
          cookies: matches.map((cookie) => `${cookie.hostKey}:${cookie.name}`),
          confirmRequired: true,
          hint: "Re-call with confirm=true to write these cookies into the Action profile.",
        });
      }
      if (into === profileName && ownsBrowser) {
        await releaseBrowser("cookie-import");
        currentTargetId = undefined;
      }
      const result = cookies.importCookiesToActionProfile({
        into,
        sourceProfile: source,
        domains,
        selectors,
      });
      return textResult({ ok: true, dryRun: false, ...result });
    }

    case "browser_open": {
      const inputUrl = asString(args.url, "url");
      const url = normalizeURL(inputUrl);
      const mode = browserOpenMode(args.mode);
      if (mode === "regular") {
        if (typeof args.profile === "string" && args.profile.trim()) {
          throw new Error("profile is only available in action mode; regular mode uses the user's normal Chrome profile.");
        }
        checkDeadline();
        const launch = Bun.spawn(regularChromeLaunchArgs(chromeAppName, url), {
          stdout: "ignore",
          stderr: "pipe",
        });
        const status = await boundedWait(launch.exited, "Launch Chrome", () => launch.kill());
        if (status !== 0) {
          const stderr = await boundedWait(new Response(launch.stderr).text(), "Read Chrome launch error");
          throw new Error(stderr.trim() || `Could not open ${chromeAppName}.`);
        }
        return textResult({
          ok: true,
          mode,
          ...(inputUrl === url ? {} : { inputUrl }),
          openedUrl: url,
          controlAvailable: false,
          handoff: true,
          chrome: {
            app: chromeAppName,
            profile: "system-selected",
            profileVerified: false,
            automated: false,
          },
          message: "Opened in the user's regular Chrome. Action Browser cannot inspect, click, fill, or screenshot this tab.",
          nativeControlPath: "Drive this window with Action's native macOS tools instead: action.observe.snapshot (screen + accessibility), action.resolve.target, action.act.execute.",
          domControlAlternative: "For DOM-level control of a signed-in session, seed an Action identity: browser_import_cookies { into: \"work\", source: \"Profile 1\", domains: [...], confirm: true } then browser_open { url, profile: \"work\" }.",
        });
      }
      if (typeof args.profile === "string" && args.profile.trim()) {
        await useProfile(args.profile);
      }
      const background = args.background !== false;
      const timeoutMs = Math.max(0, optionalNumber(args.waitMs, 15_000));
      await ensureChrome(background);
      let target: ChromeTarget | undefined;
      let reusedTab = false;
      if (shouldReuseCurrentTab({
        currentTargetId,
        newTab: args.newTab === true,
      })) {
        target = (await listTargets()).find((candidate) => candidate.id === currentTargetId);
        reusedTab = Boolean(target);
      }
      if (!target) {
        target = await fetchJson<ChromeTarget>("/json/new?about%3Ablank", { method: "PUT" });
        if (!target.webSocketDebuggerUrl) {
          throw new Error("Chrome created a tab without a DevTools endpoint.");
        }
      }
      if (!target.webSocketDebuggerUrl) throw new Error("Chrome tab has no DevTools endpoint.");
      currentTargetId = target.id;
      const session = await CDPSession.connect(target.webSocketDebuggerUrl);
      try {
        await session.call("Page.enable");
        // Install the console recorder before navigating, so it is in place before
        // the new document parses and browser_console can answer for the whole page
        // rather than from whenever it was first asked.
        await installConsoleRecorder(session, target.id);
        // Restore a sticky viewport before navigating so the first layout, and any
        // breakpoint-sensitive script the page runs on load, sees the right width.
        await applyViewportOverride(session, target.id);
        const navigation = await session.call("Page.navigate", { url });
        const navigateErrorText = typeof navigation.errorText === "string"
          ? navigation.errorText
          : undefined;
        const loaderId = typeof navigation.loaderId === "string" ? navigation.loaderId : undefined;
        const readiness = await waitUntilReady(
          session,
          navigateErrorText ? Math.min(timeoutMs, 1_500) : timeoutMs,
          loaderId,
        );
        let page: JsonObject = {};
        try {
          page = await evaluateValue(
            session,
            "({ title: document.title, documentUrl: location.href, readyState: document.readyState, pageText: (document.body?.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 1000) })",
          ) as JsonObject;
        } catch {
          // The target metadata and readiness observation still provide a useful failure contract.
        }
        let observedTarget: ChromeTarget | undefined;
        try {
          observedTarget = (await fetchJson<ChromeTarget[]>("/json/list"))
            .find((candidate) => candidate.id === target.id);
        } catch {
          // Chrome can briefly withhold target metadata while replacing an error document.
        }
        const outcome = assessNavigation({
          requestedUrl: url,
          documentUrl: typeof page.documentUrl === "string"
            ? page.documentUrl
            : readiness.documentUrl,
          targetUrl: observedTarget?.url ?? target.url,
          title: typeof page.title === "string" ? page.title : readiness.title,
          readyState: typeof page.readyState === "string" ? page.readyState : readiness.readyState,
          timedOut: readiness.timedOut,
          timeoutMs,
          navigateErrorText,
          pageText: typeof page.pageText === "string" ? page.pageText : undefined,
        });
        const result: JsonObject = {
          ...outcome,
          mode,
          ...(inputUrl === url ? {} : { inputUrl }),
          reusedTab,
          tab: {
            id: target.id,
            title: page.title ?? readiness.title ?? observedTarget?.title ?? target.title,
            url: outcome.finalUrl,
          },
          chrome: {
            profile: profileName,
            profileDir,
            background,
            debugPort,
            session: sessionName,
          },
        };
        return outcome.ok ? textResult(result) : errorResult(result);
      } finally {
        session.close();
      }
    }

    case "browser_tabs": {
      const tabs = (await listTargets()).map(({ id, title, url }) => ({
        id,
        title,
        url,
        current: id === currentTargetId,
      }));
      return textResult({ ok: true, tabs });
    }

    case "browser_snapshot":
      return await withTarget(args.tabId, async (session, target) => {
        const maxTextChars = Math.max(500, optionalNumber(args.maxTextChars, 12_000));
        const maxElements = Math.max(1, optionalNumber(args.maxElements, 80));
        const expression = `(() => {
          const visible = (element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
          };
          const selector = (element) => {
            if (element.id) return "#" + CSS.escape(element.id);
            const testId = element.getAttribute("data-testid");
            if (testId) return '[data-testid="' + CSS.escape(testId) + '"]';
            const name = element.getAttribute("name");
            if (name) return element.tagName.toLowerCase() + '[name="' + CSS.escape(name) + '"]';
            const role = element.getAttribute("role");
            if (role) return element.tagName.toLowerCase() + '[role="' + CSS.escape(role) + '"]';
            return element.tagName.toLowerCase();
          };
          const nodes = [...document.querySelectorAll('a[href],button,input,select,textarea,[role],[contenteditable="true"],[tabindex]')]
            .filter(visible)
            .slice(0, ${maxElements})
            .map((element) => {
              const rect = element.getBoundingClientRect();
              const isPassword = element instanceof HTMLInputElement && element.type === "password";
              return {
                selector: selector(element),
                tag: element.tagName.toLowerCase(),
                role: element.getAttribute("role"),
                label: element.getAttribute("aria-label") || element.getAttribute("placeholder") || element.innerText?.trim() || element.getAttribute("name"),
                value: isPassword ? null : ("value" in element ? String(element.value).slice(0, 500) : null),
                rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
              };
            });
          return {
            title: document.title,
            url: location.href,
            text: (document.body?.innerText || "").replace(/\\s+/g, " ").trim().slice(0, ${maxTextChars}),
            elements: nodes
          };
        })()`;
        const snapshot = await evaluateValue(session, expression) as JsonObject;
        // "Did this page work?" should be answerable on the call an agent already
        // makes, not only by asking a second time. The full list stays behind
        // browser_console; this is the count plus the errors themselves.
        const page = await readPageConsole(session, target.id, false).catch(() => undefined);
        const entries = page ? dedupeEntries(page.entries) : [];
        const summary = page ? summarize(entries) : undefined;
        const errors = entries.filter((entry) => entry.level === "error").slice(-5);
        return textResult({
          ok: true,
          tabId: target.id,
          ...snapshot,
          ...(summary
            ? {
              console: {
                ...summary,
                // Page-side only. Chrome's own log -- failed subresources, CSP
                // refusals -- is a second round trip, so browser_console can
                // legitimately report more errors than this block does.
                source: "page",
                // `errors` is the count from the summary; these are the entries.
                ...(errors.length > 0
                  ? { recentErrors: errors, note: "Counts what the page itself logged; browser_console also reads Chrome's log." }
                  : {}),
                ...(page && !page.fromDocumentStart
                  ? { partial: true, partialNote: "Recording started after this document did; call browser_console after a browser_open for complete history." }
                  : {}),
              },
            }
            : {}),
        });
      });

    case "browser_click": {
      const settle = parseSettleRequest(args, {
        defaultMode: "paint",
        defaultWaitMs: CLICK_WAIT_MS,
        label: "browser_click",
      });
      return await withTarget(args.tabId, async (session, target) => {
        const selector = typeof args.selector === "string" ? args.selector : undefined;
        const text = typeof args.text === "string" ? args.text : undefined;
        if (!selector && !text) throw new Error("browser_click requires selector or text.");
        const expression = `(() => {
          const selector = ${JSON.stringify(selector)};
          const text = ${JSON.stringify(text?.trim().toLowerCase())};
          const candidates = [...document.querySelectorAll('a[href],button,input,[role="button"],[role="link"],[tabindex]')];
          const element = selector
            ? document.querySelector(selector)
            : candidates.find((candidate) => (candidate.innerText || candidate.textContent || candidate.getAttribute("aria-label") || "").trim().toLowerCase().includes(text));
          if (!(element instanceof HTMLElement)) throw new Error("No clickable element matched.");
          element.scrollIntoView({ block: "center", inline: "center" });
          element.click();
          return { selector: selector || element.tagName.toLowerCase(), text: (element.innerText || element.textContent || "").trim().slice(0, 300) };
        })()`;
        const result = await evaluateValue(session, expression) as JsonObject;
        const settled = await settleInteraction(session, settle, "browser_click");
        return textResult({ ok: true, tabId: target.id, result, settle: settled });
      });
    }

    case "browser_fill": {
      const settle = parseSettleRequest(args, {
        defaultMode: "none",
        defaultWaitMs: FILL_WAIT_MS,
        label: "browser_fill",
      });
      return await withTarget(args.tabId, async (session, target) => {
        const selector = asString(args.selector, "selector");
        const value = stringValue(args.value, "value");
        const expression = `(() => {
          const element = document.querySelector(${JSON.stringify(selector)});
          if (!(element instanceof HTMLElement)) throw new Error("No field matched the selector.");
          if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
            const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), "value")?.set;
            setter ? setter.call(element, ${JSON.stringify(value)}) : element.value = ${JSON.stringify(value)};
          } else if (element.isContentEditable) {
            element.textContent = ${JSON.stringify(value)};
          } else {
            throw new Error("Matched element is not editable.");
          }
          element.focus();
          element.dispatchEvent(new InputEvent("input", { bubbles: true, data: ${JSON.stringify(value)}, inputType: "insertText" }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
          return { selector: ${JSON.stringify(selector)}, valueLength: ${value.length} };
        })()`;
        const result = await evaluateValue(session, expression) as JsonObject;
        const settled = await settleInteraction(session, settle, "browser_fill");
        return textResult({ ok: true, tabId: target.id, result, settle: settled });
      });
    }

    case "browser_console": {
      const request = parseConsoleRequest(args);
      return await withTarget(args.tabId, async (session, target) => {
        await session.call("Page.enable");
        const { entries, all, page } = await collectConsole(session, target.id, request);
        const summary = summarize(all);
        return textResult({
          ok: true,
          tabId: target.id,
          url: page.url ?? target.url,
          title: target.title,
          ...summary,
          // Say how much history this answer actually covers, so "no errors" is
          // never mistaken for "no errors were recorded".
          coverage: page.installed
            ? (page.fromDocumentStart ? "document-start" : "partial")
            : "chrome-log-only",
          coverageNote: page.installed
            ? (page.fromDocumentStart
              ? "The page recorder was in place before this document parsed; this is its full history."
              : "The page recorder was installed after this document started, so earlier console calls are missing. Reload with browser_open to get complete history.")
            : "Only Chrome's own log was available for this tab. Reload with browser_open to record the page's console from the start.",
          levels: request.levels,
          entries,
          ...(request.clear ? { cleared: true } : {}),
        });
      });
    }


    case "browser_resize": {
      const request = parseResizeRequest(args);
      const target = await targetFor(args.tabId);
      const hadEmulatedViewport = viewportOverrides.has(target.id);

      let windowDetail: JsonObject = {};
      // Only a caller-named viewport size can be checked for drift. A reset asks for
      // "whatever the window is", so there is nothing to have missed.
      let requestedViewport: { width: number; height: number } | undefined;

      if (request.kind === "set" && request.target === "tab") {
        viewportOverrides.set(target.id, request.viewport);
        requestedViewport = { width: request.viewport.width, height: request.viewport.height };
      } else if (request.kind === "set") {
        // The window path owns the tab's size outright: an emulated viewport would
        // mask the resize the caller asked to see.
        await dropViewportOverride(target.id);
        requestedViewport = { width: request.viewport.width, height: request.viewport.height };
        windowDetail = await resizeWindowForTab(target.id, requestedViewport, "viewport");
      } else if (request.target === "window") {
        await dropViewportOverride(target.id);
        windowDetail = await resizeWindowForTab(target.id, DEFAULT_WINDOW_SIZE, "bounds");
      } else {
        await dropViewportOverride(target.id);
      }

      const measured = await withTarget(target.id, async (session) => {
        await settleLayout(session);
        return await measureViewport(session, request.matchMedia);
      });
      const drift = requestedViewport
        ? measureDrift(requestedViewport, {
          width: Number(measured.width ?? 0),
          height: Number(measured.height ?? 0),
        })
        : undefined;

      const result: JsonObject = {
        ok: true,
        target: request.target,
        tabId: target.id,
        url: target.url,
        reset: request.kind === "reset",
        requested: request.kind === "set"
          ? { ...request.viewport }
          : {
            restoredTo: request.target === "window"
              ? `the default ${DEFAULT_WINDOW_SIZE.width}x${DEFAULT_WINDOW_SIZE.height} window`
              : "the real window viewport",
          },
        viewport: measured,
        ...(drift ?? {}),
        widthClass: widthClass(Number(measured.width ?? 0)),
        emulated: viewportOverrides.has(target.id),
        ...(request.target === "window" && hadEmulatedViewport
          ? { clearedEmulatedViewport: true }
          : {}),
        ...windowDetail,
      };
      if (drift && !drift.exact) {
        result.note = request.target === "window"
          ? "The window manager did not grant the exact size; a window cannot exceed its display. Use target=tab for an exact viewport."
          : "The page did not lay out at the requested size. A hard min-width or a zoom level can hold it wider.";
      }
      return textResult(result);
    }

    case "browser_screenshot": {
      const request = parseCaptureRequest(args);
      return await withTarget(args.tabId, async (session, target) => {
        await session.call("Page.enable");
        const fullPage = request.kind === "fullPage";
        // Every clip goes out at scale 1, so a captured pixel is a CSS pixel times
        // the device scale factor and nothing else. Rescaling is what makes a
        // screenshot stop being evidence.
        let captureParams: JsonObject = {
          format: "png",
          fromSurface: true,
          captureBeyondViewport: request.kind !== "viewport",
        };
        let area: JsonObject = { kind: request.kind };
        let clip: CaptureRect | undefined;

        if (fullPage) {
          const metrics = await session.call("Page.getLayoutMetrics");
          const contentSize = metrics.cssContentSize as JsonObject | undefined
            ?? metrics.contentSize as JsonObject | undefined;
          if (contentSize) {
            const width = Number(contentSize.width ?? 1440);
            const height = Number(contentSize.height ?? 1000);
            clip = {
              x: 0,
              y: 0,
              width: Math.min(width, MAX_CAPTURE_EDGE),
              height: Math.min(height, MAX_CAPTURE_EDGE),
            };
            area = {
              kind: "fullPage",
              documentSize: { width, height },
              ...(width > MAX_CAPTURE_EDGE || height > MAX_CAPTURE_EDGE
                ? {
                  truncated: true,
                  truncatedNote: `The document exceeds Chrome's ${MAX_CAPTURE_EDGE}px capture limit, so this frame is cut off rather than scaled down. Capture the part you need with selector or clip.`,
                }
                : { truncated: false }),
            };
          }
        } else if (request.kind === "element") {
          await settleLayout(session);
          const measured = await evaluateValue(session, measureElementExpression(request.selector)) as JsonObject | undefined;
          if (measured?.found !== true) {
            throw new Error(`No element matched ${request.selector}. Call browser_snapshot for the selectors this page actually offers.`);
          }
          const width = Number(measured.width ?? 0);
          const height = Number(measured.height ?? 0);
          if (!(width > 0) || !(height > 0)) {
            throw new Error(
              `${request.selector} matched an element with no rendered size (${width}x${height}). `
              + "It may be hidden, collapsed, or not laid out yet.",
            );
          }
          const outcome = clipForRect(
            { x: Number(measured.x ?? 0), y: Number(measured.y ?? 0), width, height },
            request.padding,
            { width: Number(measured.documentWidth ?? 0), height: Number(measured.documentHeight ?? 0) },
          );
          clip = outcome.clip;
          area = {
            kind: "element",
            selector: request.selector,
            tag: measured.tag,
            padding: request.padding,
            element: { x: measured.x, y: measured.y, width, height },
            clamped: outcome.clamped,
            truncated: outcome.truncated,
          };
        } else if (request.kind === "clip") {
          clip = request.clip;
          area = { kind: "clip", requested: request.clip };
        }

        if (clip) {
          captureParams = { ...captureParams, clip: { ...clip, scale: 1 } };
        }
        const capture = await session.call("Page.captureScreenshot", captureParams);
        const data = asString(capture.data, "screenshot data");
        const requestedPath = typeof args.outputPath === "string" ? args.outputPath : undefined;
        if (requestedPath && !isAbsolute(requestedPath)) {
          throw new Error("outputPath must be absolute when provided.");
        }
        const outputPath = requestedPath
          ? resolve(requestedPath)
          : join(artifactRoot, `browser-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
        await mkdir(dirname(outputPath), { recursive: true });
        await Bun.write(outputPath, Buffer.from(data, "base64"));
        const viewport = await measureViewport(session).catch(() => undefined) as JsonObject | undefined;
        const metadata: JsonObject = {
          ok: true,
          tabId: target.id,
          title: target.title,
          url: target.url,
          outputPath,
          fullPage,
          mimeType: "image/png",
          area,
          ...(clip ? { clip } : {}),
          // State the scale rather than leaving it to be assumed. At scale 1 a
          // captured pixel is a CSS pixel times the device scale factor, so a
          // measurement taken off this PNG is a measurement of the page.
          scale: 1,
          deviceScaleFactor: viewport?.devicePixelRatio ?? 1,
          // Say which viewport this frame is evidence of, so a breakpoint screenshot
          // is self-describing rather than a size the reader has to remember.
          viewport,
          emulated: viewportOverrides.has(target.id),
        };
        return {
          content: [
            { type: "text", text: JSON.stringify(metadata, null, 2) },
            ...(args.includeImage === false ? [] : [{ type: "image" as const, data, mimeType: "image/png" as const }]),
          ],
          structuredContent: metadata,
        };
      });
    }

    case "browser_close": {
      if (args.scope === "browser") {
        const outcome = await releaseBrowser("browser_close");
        currentTargetId = undefined;
        viewportOverrides.clear();
        return textResult({
          ok: true,
          scope: "browser",
          session: sessionName,
          closed: outcome.closed,
          liveOwners: outcome.liveOwners,
        });
      }
      const target = await targetFor(args.tabId);
      const response = await boundedWait(fetch(`${chromeBaseURL}/json/close/${encodeURIComponent(target.id)}`, { signal: AbortSignal.timeout(10_000) }), "Close Chrome tab");
      if (!response.ok) {
        throw new Error(`Chrome could not close tab ${target.id}.`);
      }
      viewportOverrides.delete(target.id);
      if (currentTargetId === target.id) currentTargetId = undefined;
      return textResult({ ok: true, closed: target.id });
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

/**
 * The browser toolset, as the lattices MCP router consumes it. The router owns
 * the JSON-RPC framing; everything below the framing -- Chrome ownership, the
 * claim registry, the idle timer -- stays here, unchanged from when this server
 * spoke the protocol itself.
 */
export const browserToolset = {
  name: "browser",
  title: "Action Browser",
  tools,
  instructions: [
    "Action Browser drives Action-owned Chrome identities, never the user's regular Chrome.",
    "Three browsers exist. (1) The user's regular Chrome: browser_open mode=regular opens a URL there and nothing else; control it with Action's native screen + accessibility tools (action.observe.* then action.act.execute). (2) An Action browser: the default agent-browser identity, blank and isolated, with full DOM tools. (3) An Action browser identity seeded from a regular Chrome profile: same DOM tools, already signed in.",
    "To act on a signed-in site, seed rather than hand off: browser_import_cookies { into: \"work\", source: \"Profile 1\", domains: [\"github.com\"] } to preview, again with confirm: true to write, then browser_open { url, profile: \"work\" }.",
    "Fast path for anything public: browser_open \u2192 browser_screenshot.",
    "Responsive checks: browser_open \u2192 browser_resize { width, height } \u2192 browser_screenshot. The size sticks to that tab until browser_resize { reset: true }.",
    "Reviewing one component: browser_screenshot { selector } captures just that element at scale 1, so no cropping and no rescaling. Add padding for breathing room.",
    "Interactions can be awaited instead of guessed at: browser_click { selector, waitForSelector } fails if the expected result never appears, and settle: \"navigation\" or \"network-idle\" waits for the page the click produced.",
    "A blank or wrong-looking page: browser_console before another screenshot. It carries console calls, uncaught errors, and Chrome's own log of failed subresources.",
    "browser_profiles lists identities and surfaces; browser_companion_status reports the extension bridge.",
  ],

  /**
   * Startup work, run once before the first request is served. The orphan sweep
   * is load-bearing: it is what closes a Chrome whose owning session died
   * without releasing its claim.
   */
  async init(): Promise<void> {
    await sweepOrphans();
  },

  /**
   * Called before each of *this* toolset's tool calls. Scoped that way on
   * purpose: a call into some other toolset is not browser activity and must not
   * postpone the idle close.
   */
  onToolCall(): void {
    scheduleIdleRelease();
  },

  callTool,

  /** Release Chrome on router shutdown, within this toolset's own budget. */
  async shutdown(reason: string): Promise<void> {
    await shutdownBrowser(reason);
  },

  /** Synchronous last resort, for the router's `exit` handler. */
  shutdownSync: shutdownBrowserSync,
};

export type BrowserToolset = typeof browserToolset;
