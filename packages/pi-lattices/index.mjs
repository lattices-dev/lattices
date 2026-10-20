import { daemonCall, daemonConfig, isDaemonUnavailable } from "./daemon-client.mjs";

const TOOL_PREFIX = "lattices_";
const DEFAULT_SOURCE = "pi-lattices";

const string = (description) => ({ type: "string", description });
const boolean = (description) => ({ type: "boolean", description });
const number = (description) => ({ type: "number", description });
const integer = (description) => ({ type: "integer", minimum: 1, description });
const nonNegativeInteger = (description) => ({ type: "integer", minimum: 0, description });
const optionalEnum = (values, description) => ({ type: "string", enum: values, description });
const object = (properties = {}, required = []) => ({
  type: "object",
  additionalProperties: false,
  properties,
  ...(required.length > 0 ? { required } : {}),
});

const treatment = optionalEnum(
  ["observe", "stage", "present", "execute"],
  "Lattices computer-use treatment. Pi tools default to stage where that avoids mutation."
);

const source = string("Calling surface label recorded in Lattices runs/traces. Defaults to pi-lattices.");
const dryRun = boolean("Legacy alias for treatment=stage where supported by the daemon.");
const capture = boolean("Whether Lattices should capture before/after artifacts when supported.");
const wid = integer("CGWindowID / kCGWindowNumber.");
const session = string("Lattices tmux/session name, such as myapp-a1b2c3.");
const app = string("macOS application name, such as Finder, Notes, Terminal, iTerm2, or Scout.");
const title = string("Optional window title substring for target selection.");
const path = string("Filesystem path.");
const artifactId = string("Run artifact id.");
const x = number("Absolute screen X coordinate.");
const y = number("Absolute screen Y coordinate.");
const ratio = (description) => ({ type: "number", minimum: 0, maximum: 1, description });
const text = string("Text payload. Pass treatment=execute to actually insert it.");
const instruction = string("Explicit analysis instruction or verification question.");
const allowAutomation = boolean("Must be true for browser JavaScript automation.");
const selector = string("CSS selector.");
const script = string("JavaScript source.");
const windowStateMode = optionalEnum(
  ["ax", "both", "screenshot"],
  "Snapshot mode. ax avoids Screen Recording; both includes AX plus screenshot capture; screenshot skips AX."
);
const elementAction = optionalEnum(
  ["press", "showMenu", "focus"],
  "Element action. press is the default and maps to AXPress."
);
const key = string("Keyboard key name, such as escape, enter, tab, left, right, or a single character.");
const modifiers = {
  anyOf: [
    { type: "array", items: { type: "string" } },
    { type: "string" },
  ],
  description: "Keyboard modifiers: command, option, control, shift. Array or +/comma/space-delimited string.",
};
const shortcut = string("Shortcut shorthand, such as command+shift+p, cmd+k, or shift+tab.");
const allowGlobal = boolean("Allow treatment=execute without an explicit target by posting to the focused system target.");
const pointerCount = integer("Repeat count for pointer events.");
const delayMs = number("Delay between repeated events in milliseconds.");
const durationMs = number("Pointer action duration in milliseconds.");

const emptyParams = object();
const runSourceParams = {
  source,
};
const targetParams = {
  wid,
  session,
  app,
  title,
};
const windowPointParams = {
  x,
  y,
  xRatio: ratio("Window-relative X ratio, where 0 is the left edge and 1 is the right edge."),
  yRatio: ratio("Window-relative Y ratio, where 0 is the top edge and 1 is the bottom edge."),
};
const computerBaseParams = {
  treatment,
  dryRun,
  capture,
  source,
};

export const LATTICES_TOOLS = [
  {
    name: `${TOOL_PREFIX}status`,
    method: "daemon.status",
    description: "Return Lattices daemon health, uptime, tracked windows, and tmux session counts.",
    parameters: emptyParams,
  },
  {
    name: `${TOOL_PREFIX}api_schema`,
    method: "api.schema",
    description: "Return the live Lattices daemon API schema for self-discovery.",
    parameters: emptyParams,
  },
  {
    name: `${TOOL_PREFIX}windows_list`,
    method: "windows.list",
    description: "List visible windows tracked by Lattices, including app/title/frame/session metadata.",
    parameters: emptyParams,
  },
  {
    name: `${TOOL_PREFIX}windows_search`,
    method: "windows.search",
    description: "Search windows by title, app, Lattices session tag, and optionally OCR text.",
    parameters: object({
      query: string("Search query."),
      ocr: boolean("Include OCR text in search. Defaults to true in the daemon."),
      limit: integer("Maximum results to return."),
    }, ["query"]),
  },
  {
    name: `${TOOL_PREFIX}window_get`,
    method: "windows.get",
    description: "Get one tracked window by CGWindowID.",
    parameters: object({ wid }, ["wid"]),
  },
  {
    name: `${TOOL_PREFIX}runs_list`,
    method: "runs.list",
    description: "List recent Lattices runs from the local run store.",
    parameters: object({
      limit: integer("Maximum runs to return. Daemon default is 20."),
    }),
  },
  {
    name: `${TOOL_PREFIX}runs_get`,
    method: "runs.get",
    description: "Inspect one Lattices run, including artifacts and trace events.",
    parameters: object({
      id: string("Run id, such as run_20260617-120000_a1b2c3."),
    }, ["id"]),
  },
  {
    name: `${TOOL_PREFIX}ocr_snapshot`,
    method: "ocr.snapshot",
    description: "Return current in-memory OCR results for visible windows.",
    parameters: emptyParams,
  },
  {
    name: `${TOOL_PREFIX}ocr_search`,
    method: "ocr.search",
    description: "Search Lattices OCR history or the live OCR snapshot.",
    parameters: object({
      query: string("FTS5 search query."),
      app: string("Optional application-name filter."),
      limit: integer("Maximum results to return. Daemon default is 50."),
      live: boolean("Search the live OCR snapshot instead of history."),
    }, ["query"]),
  },
  {
    name: `${TOOL_PREFIX}computer_window_state`,
    method: "computer.windowState",
    description: "Inspect a target window's Accessibility tree and return snapshot-local element ids for semantic computer use.",
    parameters: object({
      ...targetParams,
      mode: windowStateMode,
      capture: boolean("Capture a screenshot artifact. Defaults true for both/screenshot and false for ax."),
      maxDepth: integer("Maximum AX tree depth to traverse. Daemon default is 8."),
      maxElements: integer("Maximum elements to return. Daemon default is 250."),
      timeoutMs: integer("Traversal timeout in milliseconds. Daemon default is 1200."),
      source,
    }),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}window_focus`,
    method: "computer.focusWindow",
    description: "Resolve and focus/present a target window through Lattices computer-use runs. Defaults to treatment=stage; pass present or execute to focus.",
    parameters: object({
      ...targetParams,
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_element_action`,
    method: "computer.elementAction",
    description: "Stage or execute an Accessibility action against an element id from lattices_computer_window_state.",
    parameters: object({
      snapshotId: string("Snapshot id returned by lattices_computer_window_state."),
      elementId: string("Snapshot-local element id, such as e4."),
      action: elementAction,
      ...computerBaseParams,
    }, ["snapshotId", "elementId"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_type_element`,
    method: "computer.typeElement",
    description: "Stage or execute AXValue text insertion against an element id from lattices_computer_window_state.",
    parameters: object({
      snapshotId: string("Snapshot id returned by lattices_computer_window_state."),
      elementId: string("Snapshot-local element id, such as e4."),
      text,
      append: boolean("Append to current AXValue instead of replacing it."),
      typeIntervalMs: number("Optional per-character interval for typewriter-style AXValue updates."),
      ...computerBaseParams,
    }, ["snapshotId", "elementId", "text"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_set_value`,
    method: "computer.setValue",
    description: "Stage or execute AXValue replacement against an element id from lattices_computer_window_state.",
    parameters: object({
      snapshotId: string("Snapshot id returned by lattices_computer_window_state."),
      elementId: string("Snapshot-local element id, such as e4."),
      value: string("Value to set on AXValue."),
      append: boolean("Append to current AXValue instead of replacing it."),
      typeIntervalMs: number("Optional per-character interval for typewriter-style AXValue updates."),
      ...computerBaseParams,
    }, ["snapshotId", "elementId", "value"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_press_key`,
    method: "computer.pressKey",
    description: "Stage or execute one keyboard key press against an explicit target window. Defaults to treatment=stage; pass execute to press.",
    parameters: object({
      ...targetParams,
      key,
      modifiers,
      count: integer("Number of times to press the key. Daemon default is 1, max 20."),
      delayMs: number("Delay between repeated presses in milliseconds. Daemon default is 80."),
      allowGlobal,
      ...computerBaseParams,
    }, ["key"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_hotkey`,
    method: "computer.hotkey",
    description: "Stage or execute a keyboard shortcut against an explicit target window. Defaults to treatment=stage; pass execute to send.",
    parameters: {
      ...object({
        ...targetParams,
        shortcut,
        key,
        modifiers,
        count: integer("Number of times to send the shortcut. Daemon default is 1, max 20."),
        delayMs: number("Delay between repeated sends in milliseconds. Daemon default is 80."),
        allowGlobal,
        ...computerBaseParams,
      }),
      anyOf: [
        { required: ["shortcut"] },
        { required: ["key"] },
      ],
    },
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}window_place`,
    method: "windows.place",
    description: "Place a target window/session using Lattices' typed placement runtime and return the action receipt.",
    parameters: object({
      ...targetParams,
      display: nonNegativeInteger("Zero-based target display index."),
      placement: {
        description: "Placement shorthand (left, right, maximize, grid:3x2:0,0, etc.) or typed placement object.",
        anyOf: [
          { type: "string" },
          { type: "object", additionalProperties: true },
        ],
      },
    }, ["placement"]),
  },
  {
    name: `${TOOL_PREFIX}capture_window`,
    method: "capture.screenshotWindow",
    description: "Capture a target window as a Lattices run artifact. Defaults to frontmost non-Lattices window if no target is provided.",
    parameters: object({
      ...targetParams,
      runId: string("Existing run id to append to."),
      filename: string("Optional artifact filename."),
      ...runSourceParams,
    }),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}capture_region`,
    method: "capture.screenshotRegion",
    description: "Capture a screen region as a PNG run artifact. Falls back to the target window frame if x/y/width/height are omitted.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      width: number("Region width in screen coordinates."),
      height: number("Region height in screen coordinates."),
      w: number("Alias for width."),
      h: number("Alias for height."),
      runId: string("Existing run id to append to."),
      filename: string("Optional artifact filename."),
      ...runSourceParams,
    }),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}capture_zoom_artifact`,
    method: "capture.zoomArtifact",
    description: "Crop and zoom an image artifact into a new PNG artifact linked to the same run.",
    parameters: object({
      runId: string("Run id containing the source artifact."),
      artifactId,
      path,
      x: number("Crop x in image pixels."),
      y: number("Crop y in image pixels."),
      width: number("Crop width in image pixels."),
      height: number("Crop height in image pixels."),
      xRatio: ratio("Crop x ratio within source image."),
      yRatio: ratio("Crop y ratio within source image."),
      widthRatio: ratio("Crop width ratio within source image."),
      heightRatio: ratio("Crop height ratio within source image."),
      scale: number("Zoom scale. Daemon default is 2, max 8."),
      filename: string("Optional artifact filename."),
      ...runSourceParams,
    }),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}vision_analyze_window`,
    method: "vision.analyzeWindow",
    description: "Capture a window and run local OCR-based visual analysis with an explicit instruction.",
    parameters: object({
      ...targetParams,
      instruction,
      contains: string("Optional text that should be present."),
      notContains: string("Optional text that should be absent."),
      ...runSourceParams,
    }, ["instruction"]),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}vision_analyze_artifact`,
    method: "vision.analyzeArtifact",
    description: "Run local OCR-based visual analysis against an existing image artifact or path.",
    parameters: object({
      runId: string("Run id containing the source artifact."),
      artifactId,
      path,
      instruction,
      contains: string("Optional text that should be present."),
      notContains: string("Optional text that should be absent."),
      ...runSourceParams,
    }, ["instruction"]),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_prepare`,
    method: "computer.prepare",
    description: "Resolve and stage/observe a safe terminal target for later computer-use actions without typing by default.",
    parameters: object({
      wid,
      tty: string("Specific terminal TTY."),
      app: string("Preferred terminal app, such as Terminal or iTerm2."),
      text: string("Optional text to stage in the run trace."),
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_launch_app`,
    method: "computer.launchApp",
    description: "Launch or focus a normal macOS app through a Lattices run. Defaults to treatment=stage; pass present or execute to launch/focus.",
    parameters: object({
      app,
      bundleId: string("Bundle identifier fallback for precise launch."),
      path: string("Explicit .app bundle path."),
      title,
      ...computerBaseParams,
    }, ["app"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_click`,
    method: "computer.click",
    description: "Stage, present, or execute a window-relative click. Defaults to treatment=stage; pass execute to click.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      button: optionalEnum(["left", "right", "secondary", "context"], "Mouse button. Defaults to left."),
      count: pointerCount,
      delayMs,
      transport: optionalEnum(["auto", "ax", "accessibility", "pointer", "mouse", "hardware"], "Click transport. auto prefers AXPress when possible."),
      axLabel: string("Optional AX title/label hint, such as Send."),
      targetText: string("Optional visible target text hint."),
      noFocus: boolean("Require no-focus AX execution and disable pointer fallback."),
      label: string("Optional label recorded with the click/cursor target."),
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_double_click`,
    method: "computer.doubleClick",
    description: "Stage, present, or execute a window-relative double-click. Defaults to treatment=stage; pass execute to double-click.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      delayMs: number("Delay between the two clicks in milliseconds. Daemon default is 90."),
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_right_click`,
    method: "computer.rightClick",
    description: "Stage, present, or execute a window-relative right-click/context-click. Defaults to treatment=stage; pass execute to right-click.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      count: pointerCount,
      delayMs,
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_scroll`,
    method: "computer.scroll",
    description: "Stage, present, or execute scroll wheel input at a cursor or window-relative point. Defaults to treatment=stage; pass execute to scroll.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      direction: optionalEnum(["down", "up", "left", "right"], "High-level scroll direction. Defaults to down."),
      amount: number("Scroll amount in pixel units when direction is used. Daemon default is 420."),
      deltaX: number("Horizontal scroll wheel delta override."),
      deltaY: number("Vertical scroll wheel delta override."),
      count: integer("Number of scroll events. Daemon default is 1, max 30."),
      delayMs,
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_drag`,
    method: "computer.drag",
    description: "Stage, present, or execute a pointer drag between absolute or window-relative points. Defaults to treatment=stage; pass execute to drag.",
    parameters: object({
      ...targetParams,
      ...windowPointParams,
      fromX: number("Absolute drag start X coordinate."),
      fromY: number("Absolute drag start Y coordinate."),
      toX: number("Absolute drag end X coordinate."),
      toY: number("Absolute drag end Y coordinate."),
      fromXRatio: ratio("Window-relative drag start X ratio."),
      fromYRatio: ratio("Window-relative drag start Y ratio."),
      toXRatio: ratio("Window-relative drag end X ratio."),
      toYRatio: ratio("Window-relative drag end Y ratio."),
      button: optionalEnum(["left", "right", "secondary", "context"], "Mouse button held while dragging. Defaults to left."),
      durationMs,
      steps: integer("Interpolated drag event count. Daemon default is 18, max 120."),
      ...computerBaseParams,
    }),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_verify`,
    method: "computer.verify",
    description: "Verify OCR, AX, or artifact-change expectations after a computer-use flow.",
    parameters: object({
      ...targetParams,
      mode: optionalEnum(["ocr", "ax", "artifactChanged"], "Verification mode. Defaults to OCR."),
      snapshotId: string("AX snapshot id from lattices_computer_window_state."),
      elementId: string("AX element id within snapshotId."),
      runId: string("Run id containing an image artifact."),
      artifactId,
      path,
      contains: string("Text that should be present."),
      expected: string("Alias for contains."),
      notContains: string("Text that should be absent."),
      beforeArtifactId: string("Before artifact id for artifactChanged mode."),
      afterArtifactId: string("After artifact id for artifactChanged mode."),
      beforePath: string("Before image path for artifactChanged mode."),
      afterPath: string("After image path for artifactChanged mode."),
      ...runSourceParams,
    }),
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}browser_get_text`,
    method: "browser.getText",
    description: "Read visible browser text through Accessibility without enabling browser JavaScript automation.",
    parameters: object({
      wid,
      app: string("Browser app name, such as Safari, Google Chrome, Brave Browser, Microsoft Edge, or Arc."),
      title,
    }),
  },
  {
    name: `${TOOL_PREFIX}browser_query_dom`,
    method: "browser.queryDom",
    description: "Read DOM element summaries from a supported browser. Requires allowAutomation=true.",
    parameters: object({
      wid,
      app: string("Browser app name, such as Safari, Google Chrome, Brave Browser, Microsoft Edge, or Arc."),
      title,
      selector,
      limit: integer("Maximum nodes to return. Daemon default is 20, max 200."),
      allowAutomation,
    }, ["selector", "allowAutomation"]),
  },
  {
    name: `${TOOL_PREFIX}browser_execute_javascript`,
    method: "browser.executeJavascript",
    description: "Stage or execute JavaScript in a supported browser tab. Execute requires treatment=execute and allowAutomation=true.",
    parameters: object({
      wid,
      app: string("Browser app name, such as Safari, Google Chrome, Brave Browser, Microsoft Edge, or Arc."),
      title,
      script,
      treatment,
      allowAutomation,
      ...runSourceParams,
    }, ["script"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_type_window_text`,
    method: "computer.typeWindowText",
    description: "Type into a normal app window, optionally after a click. Defaults to treatment=stage; pass execute to insert text.",
    parameters: object({
      wid,
      app,
      title,
      text,
      enter: boolean("Press Enter after typing. Defaults to false."),
      send: boolean("Alias for enter in chat-style demos."),
      ...windowPointParams,
      ...computerBaseParams,
    }, ["text"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}computer_type_text`,
    method: "computer.typeText",
    description: "Insert text into a safe terminal through Lattices transports. Defaults to treatment=stage; pass execute to type.",
    parameters: object({
      wid,
      tty: string("Specific terminal TTY."),
      app: string("Preferred terminal app, such as Terminal or iTerm2."),
      text,
      enter: boolean("Press Enter after typing. Defaults to false."),
      transport: optionalEnum(["auto", "tmux", "pasteboard"], "Terminal text transport. Defaults to auto."),
      ...computerBaseParams,
    }, ["text"]),
    defaultTreatment: "stage",
    defaultSource: DEFAULT_SOURCE,
  },
  {
    name: `${TOOL_PREFIX}call`,
    method: null,
    description: "Escape hatch for calling any Lattices daemon method by name. Prefer typed lattices_* tools when available.",
    parameters: object({
      method: string("Daemon method name, such as windows.list or computer.prepare."),
      params: {
        type: "object",
        additionalProperties: true,
        description: "Method-specific JSON params.",
      },
      timeoutMs: {
        type: "integer",
        minimum: 1,
        description: "Optional per-call timeout in milliseconds.",
      },
    }, ["method"]),
    escapeHatch: true,
  },
];

export default function latticesPiExtension(pi) {
  pi.on("session_start", async (_event, ctx) => {
    for (const tool of LATTICES_TOOLS) {
      pi.registerTool(createPiTool(tool, ctx));
    }
  });
}

function createPiTool(definition, sessionContext) {
  return {
    name: definition.name,
    label: definition.name,
    description: definition.description,
    parameters: definition.parameters,
    async execute(_toolCallId, params = {}, _signal, _onUpdate, ctx) {
      const executionContext = ctx ?? sessionContext;
      const call = daemonRequestForTool(definition, params ?? {});

      try {
        const result = await daemonCall(call.method, call.params, call.options);
        return formatSuccess(result);
      } catch (error) {
        notifyError(executionContext, definition.name, error);
        return formatError(definition.name, error);
      }
    },
  };
}

function daemonRequestForTool(definition, params) {
  if (definition.escapeHatch) {
    const { method, params: callParams = null, timeoutMs } = params;
    return {
      method,
      params: callParams,
      options: timeoutMs ? { timeoutMs } : {},
    };
  }

  const callParams = { ...params };
  if (definition.defaultSource && callParams.source === undefined) {
    callParams.source = definition.defaultSource;
  }
  if (definition.defaultTreatment
    && callParams.treatment === undefined
    && callParams.dryRun === undefined) {
    callParams.treatment = definition.defaultTreatment;
  }

  return {
    method: definition.method,
    params: Object.keys(callParams).length === 0 ? null : callParams,
    options: {},
  };
}

function formatSuccess(result) {
  return {
    content: [{ type: "text", text: stringifyResult(result) }],
    details: result,
  };
}

function formatError(toolName, error) {
  const config = daemonConfig();
  const endpoint = config.socketPath ?? `ws://${config.host}:${config.port}`;
  const original = error instanceof Error ? error.message : String(error);
  const text = isDaemonUnavailable(error)
    ? [
        `Lattices daemon is not reachable at ${endpoint}.`,
        "Start Lattices with: lattices app",
        "Then retry the Pi tool.",
        `Tool: ${toolName}`,
        `Original error: ${original}`,
      ].join("\n")
    : [
        `Lattices daemon returned an error for ${toolName}:`,
        original,
      ].join("\n");

  return {
    content: [{ type: "text", text }],
    details: {
      tool: toolName,
      daemon: endpoint,
      error: original,
      daemonUnavailable: isDaemonUnavailable(error),
    },
    isError: true,
  };
}

function notifyError(ctx, toolName, error) {
  if (!isDaemonUnavailable(error)) return;
  try {
    ctx?.ui?.notify?.(`pi-lattices: ${toolName} cannot reach the Lattices daemon. Start it with: lattices app`, "warning");
  } catch {
    // Notification is best-effort; tool output remains the source of truth.
  }
}

function stringifyResult(result) {
  if (result === undefined) return "undefined";
  if (typeof result === "string") return result;
  return JSON.stringify(result, null, 2);
}
