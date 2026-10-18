import { randomBytes } from "node:crypto";
import { createConnection } from "node:net";

// This SDK only needs a small, synchronous subset of Zod. Keeping that subset
// here avoids making every CLI install pull in a general-purpose schema library
// while preserving the public schemas' parse/safeParse interface.
function validationError(path, message) {
  const location = path.length ? ` at ${path.join(".")}` : "";
  const error = new Error(`${message}${location}`);
  error.name = "ValidationError";
  error.issues = [{ path, message }];
  return error;
}

function schema(parser) {
  const value = {
    _parse: parser,
    parse(input) {
      return parser(input, []);
    },
    safeParse(input) {
      try {
        return { success: true, data: value.parse(input) };
      } catch (error) {
        return { success: false, error };
      }
    },
    optional() {
      const optionalSchema = schema((input, path) =>
        input === undefined ? undefined : parser(input, path)
      );
      optionalSchema._optional = true;
      return optionalSchema;
    },
    refine(check, message = "Invalid value") {
      return schema((input, path) => {
        const parsed = parser(input, path);
        if (!check(parsed)) throw validationError(path, message);
        return parsed;
      });
    },
  };
  return value;
}

function withChecks(kind, initialChecks = []) {
  const build = (checks) => {
    const value = schema((input, path) => {
      if (typeof input !== kind) {
        throw validationError(path, `Expected ${kind}`);
      }
      for (const { check, message } of checks) {
        if (!check(input)) throw validationError(path, message);
      }
      return input;
    });
    const add = (check, message) => build([...checks, { check, message }]);
    if (kind === "string") {
      value.min = (minimum) => add(
        (input) => input.length >= minimum,
        `Expected string length to be at least ${minimum}`
      );
    } else {
      value.min = (minimum) => add(
        (input) => input >= minimum,
        `Expected number to be at least ${minimum}`
      );
      value.max = (maximum) => add(
        (input) => input <= maximum,
        `Expected number to be at most ${maximum}`
      );
      value.int = () => add(Number.isInteger, "Expected integer");
      value.finite = () => add(Number.isFinite, "Expected finite number");
      value.positive = () => add((input) => input > 0, "Expected positive number");
      value.nonnegative = () => add((input) => input >= 0, "Expected nonnegative number");
    }
    return value;
  };
  return build(initialChecks);
}

function objectSchema(shape) {
  const value = schema((input, path) => {
    if (!input || typeof input !== "object" || Array.isArray(input)) {
      throw validationError(path, "Expected object");
    }
    const output = {};
    for (const [key, child] of Object.entries(shape)) {
      const parsed = child._parse(input[key], [...path, key]);
      if (parsed !== undefined || Object.hasOwn(input, key)) output[key] = parsed;
    }
    return output;
  });
  value._shape = shape;
  value.extend = (extension) => objectSchema({ ...shape, ...extension });
  value.merge = (other) => objectSchema({ ...shape, ...other._shape });
  value.pick = (selection) => objectSchema(Object.fromEntries(
    Object.keys(selection)
      .filter((key) => selection[key] && key in shape)
      .map((key) => [key, shape[key]])
  ));
  return value;
}

const z = {
  string: () => withChecks("string"),
  number: () => withChecks("number"),
  boolean: () => schema((input, path) => {
    if (typeof input !== "boolean") throw validationError(path, "Expected boolean");
    return input;
  }),
  enum: (values) => schema((input, path) => {
    if (!values.includes(input)) {
      throw validationError(path, `Expected one of: ${values.join(", ")}`);
    }
    return input;
  }),
  array: (item) => schema((input, path) => {
    if (!Array.isArray(input)) throw validationError(path, "Expected array");
    return input.map((entry, index) => item._parse(entry, [...path, index]));
  }),
  union: (schemas) => schema((input, path) => {
    for (const candidate of schemas) {
      try {
        return candidate._parse(input, path);
      } catch {}
    }
    throw validationError(path, "Value did not match any allowed type");
  }),
  object: objectSchema,
};

const DAEMON_HOST = "127.0.0.1";
const DAEMON_PORT = 9399;

export const computerTreatmentSchema = z.enum([
  "observe",
  "stage",
  "present",
  "execute",
]);

export const computerClickTransportSchema = z.enum([
  "auto",
  "ax",
  "accessibility",
  "pointer",
  "mouse",
  "hardware",
]);

export const cursorStyleSchema = z.enum(["spotlight", "pulse", "marker"]);
export const cursorShapeSchema = z.enum([
  "arrow",
  "chevron",
  "facet",
  "shard",
  "wedge",
  "prism",
  "notch",
  "needle",
  "petal",
  "kite",
]);
export const cursorSizeSchema = z.enum(["tiny", "small", "regular", "large"]);
export const cursorTrailSchema = z.enum(["none", "thread", "ribbon", "spark", "comet", "route"]);
export const cursorMotionSchema = z.enum([
  "glide",
  "snap",
  "float",
  "rush",
  "crawl",
  "accelerate",
  "teleport",
  "spring",
  "magnet",
  "slingshot",
]);
export const cursorTrajectorySchema = z.enum(["straight", "soft", "arc", "swoop", "overshoot"]);
export const cursorGlowSchema = z.enum(["none", "soft", "halo", "comet"]);
export const cursorIdleSchema = z.enum([
  "still",
  "breathe",
  "wiggle",
  "orbit",
  "hover",
  "nod",
  "drift",
  "shimmer",
  "blink",
  "tremble",
]);
export const cursorEdgeSchema = z.enum([
  "none",
  "pulse",
  "ripple",
  "tick",
  "reticle",
  "blink",
  "spark",
  "underline",
  "echo",
  "scan",
  "pin",
]);
export const cursorSoundSchema = z.enum(["none", "tick", "click", "engage", "chime"]);
export const captionPlacementSchema = z.enum([
  "top-left",
  "top-right",
  "bottom-left",
  "bottom-right",
  "top-center",
  "top",
  "center",
  "middle",
  "near-cursor",
  "cursor",
]);

const ratioSchema = z.number().min(0).max(1);
const pointSchema = z.number().finite();

const windowTargetSchema = z.object({
  wid: z.number().int().positive().optional(),
  session: z.string().min(1).optional(),
  app: z.string().min(1).optional(),
  title: z.string().optional(),
});

const actionBaseSchema = z.object({
  treatment: computerTreatmentSchema.optional(),
  dryRun: z.boolean().optional(),
  capture: z.boolean().optional(),
  source: z.string().optional(),
});

const pointTargetSchema = z.object({
  x: pointSchema.optional(),
  y: pointSchema.optional(),
  xRatio: ratioSchema.optional(),
  yRatio: ratioSchema.optional(),
});

const cursorAppearanceSchema = z.object({
  style: cursorStyleSchema.optional(),
  appearance: cursorStyleSchema.optional(),
  shape: cursorShapeSchema.optional(),
  angleDeg: z.number().finite().optional(),
  size: cursorSizeSchema.optional(),
  color: z.string().min(1).optional(),
  durationMs: z.number().int().positive().optional(),
  label: z.string().optional(),
  caption: z.string().optional(),
  captionTitle: z.string().optional(),
  captionBody: z.string().optional(),
  captionDetail: z.string().optional(),
  captionTags: z.string().optional(),
  captionMode: z.enum(["auto", "selection"]).optional(),
  captionEyebrow: z.string().optional(),
  captionLeadMs: z.number().finite().nonnegative().optional(),
  captionSound: cursorSoundSchema.optional(),
  captionPlacement: captionPlacementSchema.optional(),
  captionMargin: z.number().finite().nonnegative().optional(),
  captionX: z.number().finite().optional(),
  captionY: z.number().finite().optional(),
  captionXRatio: ratioSchema.optional(),
  captionYRatio: ratioSchema.optional(),
  captionLeftRatio: ratioSchema.optional(),
  captionTopRatio: ratioSchema.optional(),
  sound: cursorSoundSchema.optional(),
  sfx: cursorSoundSchema.optional(),
  showCaption: z.boolean().optional(),
  captionSelections: z.boolean().optional(),
  treatmentLabel: z.string().optional(),
  variant: z.string().optional(),
  trail: cursorTrailSchema.optional(),
  pathStyle: cursorTrailSchema.optional(),
  motion: cursorMotionSchema.optional(),
  trajectory: cursorTrajectorySchema.optional(),
  glow: cursorGlowSchema.optional(),
  bloom: cursorGlowSchema.optional(),
  idle: cursorIdleSchema.optional(),
  settle: cursorIdleSchema.optional(),
  presence: cursorIdleSchema.optional(),
  edge: cursorEdgeSchema.optional(),
  edgeEffect: cursorEdgeSchema.optional(),
  arrival: cursorEdgeSchema.optional(),
  typewriter: z.boolean().optional(),
  typing: z.boolean().optional(),
  typeIntervalMs: z.number().finite().positive().optional(),
  typingIntervalMs: z.number().finite().positive().optional(),
});

export const computerClickParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .merge(cursorAppearanceSchema.pick({ label: true }))
  .extend({
    button: z.enum(["left", "right", "secondary", "context"]).optional(),
    count: z.number().int().positive().max(8).optional(),
    delayMs: z.number().finite().nonnegative().optional(),
    transport: computerClickTransportSchema.optional(),
    axLabel: z.string().min(1).optional(),
    targetText: z.string().min(1).optional(),
    noFocus: z.boolean().optional(),
  });

export const computerMagicCursorParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .merge(cursorAppearanceSchema)
  .extend({
    text: z.string().optional(),
    append: z.boolean().optional(),
    fromX: pointSchema.optional(),
    fromY: pointSchema.optional(),
    fromXRatio: ratioSchema.optional(),
    fromYRatio: ratioSchema.optional(),
  });

export const computerWindowStateParamsSchema = windowTargetSchema.extend({
  mode: z.enum(["ax", "both", "screenshot"]).optional(),
  capture: z.boolean().optional(),
  maxDepth: z.number().int().positive().optional(),
  maxElements: z.number().int().positive().optional(),
  timeoutMs: z.number().int().positive().optional(),
  source: z.string().optional(),
});

export const computerElementActionParamsSchema = actionBaseSchema.extend({
  snapshotId: z.string().min(1),
  elementId: z.string().min(1),
  action: z.enum(["press", "showMenu", "focus"]).optional(),
});

export const computerTypeElementParamsSchema = actionBaseSchema.extend({
  snapshotId: z.string().min(1),
  elementId: z.string().min(1),
  text: z.string(),
  append: z.boolean().optional(),
  typeIntervalMs: z.number().finite().positive().optional(),
});

export const computerSetValueParamsSchema = actionBaseSchema.extend({
  snapshotId: z.string().min(1),
  elementId: z.string().min(1),
  value: z.string(),
  append: z.boolean().optional(),
  typeIntervalMs: z.number().finite().positive().optional(),
});

const keyboardParamsSchema = windowTargetSchema.merge(actionBaseSchema).extend({
  key: z.string().min(1).optional(),
  shortcut: z.string().min(1).optional(),
  modifiers: z.union([z.array(z.string()), z.string()]).optional(),
  count: z.number().int().positive().max(20).optional(),
  delayMs: z.number().finite().nonnegative().optional(),
  allowGlobal: z.boolean().optional(),
});

export const computerPressKeyParamsSchema = keyboardParamsSchema.extend({
  key: z.string().min(1),
});

export const computerHotkeyParamsSchema = keyboardParamsSchema.refine(
  (value) => Boolean(value.shortcut || value.key),
  "computer.hotkey requires shortcut or key"
);

export const computerFocusWindowParamsSchema = windowTargetSchema.merge(actionBaseSchema);

export const computerLaunchAppParamsSchema = actionBaseSchema.extend({
  app: z.string().min(1),
  bundleId: z.string().min(1).optional(),
  path: z.string().min(1).optional(),
  title: z.string().optional(),
});

export const computerTypeWindowTextParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .extend({
    text: z.string(),
    enter: z.boolean().optional(),
    send: z.boolean().optional(),
  });

export const computerTypeTextParamsSchema = actionBaseSchema.extend({
  wid: z.number().int().positive().optional(),
  tty: z.string().min(1).optional(),
  app: z.string().min(1).optional(),
  text: z.string(),
  enter: z.boolean().optional(),
  transport: z.enum(["auto", "tmux", "iterm", "iterm2", "pasteboard"]).optional(),
});

export const computerDoubleClickParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .extend({
    delayMs: z.number().finite().nonnegative().optional(),
  });

export const computerRightClickParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .extend({
    count: z.number().int().positive().max(8).optional(),
    delayMs: z.number().finite().nonnegative().optional(),
  });

export const computerScrollParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .extend({
    direction: z.enum(["down", "up", "left", "right"]).optional(),
    amount: z.number().finite().optional(),
    deltaX: z.number().finite().optional(),
    deltaY: z.number().finite().optional(),
    count: z.number().int().positive().max(30).optional(),
    delayMs: z.number().finite().nonnegative().optional(),
  });

export const computerDragParamsSchema = windowTargetSchema
  .merge(pointTargetSchema)
  .merge(actionBaseSchema)
  .extend({
    fromX: pointSchema.optional(),
    fromY: pointSchema.optional(),
    toX: pointSchema.optional(),
    toY: pointSchema.optional(),
    fromXRatio: ratioSchema.optional(),
    fromYRatio: ratioSchema.optional(),
    toXRatio: ratioSchema.optional(),
    toYRatio: ratioSchema.optional(),
    button: z.enum(["left", "right", "secondary", "context"]).optional(),
    durationMs: z.number().finite().positive().optional(),
    steps: z.number().int().positive().max(120).optional(),
  });

export const computerVerifyParamsSchema = windowTargetSchema.extend({
  mode: z.enum(["ocr", "ax", "artifactChanged"]).optional(),
  snapshotId: z.string().min(1).optional(),
  elementId: z.string().min(1).optional(),
  runId: z.string().min(1).optional(),
  artifactId: z.string().min(1).optional(),
  path: z.string().min(1).optional(),
  contains: z.string().optional(),
  expected: z.string().optional(),
  notContains: z.string().optional(),
  beforeArtifactId: z.string().min(1).optional(),
  afterArtifactId: z.string().min(1).optional(),
  beforePath: z.string().min(1).optional(),
  afterPath: z.string().min(1).optional(),
  source: z.string().optional(),
});

export const captureWindowParamsSchema = windowTargetSchema.extend({
  runId: z.string().min(1).optional(),
  filename: z.string().min(1).optional(),
  source: z.string().optional(),
});

export const captureRegionParamsSchema = windowTargetSchema.extend({
  x: pointSchema.optional(),
  y: pointSchema.optional(),
  width: z.number().finite().positive().optional(),
  height: z.number().finite().positive().optional(),
  w: z.number().finite().positive().optional(),
  h: z.number().finite().positive().optional(),
  runId: z.string().min(1).optional(),
  filename: z.string().min(1).optional(),
  source: z.string().optional(),
});

export const zoomArtifactParamsSchema = z.object({
  runId: z.string().min(1).optional(),
  artifactId: z.string().min(1).optional(),
  path: z.string().min(1).optional(),
  x: z.number().finite().optional(),
  y: z.number().finite().optional(),
  width: z.number().finite().positive().optional(),
  height: z.number().finite().positive().optional(),
  xRatio: ratioSchema.optional(),
  yRatio: ratioSchema.optional(),
  widthRatio: ratioSchema.optional(),
  heightRatio: ratioSchema.optional(),
  scale: z.number().finite().positive().optional(),
  filename: z.string().min(1).optional(),
  source: z.string().optional(),
});

const visionBaseSchema = z.object({
  instruction: z.string().min(1),
  contains: z.string().optional(),
  notContains: z.string().optional(),
  source: z.string().optional(),
});

export const visionAnalyzeWindowParamsSchema = windowTargetSchema.merge(visionBaseSchema);

export const visionAnalyzeArtifactParamsSchema = visionBaseSchema.extend({
  runId: z.string().min(1).optional(),
  artifactId: z.string().min(1).optional(),
  path: z.string().min(1).optional(),
});

export const browserGetTextParamsSchema = windowTargetSchema;

export const browserQueryDomParamsSchema = windowTargetSchema.extend({
  selector: z.string().min(1),
  limit: z.number().int().positive().max(200).optional(),
  allowAutomation: z.boolean(),
});

export const browserExecuteJavascriptParamsSchema = windowTargetSchema.extend({
  script: z.string().min(1),
  treatment: computerTreatmentSchema.optional(),
  allowAutomation: z.boolean().optional(),
  source: z.string().optional(),
});

export function createCuaClient(options = {}) {
  const defaultTimeoutMs = options.defaultTimeoutMs ?? 30_000;

  async function call(method, params, timeoutMs = defaultTimeoutMs) {
    return daemonCall(method, params, timeoutMs);
  }

  return {
    windowState(params) {
      return call("computer.windowState", computerWindowStateParamsSchema.parse(params));
    },
    elementAction(params) {
      return call("computer.elementAction", computerElementActionParamsSchema.parse(params));
    },
    typeElement(params) {
      return call("computer.typeElement", computerTypeElementParamsSchema.parse(params));
    },
    setValue(params) {
      return call("computer.setValue", computerSetValueParamsSchema.parse(params));
    },
    pressKey(params) {
      return call("computer.pressKey", computerPressKeyParamsSchema.parse(params));
    },
    hotkey(params) {
      return call("computer.hotkey", computerHotkeyParamsSchema.parse(params));
    },
    focusWindow(params) {
      return call("computer.focusWindow", computerFocusWindowParamsSchema.parse(params));
    },
    launchApp(params) {
      return call("computer.launchApp", computerLaunchAppParamsSchema.parse(params));
    },
    typeWindowText(params) {
      return call("computer.typeWindowText", computerTypeWindowTextParamsSchema.parse(params));
    },
    typeText(params) {
      return call("computer.typeText", computerTypeTextParamsSchema.parse(params));
    },
    click(params) {
      return call("computer.click", computerClickParamsSchema.parse(params));
    },
    doubleClick(params) {
      return call("computer.doubleClick", computerDoubleClickParamsSchema.parse(params));
    },
    rightClick(params) {
      return call("computer.rightClick", computerRightClickParamsSchema.parse(params));
    },
    scroll(params) {
      return call("computer.scroll", computerScrollParamsSchema.parse(params));
    },
    drag(params) {
      return call("computer.drag", computerDragParamsSchema.parse(params));
    },
    verify(params) {
      return call("computer.verify", computerVerifyParamsSchema.parse(params));
    },
    captureWindow(params) {
      return call("capture.screenshotWindow", captureWindowParamsSchema.parse(params));
    },
    screenshotRegion(params) {
      return call("capture.screenshotRegion", captureRegionParamsSchema.parse(params));
    },
    zoomArtifact(params) {
      return call("capture.zoomArtifact", zoomArtifactParamsSchema.parse(params));
    },
    analyzeWindow(params) {
      return call("vision.analyzeWindow", visionAnalyzeWindowParamsSchema.parse(params));
    },
    analyzeArtifact(params) {
      return call("vision.analyzeArtifact", visionAnalyzeArtifactParamsSchema.parse(params));
    },
    browserGetText(params) {
      return call("browser.getText", browserGetTextParamsSchema.parse(params));
    },
    browserQueryDom(params) {
      return call("browser.queryDom", browserQueryDomParamsSchema.parse(params));
    },
    browserExecuteJavascript(params) {
      return call("browser.executeJavascript", browserExecuteJavascriptParamsSchema.parse(params));
    },
    magicCursor(params) {
      return call("computer.magicCursor", computerMagicCursorParamsSchema.parse(params));
    },
  };
}

export const cua = createCuaClient();

export function windowState(params) {
  return cua.windowState(params);
}

export function elementAction(params) {
  return cua.elementAction(params);
}

export function typeElement(params) {
  return cua.typeElement(params);
}

export function setValue(params) {
  return cua.setValue(params);
}

export function pressKey(params) {
  return cua.pressKey(params);
}

export function hotkey(params) {
  return cua.hotkey(params);
}

export function focusWindow(params) {
  return cua.focusWindow(params);
}

export function launchApp(params) {
  return cua.launchApp(params);
}

export function typeWindowText(params) {
  return cua.typeWindowText(params);
}

export function typeText(params) {
  return cua.typeText(params);
}

export function click(params) {
  return cua.click(params);
}

export function doubleClick(params) {
  return cua.doubleClick(params);
}

export function rightClick(params) {
  return cua.rightClick(params);
}

export function scroll(params) {
  return cua.scroll(params);
}

export function drag(params) {
  return cua.drag(params);
}

export function verify(params) {
  return cua.verify(params);
}

export function captureWindow(params) {
  return cua.captureWindow(params);
}

export function screenshotRegion(params) {
  return cua.screenshotRegion(params);
}

export function zoomArtifact(params) {
  return cua.zoomArtifact(params);
}

export function analyzeWindow(params) {
  return cua.analyzeWindow(params);
}

export function analyzeArtifact(params) {
  return cua.analyzeArtifact(params);
}

export function browserGetText(params) {
  return cua.browserGetText(params);
}

export function browserQueryDom(params) {
  return cua.browserQueryDom(params);
}

export function browserExecuteJavascript(params) {
  return cua.browserExecuteJavascript(params);
}

export function magicCursor(params) {
  return cua.magicCursor(params);
}

export async function daemonCall(method, params = null, timeoutMs = 3000) {
  const id = randomBytes(4).toString("hex");
  const deadline = Date.now() + timeoutMs;
  const request = JSON.stringify({ id, method, params: params ?? null, deadline });
  const mutation = method.startsWith("computer.") && !/\.(observe|capture|status)$/.test(method);
  const uncertain = () => new Error("Daemon connection lost or deadline exceeded; action outcome uncertain; do not retry blindly");

  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: DAEMON_HOST, port: DAEMON_PORT });
    let settled = false;
    let buffer = Buffer.alloc(0);
    let upgraded = false;
    let sent = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.destroy();
        reject(mutation && sent ? uncertain() : new Error("Daemon request timed out"));
      }
    }, timeoutMs + (mutation ? 1500 : 0));

    const cleanup = () => {
      clearTimeout(timer);
      socket.destroy();
    };

    socket.on("error", (err) => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(mutation && sent ? uncertain() : err);
      }
    });

    socket.on("close", () => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(mutation && sent ? uncertain() : new Error("Daemon connection closed"));
      }
    });
    socket.on("connect", () => {
      const key = randomBytes(16).toString("base64");
      const upgrade = [
        "GET / HTTP/1.1",
        `Host: ${DAEMON_HOST}:${DAEMON_PORT}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n");
      socket.write(upgrade);
    });

    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);

      if (!upgraded) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;
        const header = buffer.subarray(0, headerEnd).toString();
        if (!header.includes("101")) {
          settled = true;
          cleanup();
          reject(new Error("WebSocket upgrade failed"));
          return;
        }
        upgraded = true;
        buffer = buffer.subarray(headerEnd + 4);
        sent = true;
        sendFrame(socket, request);
      }

      while (true) {
        const result = parseFrame(buffer);
        if (!result) break;
        buffer = result.rest;

        try {
          const parsed = JSON.parse(result.payload);
          if (parsed.event || parsed.id !== id) continue;
          if (!settled) {
            settled = true;
            cleanup();
            if (parsed.error) {
              reject(new Error(parsed.error));
            } else {
              resolve(parsed.result);
            }
          }
          return;
        } catch {
          if (!settled) {
            settled = true;
            cleanup();
            reject(mutation && sent ? uncertain() : new Error("Invalid JSON response from daemon"));
          }
          return;
        }
      }
    });
  });
}

function sendFrame(socket, text) {
  const payload = Buffer.from(text, "utf8");
  const mask = randomBytes(4);
  const len = payload.length;

  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81;
    header[1] = 0x80 | len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }

  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) {
    masked[i] = payload[i] ^ mask[i % 4];
  }

  socket.write(Buffer.concat([header, mask, masked]));
}

function parseFrame(buf) {
  if (buf.length < 2) return null;

  const isMasked = (buf[1] & 0x80) !== 0;
  let payloadLen = buf[1] & 0x7f;
  let offset = 2;

  if (payloadLen === 126) {
    if (buf.length < 4) return null;
    payloadLen = buf.readUInt16BE(2);
    offset = 4;
  } else if (payloadLen === 127) {
    if (buf.length < 10) return null;
    payloadLen = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }

  if (isMasked) offset += 4;
  if (buf.length < offset + payloadLen) return null;

  let payload = buf.subarray(offset, offset + payloadLen);
  if (isMasked) {
    const maskKey = buf.subarray(offset - 4, offset);
    payload = Buffer.alloc(payloadLen);
    for (let i = 0; i < payloadLen; i++) {
      payload[i] = buf[offset + i] ^ maskKey[i % 4];
    }
  }

  return {
    payload: payload.toString("utf8"),
    rest: buf.subarray(offset + payloadLen),
  };
}
