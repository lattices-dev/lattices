import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { before, test } from "node:test";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { toSessionName, pathHash } from "../bin/cli/session.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const nodeBin = process.execPath;
const cliEntry = path.join(repoRoot, "bin/lattices.ts");
const daemonClientUrl = pathToFileURL(
  path.join(repoRoot, "bin/daemon-client.ts")
).href;

const { isDaemonRunning } = await import(daemonClientUrl);
const { createWorkspaceMapSnapshot, parseMapOptions, renderWorkspaceMap } = await import(
  pathToFileURL(path.join(repoRoot, "bin/cli/map.ts")).href
);
const {
  createDesktopMapReference,
  intersectMapFrames,
  projectMapFrame,
  unionMapFrames,
} = await import(pathToFileURL(path.join(repoRoot, "bin/cli/map-reference.ts")).href);
const { displaysMissingGeometry } = await import(
  pathToFileURL(path.join(repoRoot, "bin/cli/map.ts")).href
);
const { parseCaptureDisplayArgs } = await import(
  pathToFileURL(path.join(repoRoot, "bin/cli/capture.ts")).href
);
const {
  describeMoveReceipt,
  normalizePlacement,
  parseWindowMoveArgs,
  parseWindowPlaceArgs,
} = await import(pathToFileURL(path.join(repoRoot, "bin/cli/window.ts")).href);
const { layerListLines, layerTarget, layerWindowCounts, padSlot } = await import(
  pathToFileURL(path.join(repoRoot, "bin/cli/layer.ts")).href
);

/** @type {boolean} */
let daemonRunning = false;

before(async () => {
  daemonRunning = await isDaemonRunning();
});

function runCli(args) {
  return execFileSync(
    nodeBin,
    ["--experimental-strip-types", cliEntry, ...args],
    {
      cwd: repoRoot,
      encoding: "utf8",
      env: process.env,
    }
  ).trim();
}

function runCliRaw(args) {
  try {
    const stdout = execFileSync(
      nodeBin,
      ["--experimental-strip-types", cliEntry, ...args],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: process.env,
      }
    );
    return { stdout: stdout.trim(), stderr: "", status: 0 };
  } catch (err) {
    return {
      stdout: (err.stdout || "").toString().trim(),
      stderr: (err.stderr || "").toString().trim(),
      status: err.status ?? 1,
    };
  }
}

// ── workspace map helpers ────────────────────────────────────────────

// The drawn grid only: from the first display row to the row before the Key
// block. Anchoring on "Key ·" keeps these assertions honest when the summary,
// key, or legend gains a line.
function canvasOf(out) {
  const lines = out.split("\n");
  const keyAt = lines.findIndex((line) => line.startsWith("Key ·"));
  assert.ok(keyAt > 2, `expected a Key block:\n${out}`);
  return lines.slice(2, keyAt - 1);
}

function windowLegendOf(out) {
  const lines = out.split("\n");
  const start = lines.findIndex((line) => line.startsWith("Windows ·"));
  assert.ok(start > 0, `expected a window legend:\n${out}`);
  return lines
    .slice(start + 1)
    .filter((line) => line.trim())
    .map((line) => ({
      index: Number(line.trim().split(/\s+/)[0]),
      note: line.match(/\((?:small|too small to label|off-canvas)\)$/u)?.[0] ?? "",
      line,
    }));
}

// The identity invariant: every legend row resolves to exactly one honest
// state — "[n]" on the canvas, an un-truncated bare "n" plus (small), or a note
// explaining the absence. A silent unlabeled box is the failure this catches.
function assertWindowIdentity(out, context) {
  const canvas = canvasOf(out).join("\n");
  const rows = windowLegendOf(out);
  assert.ok(rows.length > 0, `${context}: expected window legend rows\n${out}`);
  for (const { index, note } of rows) {
    if (note === "") {
      assert.ok(
        canvas.includes(`[${index}]`),
        `${context}: window ${index} carries no note but has no [${index}] on the canvas\n${out}`
      );
      continue;
    }
    if (note === "(small)") {
      // The whole number, never a prefix of it: "12" clipped to "1" would be
      // silently indistinguishable from window 1.
      assert.match(
        canvas,
        new RegExp(`(?<![0-9])${index}(?![0-9])`, "u"),
        `${context}: window ${index} is marked (small) but its bare number is not on the canvas\n${out}`
      );
      continue;
    }
    assert.ok(
      note === "(too small to label)" || note === "(off-canvas)",
      `${context}: window ${index} has an unrecognized note ${note}\n${out}`
    );
  }
  return rows;
}

// ── session hash parity ──────────────────────────────────────────────

test("session hash: known repo path produces stable session name", () => {
  // Keep the parity fixture independent of the checkout/worktree location.
  const knownRepoPath = "/Users/art/dev/lattices";
  const session = toSessionName(knownRepoPath);
  assert.equal(session, "lattices-c36f74");
  assert.equal(pathHash(knownRepoPath), "c36f74");
});

test("session hash: format is basename-6hex", () => {
  const session = toSessionName(repoRoot);
  assert.match(session, /^[a-zA-Z0-9_-]+-[0-9a-f]{6}$/);
});

test("session hash: basename sanitization replaces non-alphanumeric chars", () => {
  const session = toSessionName("/tmp/my.project+name");
  assert.match(session, /^my-project-name-[0-9a-f]{6}$/);
  assert.equal(session.slice(0, "my-project-name-".length), "my-project-name-");
});

test("session hash: different paths with same basename get distinct hashes", () => {
  const a = toSessionName("/tmp/proj-a/foo");
  const b = toSessionName("/tmp/proj-b/foo");
  assert.notEqual(a, b);
  assert.match(a, /^foo-[0-9a-f]{6}$/);
  assert.match(b, /^foo-[0-9a-f]{6}$/);
});

test("session hash: default command prints session name for cwd", () => {
  const { stdout } = runCliRaw([]);
  const expected = toSessionName(repoRoot);
  assert.match(stdout, new RegExp(`session\\s+${expected}`));
});

// ── default command & help ───────────────────────────────────────────

test("default command: prints home screen guidance", () => {
  const out = runCli([]);
  assert.match(out, /let's get you situated/);
  assert.match(out, /Common commands/);
});

test("help: mentions lats start and display capture", () => {
  const out = runCli(["help"]);
  assert.match(out, /lats start/);
  assert.match(out, /lats capture display \[index\]/);
});

test("capture help: documents delayed clipboard display capture", () => {
  const out = runCli(["capture", "help"]);
  assert.match(out, /lats capture display \[index\]/);
  assert.match(out, /--clipboard/);
  assert.match(out, /--delay seconds/);
});

test("capture display parsing: accepts target, clipboard, metadata, and delay", () => {
  assert.deepEqual(
    parseCaptureDisplayArgs([
      "1",
      "--clipboard",
      "--delay",
      "3",
      "--filename=hyper-g.png",
      "--run-id",
      "run_demo",
      "--json",
    ]),
    {
      display: 1,
      clipboard: true,
      delaySeconds: 3,
      filename: "hyper-g.png",
      runId: "run_demo",
      json: true,
    },
  );

  assert.deepEqual(parseCaptureDisplayArgs(["--delay=.5"]), {
    display: undefined,
    clipboard: false,
    delaySeconds: 0.5,
    filename: undefined,
    runId: undefined,
    json: false,
  });
});

test("capture display parsing: rejects malformed and ambiguous input", () => {
  assert.throws(() => parseCaptureDisplayArgs(["-1"]), /non-negative integer/);
  assert.throws(() => parseCaptureDisplayArgs(["1.5"]), /non-negative integer/);
  assert.throws(() => parseCaptureDisplayArgs(["0", "1"]), /Unexpected argument: 1/);
  assert.throws(() => parseCaptureDisplayArgs(["--delay"]), /--delay expects a value/);
  assert.throws(() => parseCaptureDisplayArgs(["--delay", "soon"]), /non-negative number of seconds/);
  assert.throws(() => parseCaptureDisplayArgs(["--clipboard=true"]), /does not take a value/);
  assert.throws(() => parseCaptureDisplayArgs(["--bogus"]), /Unknown option: --bogus/);
});

test("map renderer: draws current-space windows and a useful legend", () => {
  const out = renderWorkspaceMap(
    [{ displayIndex: 1, name: "Samsung", currentSpaceId: 7, visibleFrame: { x: 100, y: 20, w: 2000, h: 1000 } }],
    [
      { wid: 10, app: "Simulator", title: "iPhone 16", frame: { x: 100, y: 20, w: 1000, h: 500 }, spaceIds: [7], isOnScreen: true },
      { wid: 11, app: "Chrome", title: "iii console", frame: { x: 1100, y: 20, w: 1000, h: 1000 }, spaceIds: [7], isOnScreen: true },
      { wid: 12, app: "Chrome", title: "hidden space", frame: { x: 100, y: 520, w: 1000, h: 500 }, spaceIds: [5], isOnScreen: false },
    ],
    { width: 60, height: 14 },
  );
  assert.match(out, /Display 1 · Samsung · Space 7/);
  assert.match(out, /Simulator · iPhone 16/);
  assert.match(out, /Chrome · iii console/);
  assert.doesNotMatch(out, /hidden space/);
  assert.match(out, /wid:10/);
});

test("map reference: preserves one global desktop with negative and stacked offsets", () => {
  const frames = [
    { x: 0, y: 0, w: 3440, h: 1440 },
    { x: 3440, y: 0, w: 3840, h: 2160 },
    { x: -1280, y: -1024, w: 1280, h: 1024 },
  ];
  assert.deepEqual(unionMapFrames(frames), { x: -1280, y: -1024, w: 8560, h: 3184 });

  const reference = createDesktopMapReference(frames, { maxColumns: 100, maxRows: 30 });
  assert.ok(reference);
  assert.ok(reference.columns <= 100);
  assert.ok(reference.rows <= 30);

  const left = projectMapFrame(reference, frames[2]);
  const primary = projectMapFrame(reference, frames[0]);
  const right = projectMapFrame(reference, frames[1]);
  assert.equal(left.left, 0);
  assert.equal(left.top, 0);
  assert.equal(left.right, primary.left, "a shared world x edge must project to one canvas column");
  assert.equal(primary.right, right.left, "adjacent displays must remain adjacent after projection");
  assert.ok(primary.top > left.top, "a display above the primary must remain above it");
  assert.ok(right.right <= reference.columns - 1);
  assert.ok(right.bottom <= reference.rows - 1);
});

test("map reference: uses one scale and compensates for terminal cell aspect ratio", () => {
  const landscape = { x: 0, y: 0, w: 2000, h: 1000 };
  const portrait = { x: 2000, y: 0, w: 1000, h: 2000 };
  const reference = createDesktopMapReference([landscape, portrait], {
    maxColumns: 80,
    maxRows: 24,
    cellAspectRatio: 2,
  });
  assert.ok(reference);

  const landscapeCells = projectMapFrame(reference, landscape);
  const portraitCells = projectMapFrame(reference, portrait);
  const landscapeWidth = landscapeCells.right - landscapeCells.left;
  const landscapePhysicalHeight = (landscapeCells.bottom - landscapeCells.top) * 2;
  const portraitWidth = portraitCells.right - portraitCells.left;
  const portraitPhysicalHeight = (portraitCells.bottom - portraitCells.top) * 2;

  assert.ok(Math.abs(landscapeWidth / landscapePhysicalHeight - 2) < 0.12);
  assert.ok(Math.abs(portraitWidth / portraitPhysicalHeight - 0.5) < 0.12);
  assert.equal(landscapeCells.right, portraitCells.left);
});

test("map reference: clips frames in global point coordinates before projection", () => {
  assert.deepEqual(
    intersectMapFrames(
      { x: 100, y: 50, w: 400, h: 300 },
      { x: 0, y: 0, w: 300, h: 200 },
    ),
    { x: 100, y: 50, w: 200, h: 150 },
  );
  assert.equal(
    intersectMapFrames(
      { x: 0, y: 0, w: 100, h: 100 },
      { x: 100, y: 0, w: 100, h: 100 },
    ),
    undefined,
  );
});

test("map renderer: composes offset displays in one proportional desktop canvas", () => {
  const out = renderWorkspaceMap(
    [
      { displayIndex: 0, name: "Wide", currentSpaceId: 1, frame: { x: 0, y: 0, w: 2000, h: 1000 }, visibleFrame: { x: 0, y: 20, w: 2000, h: 980 } },
      { displayIndex: 1, name: "Tall", currentSpaceId: 7, frame: { x: 2000, y: 250, w: 1000, h: 1500 }, visibleFrame: { x: 2000, y: 270, w: 1000, h: 1480 } },
    ],
    [
      { wid: 10, app: "Editor", title: "main", frame: { x: 0, y: 20, w: 1000, h: 980 }, spaceIds: [1], isOnScreen: true },
      { wid: 20, app: "Preview", title: "phone", frame: { x: 2200, y: 700, w: 400, h: 800 }, spaceIds: [7], isOnScreen: true },
    ],
    { width: 80, height: 24 },
  );
  const lines = out.split("\n");
  const d0Top = lines.findIndex((line) => line.includes("D0 · Wide"));
  const d1Top = lines.findIndex((line) => line.includes("D1 · Tall"));
  assert.ok(d0Top >= 0 && d1Top > d0Top, out);
  assert.ok(canvasOf(out).every((line) => line.length <= 80), out);
  assert.match(out, /Desktop 3000×1750 @ 0,0 · 2 displays · 2 windows/);
  assert.match(out, /1\s+D0\s+Editor · main\s+wid:10/);
  assert.match(out, /2\s+D1\s+Preview · phone\s+wid:20/);
});

test("map renderer: retains negative display coordinates and stable display filtering", () => {
  const displays = [
    { displayIndex: 2, name: "Above", currentSpaceId: 8, frame: { x: -1200, y: -900, w: 1200, h: 900 } },
    { displayIndex: 0, name: "Primary", currentSpaceId: 1, frame: { x: 0, y: 0, w: 1600, h: 1000 } },
  ];
  const windows = [
    { wid: 30, app: "Top", title: "negative", frame: { x: -1200, y: -900, w: 600, h: 900 }, spaceIds: [8], isOnScreen: true },
    { wid: 40, app: "Main", title: "origin", frame: { x: 0, y: 0, w: 800, h: 1000 }, spaceIds: [1], isOnScreen: true },
  ];

  const all = renderWorkspaceMap(displays, windows, { width: 72, height: 24 });
  assert.match(all, /Desktop 2800×1900 @ -1200,-900/);
  assert.ok(all.indexOf("D2 · Above") < all.indexOf("D0 · Primary"), all);

  const selected = renderWorkspaceMap(displays, windows, { display: 0, width: 72, height: 24 });
  assert.match(selected, /Desktop 1600×1000 @ 0,0 · 1 display · 1 window/);
  assert.match(selected, /D0 · Primary/);
  assert.match(selected, /1\s+D0\s+Main · origin\s+wid:40/);
  assert.doesNotMatch(selected, /D2 · Above|wid:30/);
});

test("map renderer: overlapping windows stay identifiable and labels stay cell-safe", () => {
  const out = renderWorkspaceMap(
    [{ displayIndex: 0, name: "Main 📺", currentSpaceId: 7, visibleFrame: { x: 0, y: 0, w: 100, h: 100 } }],
    [
      { wid: 2, app: "Front\u001b[31m", title: "前\u001b[31m", frame: { x: 40, y: 40, w: 60, h: 60 }, spaceIds: [7], isOnScreen: true },
      { wid: 1, app: "Back", title: "background", frame: { x: 0, y: 0, w: 100, h: 100 }, spaceIds: [7], isOnScreen: true },
    ],
    { width: 40, height: 12 },
  );
  // The canvas is a fixed grid: every row must be the same number of terminal
  // columns, and never wider than the requested maximum. Anchoring on the
  // display border (╔/║/╚) matters — filtering on window glyphs alone matches
  // nothing here and silently makes this assertion vacuous.
  const canvas = canvasOf(out);
  assert.ok(canvas.length > 0 && /^╔/u.test(canvas[0]), out);
  const widths = new Set(canvas.map((line) => line.length));
  assert.equal(widths.size, 1, `every canvas row must span the same columns: ${[...widths]}`);
  assert.ok(Math.max(...widths) <= 40, out);
  assert.match(out, /\[1\] Front/);
  assert.doesNotMatch(out, /\u001b/);
  // The window the foreground covers keeps its own numbered rectangle: the map
  // is an x-ray floor plan, so nothing is painted out. It is a secondary
  // window, so it carries its number only — its identity is in the legend.
  const drawn = canvas.join("\n");
  assert.ok(drawn.includes("[2]"), out);
  assert.ok(!drawn.includes("[2] Back"), `only the primary window is labelled:\n${out}`);
  assertWindowIdentity(out, "overlapping pair");
  assert.match(out, /Key · ╔═ display ═╗   ┌\[1\] frontmost window ─┐/u);
});

test("map renderer: exactly one labelled primary window per display", () => {
  const out = renderWorkspaceMap(
    [
      { displayIndex: 0, name: "Left", currentSpaceId: 1, frame: { x: 0, y: 0, w: 2000, h: 1200 } },
      { displayIndex: 1, name: "Right", currentSpaceId: 2, frame: { x: 2000, y: 0, w: 2000, h: 1200 } },
    ],
    [
      // Front to back within each display.
      { wid: 1, app: "Alpha", title: "one", frame: { x: 100, y: 100, w: 1200, h: 900 }, spaceIds: [1], isOnScreen: true },
      { wid: 2, app: "Bravo", title: "two", frame: { x: 400, y: 300, w: 1200, h: 800 }, spaceIds: [1], isOnScreen: true },
      { wid: 3, app: "Charlie", title: "three", frame: { x: 2100, y: 100, w: 1200, h: 900 }, spaceIds: [2], isOnScreen: true },
      { wid: 4, app: "Delta", title: "four", frame: { x: 2400, y: 300, w: 1200, h: 800 }, spaceIds: [2], isOnScreen: true },
    ],
    { width: 110, height: 24 },
  );
  const canvas = canvasOf(out).join("\n");

  // The frontmost window of each display spells out its app; the others do not.
  assert.ok(canvas.includes("[1] Alpha"), `D0's primary should be labelled:\n${out}`);
  assert.ok(canvas.includes("[3] Charlie"), `D1's primary should be labelled:\n${out}`);
  assert.ok(canvas.includes("[2]") && canvas.includes("[4]"), out);
  assert.doesNotMatch(canvas, /Bravo|Delta/u, `secondary windows must not be labelled:\n${out}`);
  // Their identity is still available, in the legend.
  assert.match(out, /2\s+D0\s+Bravo · two/u);
  assert.match(out, /4\s+D1\s+Delta · four/u);
  assertWindowIdentity(out, "one primary per display");
});

test("map renderer: every drawable window terminates in its own bottom-right corner", () => {
  const out = renderWorkspaceMap(
    [{ displayIndex: 0, name: "Main", currentSpaceId: 1, frame: { x: 0, y: 0, w: 2000, h: 1200 } }],
    [
      // Three windows whose bottom edges land on the same canvas row. Without a
      // closure pass their corners merge away into one ┴──┴── rail.
      { wid: 1, app: "A", title: "a", frame: { x: 100, y: 100, w: 500, h: 900 }, spaceIds: [1], isOnScreen: true },
      { wid: 2, app: "B", title: "b", frame: { x: 500, y: 100, w: 500, h: 900 }, spaceIds: [1], isOnScreen: true },
      { wid: 3, app: "C", title: "c", frame: { x: 900, y: 100, w: 500, h: 900 }, spaceIds: [1], isOnScreen: true },
    ],
    { width: 100, height: 22 },
  );
  const canvas = canvasOf(out);
  const corners = canvas.join("").split("┘").length - 1;
  assert.equal(corners, 3, `each of the 3 windows needs its own ┘ termination:\n${out}`);
  assertWindowIdentity(out, "closure corners");
});

test("map renderer: a gutter separates the display bezel from every window", () => {
  const bezel = /[═║╔╗╚╝╠╣╦╩╬]/u;
  const windowGlyph = /[─│┌┐└┘├┤┬┴┼]/u;
  const fixtures = [
    {
      label: "maximized window",
      displays: [{ displayIndex: 0, name: "Main", currentSpaceId: 1, frame: { x: 0, y: 0, w: 2000, h: 1200 } }],
      // Flush with the display on every side, and larger than it.
      windows: [{ wid: 1, app: "Full", title: "max", frame: { x: -100, y: -100, w: 2200, h: 1400 }, spaceIds: [1], isOnScreen: true }],
      size: [80, 20],
    },
    {
      label: "adjacent displays",
      displays: [
        { displayIndex: 0, name: "L", currentSpaceId: 1, frame: { x: 0, y: 0, w: 2000, h: 1200 } },
        { displayIndex: 1, name: "R", currentSpaceId: 2, frame: { x: 2000, y: 0, w: 2000, h: 1200 } },
      ],
      windows: [
        { wid: 1, app: "L1", title: "a", frame: { x: 0, y: 0, w: 2000, h: 1200 }, spaceIds: [1], isOnScreen: true },
        { wid: 2, app: "R1", title: "b", frame: { x: 2000, y: 0, w: 2000, h: 1200 }, spaceIds: [2], isOnScreen: true },
      ],
      size: [110, 24],
    },
  ];

  for (const { label, displays, windows, size } of fixtures) {
    const out = renderWorkspaceMap(displays, windows, { width: size[0], height: size[1] });
    const canvas = canvasOf(out);
    for (let y = 0; y < canvas.length; y++) {
      for (let x = 0; x < canvas[y].length; x++) {
        if (!bezel.test(canvas[y][x])) continue;
        // No window glyph may sit on a bezel cell or in any cell touching one:
        // "║┌" reads as one thick frame, which is the confusion the gutter and
        // the paint refusal exist to prevent.
        for (const [dy, dx] of [[0, 0], [-1, 0], [1, 0], [0, -1], [0, 1]]) {
          const neighbour = canvas[y + dy]?.[x + dx];
          if (neighbour === undefined) continue;
          assert.doesNotMatch(
            neighbour,
            windowGlyph,
            `${label}: window glyph ${neighbour} at ${y + dy},${x + dx} touches the bezel at ${y},${x}\n${out}`
          );
        }
      }
    }
    assertWindowIdentity(out, label);
  }
});

test("map renderer: x-ray keeps a fully covered window and merges crossing outlines", () => {
  const out = renderWorkspaceMap(
    [{ displayIndex: 0, name: "Main", currentSpaceId: 1, visibleFrame: { x: 0, y: 0, w: 1000, h: 1000 } }],
    [
      // Front to back. [1] covers the whole display, so [2] sits entirely
      // underneath it, and [3] straddles [2]'s left and right edges.
      { wid: 1, app: "Cover", title: "front", frame: { x: 0, y: 0, w: 1000, h: 1000 }, spaceIds: [1], isOnScreen: true },
      { wid: 2, app: "Inner", title: "buried", frame: { x: 300, y: 300, w: 400, h: 400 }, spaceIds: [1], isOnScreen: true },
      { wid: 3, app: "Cross", title: "band", frame: { x: 200, y: 400, w: 600, h: 200 }, spaceIds: [1], isOnScreen: true },
    ],
    { width: 60, height: 20 },
  );
  const canvas = canvasOf(out).join("\n");

  // The regression this test exists for: a window with no uncovered pixel on
  // the real desktop is still a complete numbered rectangle on the map.
  assert.ok(canvas.includes("[2]"), `fully covered window lost its marker:\n${out}`);
  assert.ok(canvas.includes("[1]") && canvas.includes("[3]"), out);
  assert.match(canvas, /┼/u, `crossing outlines should merge into a junction:\n${out}`);
  // Interiors are never cleared, so no window is ever reported as painted out.
  assert.doesNotMatch(out, /\(occluded\)/u);
  assertWindowIdentity(out, "fully covered window");
});

test("map renderer: every window is marked, marked (small), or explained", () => {
  const display = { displayIndex: 0, name: "Main", currentSpaceId: 1, frame: { x: 0, y: 0, w: 1000, h: 600 } };
  const narrow = Array.from({ length: 12 }, (_unused, i) => ({
    wid: 100 + i,
    app: `App${i}`,
    title: "t",
    frame: { x: i * 80, y: 20, w: 60, h: 400 },
    spaceIds: [1],
    isOnScreen: true,
  }));

  const out = renderWorkspaceMap([display], narrow, { width: 40, height: 12 });
  const rows = assertWindowIdentity(out, "12 narrow windows at 40x12");
  assert.equal(rows.length, 12, out);
  // The invariant above is what matters, but a canvas that fell back to bare
  // numbers everywhere would satisfy it and still be hard to read.
  assert.ok(canvasOf(out).join("\n").match(/\[\d+\]/gu).length >= 8, out);

  // Sub-cell windows with two-digit indices: never a truncated numeral, since
  // "12" clipped to "1" is silently indistinguishable from window 1.
  const slivers = Array.from({ length: 14 }, (_unused, i) => ({
    wid: 200 + i,
    app: `S${i}`,
    title: "",
    frame: { x: i * 70, y: 20, w: 20, h: 60 },
    spaceIds: [1],
    isOnScreen: true,
  }));
  for (const [width, height] of [[44, 10], [32, 8]]) {
    assertWindowIdentity(
      renderWorkspaceMap([display], slivers, { width, height }),
      `14 slivers at ${width}x${height}`
    );
  }
});

test("map renderer: window painting never touches a display border", () => {
  const out = renderWorkspaceMap(
    [
      { displayIndex: 0, name: "A", currentSpaceId: 1, frame: { x: 0, y: 0, w: 1000, h: 600 } },
      { displayIndex: 1, name: "B", currentSpaceId: 2, frame: { x: 0, y: 600, w: 1000, h: 600 } },
      { displayIndex: 2, name: "C", currentSpaceId: 3, frame: { x: 0, y: 1200, w: 1000, h: 600 } },
    ],
    [
      // Each window is flush with its display's top-left corner and wider than
      // the display, so an unguarded painter would sit on the border.
      { wid: 1, app: "One", title: "a", frame: { x: 0, y: 0, w: 1200, h: 600 }, spaceIds: [1], isOnScreen: true },
      { wid: 2, app: "Two", title: "b", frame: { x: 0, y: 600, w: 1200, h: 600 }, spaceIds: [2], isOnScreen: true },
      { wid: 3, app: "Three", title: "c", frame: { x: 0, y: 1200, w: 1200, h: 600 }, spaceIds: [3], isOnScreen: true },
    ],
    { width: 60, height: 8 },
  );
  for (const line of canvasOf(out)) {
    assert.doesNotMatch(
      line[0],
      /[─│┌┐└┘├┤┬┴┼]/u,
      `a window glyph reached a display's left border:\n${out}`
    );
    // A display's horizontal rules carry only double line, corners, and the
    // display header text — never a window glyph.
    if (/^[╔╠╚]/u.test(line)) {
      assert.doesNotMatch(line, /[─│┌┐└┘├┤┬┴┼]/u, `a window glyph broke a display border:\n${out}`);
    }
  }
  assertWindowIdentity(out, "three stacked displays at 60x8");
});

test("map renderer: the live two-monitor fixture stays readable at every size", () => {
  const displays = [
    { displayIndex: 0, name: "AW3425DWM", currentSpaceId: 1, frame: { x: 0, y: 0, w: 3440, h: 1440 }, visibleFrame: { x: 0, y: 30, w: 3440, h: 1410 } },
    { displayIndex: 1, name: "U32J59x", currentSpaceId: 7, frame: { x: 3440, y: 235, w: 3840, h: 2160 }, visibleFrame: { x: 3440, y: 265, w: 3840, h: 2130 } },
  ];
  const windows = [
    { wid: 114, app: "ChatGPT", title: "ChatGPT", frame: { x: 593, y: 30, w: 2847, h: 1410 }, spaceIds: [1], isOnScreen: true },
    { wid: 208, app: "iTerm", title: "lattices", frame: { x: 0, y: 30, w: 1235, h: 1255 }, spaceIds: [1], isOnScreen: true },
    { wid: 4104, app: "Scout", title: "broker", frame: { x: 1244, y: 32, w: 1815, h: 1326 }, spaceIds: [1], isOnScreen: true },
    { wid: 4047, app: "System Settings", title: "Displays", frame: { x: 1868, y: 624, w: 723, h: 690 }, spaceIds: [1], isOnScreen: true },
    { wid: 3874, app: "Chrome", title: "API docs", frame: { x: 3440, y: 265, w: 1920, h: 2130 }, spaceIds: [7], isOnScreen: true },
    { wid: 4236, app: "Chrome", title: "PR review", frame: { x: 5360, y: 265, w: 1440, h: 1000 }, spaceIds: [7], isOnScreen: true },
    { wid: 146, app: "Simulator", title: "iPhone 16", frame: { x: 5783, y: 913, w: 447, h: 950 }, spaceIds: [7], isOnScreen: true },
  ];

  for (const [width, height] of [[120, 40], [80, 24], [60, 16], [40, 12], [32, 8]]) {
    const out = renderWorkspaceMap(displays, windows, { width, height });
    const canvas = canvasOf(out);
    const label = `live fixture at ${width}x${height}`;
    assert.ok(canvas.every((line) => line.length <= width), `${label}: canvas row overflows\n${out}`);

    // D1 is right of and lower than D0 — the two-adjacent-monitors claim.
    const d0Row = canvas.findIndex((line) => line.includes("D0"));
    const d1Row = canvas.findIndex((line) => line.includes("D1"));
    assert.ok(d0Row >= 0 && d1Row > d0Row, `${label}: D1 should start on a lower row than D0\n${out}`);
    assert.ok(
      canvas[d1Row].indexOf("D1") > canvas[d0Row].indexOf("D0"),
      `${label}: D1 should start right of D0\n${out}`
    );
    assertWindowIdentity(out, label);
  }

  // At the operator's working size every window keeps a full "[n]".
  const at80 = renderWorkspaceMap(displays, windows, { width: 80, height: 24 });
  const canvas80 = canvasOf(at80).join("\n");
  for (let index = 1; index <= windows.length; index++) {
    assert.ok(canvas80.includes(`[${index}]`), `80x24 lost marker [${index}]:\n${at80}`);
  }
});

test("map options: accept split and equals forms and reject malformed input", () => {
  assert.deepEqual(parseMapOptions(["--display", "1", "--width=80", "--height", "20", "--json"]), {
    display: 1,
    width: 80,
    height: 20,
    json: true,
  });
  assert.throws(() => parseMapOptions(["--width"]), /--width expects a non-negative integer/);
  assert.throws(() => parseMapOptions(["--display", "-1"]), /--display expects a non-negative integer/);
  assert.throws(() => parseMapOptions(["--bogus"]), /Unknown option: --bogus/);
});

test("map JSON snapshot: filters by display and current Space in front-to-back order", () => {
  const displays = [
    { displayIndex: 0, displayId: "main", currentSpaceId: 7, visibleFrame: { x: 0, y: 24, w: 1000, h: 776 } },
    { displayIndex: 1, displayId: "above", currentSpaceId: 8, spaces: [{ id: 8, index: 1, display: 1, isCurrent: true, rawOnly: "omit" }], visibleFrame: { x: -500, y: -900, w: 1200, h: 900 }, rawOnly: "omit" },
    { displayIndex: 2, displayId: "below", currentSpaceId: 9, visibleFrame: { x: 0, y: 800, w: 1000, h: 700 } },
  ];
  const windows = [
    { wid: 20, app: "Front", title: "above front", frame: { x: -400, y: -800, w: 600, h: 400 }, spaceIds: [8], isOnScreen: true, rawOnly: "omit" },
    { wid: 21, app: "Back", title: "above back", frame: { x: 100, y: -500, w: 500, h: 400 }, spaceIds: [8], isOnScreen: true },
    { wid: 22, app: "Hidden", title: "other Space", frame: { x: -400, y: -800, w: 600, h: 400 }, spaceIds: [99], isOnScreen: false },
    { wid: 23, app: "Below", title: "below", frame: { x: 0, y: 900, w: 500, h: 400 }, spaceIds: [9], isOnScreen: true },
  ];

  const snapshot = createWorkspaceMapSnapshot(displays, windows, { display: 1 });
  assert.deepEqual(snapshot.coordinateSystem, {
    origin: "top-left",
    units: "points",
    reference: "global-desktop",
  });
  assert.equal(snapshot.version, 1);
  assert.equal(snapshot.displays.length, 1);
  assert.equal(snapshot.displays[0].displayId, "above");
  assert.deepEqual(snapshot.displays[0].spaces, [{ id: 8, index: 1, display: 1, isCurrent: true }]);
  assert.equal("rawOnly" in snapshot.displays[0], false);
  assert.equal("rawOnly" in snapshot.displays[0].spaces[0], false);
  assert.equal("rawOnly" in snapshot.displays[0].windows[0], false);
  assert.deepEqual(snapshot.displays[0].windows.map(({ wid, zIndex }) => ({ wid, zIndex })), [
    { wid: 20, zIndex: 0 },
    { wid: 21, zIndex: 1 },
  ]);
});

test("map --help: works without a running daemon", () => {
  const out = runCli(["map", "--help"]);
  assert.match(out, /Render the current Space/);
  assert.match(out, /--display <n>/);
});

test("map JSON guard: flags displays whose daemon payload has no geometry", () => {
  const withGeometry = { displayIndex: 0, currentSpaceId: 1, visibleFrame: { x: 0, y: 0, w: 1000, h: 800 } };
  const legacy = { displayIndex: 1, currentSpaceId: 2 };
  const zeroed = { displayIndex: 2, currentSpaceId: 3, frame: { x: 0, y: 0, w: 0, h: 0 } };

  assert.deepEqual(displaysMissingGeometry([withGeometry]), []);
  assert.deepEqual(
    displaysMissingGeometry([withGeometry, legacy, zeroed]).map((d) => d.displayIndex),
    [1, 2],
  );
  // The --display filter scopes the guard the same way it scopes the snapshot.
  assert.deepEqual(displaysMissingGeometry([withGeometry, legacy], { display: 0 }), []);
  assert.deepEqual(
    displaysMissingGeometry([withGeometry, legacy], { display: 1 }).map((d) => d.displayIndex),
    [1],
  );
});

// ── window move / place ──────────────────────────────────────────────

test("window move parsing: split and equals flags, dry-run, json", () => {
  assert.deepEqual(parseWindowMoveArgs(["4182", "--display", "1"]), {
    wid: 4182, display: 1, placement: undefined, json: false, dryRun: false,
  });
  assert.deepEqual(parseWindowMoveArgs(["4182", "--display=1", "--placement=right", "--json", "--dry-run"]), {
    wid: 4182, display: 1, placement: "right", json: true, dryRun: true,
  });
  // Alias and grid slots normalize to what the daemon accepts.
  assert.equal(parseWindowMoveArgs(["7", "--placement", "left-half"]).placement, "left");
  assert.equal(parseWindowMoveArgs(["7", "--placement", "grid:4x4:0,0-1,1"]).placement, "grid:4x4:0,0-1,1");
  assert.equal(parseWindowMoveArgs(["7", "--placement", "2x2:1,1"]).placement, "2x2:1,1");
});

test("window move parsing: malformed wid is an error, never a fallback", () => {
  assert.throws(() => parseWindowMoveArgs(["--display", "1"]), /window id is required/i);
  assert.throws(() => parseWindowMoveArgs(["abc", "--display", "1"]), /Invalid window id: abc/);
  assert.throws(() => parseWindowMoveArgs(["-4182", "--display", "1"]), /Invalid window id: -4182/);
  assert.throws(() => parseWindowMoveArgs(["4182.5", "--display", "1"]), /Invalid window id/);
  assert.throws(() => parseWindowMoveArgs(["0", "--display", "1"]), /Invalid window id/);
});

test("window move parsing: rejects incomplete or unknown input", () => {
  assert.throws(() => parseWindowMoveArgs(["4182"]), /requires --display <n> and\/or --placement/);
  assert.throws(() => parseWindowMoveArgs(["4182", "--display"]), /--display expects a value/);
  assert.throws(() => parseWindowMoveArgs(["4182", "--display", "x"]), /--display expects a non-negative/);
  assert.throws(() => parseWindowMoveArgs(["4182", "--display", "1", "--placement", "diagonal"]), /Unknown placement slot: diagonal/);
  assert.throws(() => parseWindowMoveArgs(["4182", "--display", "1", "--space", "3"]), /Unknown option: --space/);
  assert.throws(() => parseWindowMoveArgs(["4182", "extra", "--display", "1"]), /Unexpected argument: extra/);
});

test("window place parsing: wid plus slot with optional display", () => {
  assert.deepEqual(parseWindowPlaceArgs(["4182", "top-left"]), {
    wid: 4182, display: undefined, placement: "top-left", json: false, dryRun: false,
  });
  assert.equal(parseWindowPlaceArgs(["4182", "MAX", "--display=1"]).placement, "maximize");
  assert.throws(() => parseWindowPlaceArgs(["4182"]), /requires a slot/);
  assert.throws(() => parseWindowPlaceArgs(["nope", "left"]), /Invalid window id: nope/);
  assert.throws(() => parseWindowPlaceArgs(["4182", "sideways"]), /Unknown placement slot: sideways/);
  assert.throws(() => parseWindowPlaceArgs(["4182", "left", "--placement", "right"]), /Unknown option: --placement/);
});

test("placement normalization: named slots, aliases, and grid forms", () => {
  assert.equal(normalizePlacement("bottom-right"), "bottom-right");
  assert.equal(normalizePlacement("Top_Center Third"), "top-center-third");
  assert.equal(normalizePlacement("max"), "maximize");
  assert.equal(normalizePlacement("upper-third"), "top-third");
  assert.equal(normalizePlacement("grid:4.5"), "grid:4.5");
  assert.equal(normalizePlacement("grid:3x2:2,0"), "grid:3x2:2,0");
  assert.equal(normalizePlacement("banana"), undefined);
  assert.equal(normalizePlacement("4x4"), undefined);
});

test("window move receipt rendering: ok, planned, blocked, failed", () => {
  const base = {
    app: "Safari",
    wid: 4182,
    display: { name: "U32J59x" },
    mutations: [{ from: { x: 0, y: 0, w: 800, h: 600 }, to: { x: 3440, y: 265, w: 800, h: 600 }, after: { x: 3440, y: 265, w: 800, h: 600 } }],
    receiptId: "exec_1",
  };
  const ok = describeMoveReceipt({ ...base, status: "ok", verified: true });
  assert.match(ok, /Moved Safari \(wid:4182\) on U32J59x/);
  assert.match(ok, /800×600 @ 0,0 → 800×600 @ 3440,265/);
  assert.match(ok, /verified/);
  assert.match(ok, /receipt exec_1/);

  assert.match(describeMoveReceipt({ ...base, status: "planned" }), /Planned .*dry run, not executed/);
  const blocked = describeMoveReceipt({ ...base, status: "blocked", blockedReason: "accessibility-not-trusted", requiredPermissions: ["accessibility"] });
  assert.match(blocked, /Blocked Safari/);
  assert.match(blocked, /accessibility-not-trusted/);
  assert.match(describeMoveReceipt({ ...base, status: "failed" }), /did not verify/);
});

test("window move: malformed wid exits non-zero without touching the daemon", () => {
  const { status, stdout, stderr } = runCliRaw(["window", "move", "abc", "--display", "1"]);
  const combined = `${stdout}\n${stderr}`;
  assert.equal(status, 1, `expected exit 1, got ${status}: ${combined}`);
  assert.match(combined, /Invalid window id: abc/);
  assert.doesNotMatch(combined, /Daemon not running/);
});

test("window move --help: lists slots without a running daemon", () => {
  const out = runCli(["window", "move", "--help"]);
  assert.match(out, /lats window move <wid> --display <n>/);
  assert.match(out, /grid:CxR:c,r/);
  assert.match(out, /bottom-right/);
});

// ── layer ────────────────────────────────────────────────────────────

test("layer slots: layers fill the pad round its centre", () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 7].map(padSlot), [1, 2, 3, 4, 6, 7, 8, 9]);
  assert.equal(padSlot(8), undefined);
});

test("layer target: a digit is a pad slot, anything else a name", () => {
  assert.deepEqual(layerTarget("1"), { index: 0, slot: 1 });
  assert.deepEqual(layerTarget("6"), { index: 4, slot: 6 });
  assert.deepEqual(layerTarget("9"), { index: 7, slot: 9 });
  assert.deepEqual(layerTarget("web"), { name: "web" });
  assert.match(layerTarget("5").error, /centre/);
  assert.match(layerTarget("0").error, /1-4 and 6-9/);
  assert.match(layerTarget("12").error, /1-4 and 6-9/);
});

test("layer list: slot digits and resolver window counts", () => {
  const layers = [
    { index: 0, label: "Web", projectCount: 3 },
    { index: 4, label: "Docs", projectCount: 1 },
    { index: 8, label: "Spare", projectCount: 2 },
  ];
  const counts = layerWindowCounts({
    layers: [
      { index: 0, entries: [{ windows: [{}, {}] }, { windows: [{}] }] },
      { index: 4, entries: [{ windows: [] }] },
      { index: 8, entries: [{ windows: [{}] }] },
    ],
  });
  assert.deepEqual([...counts], [[0, 3], [4, 0], [8, 1]]);
  const lines = layerListLines(layers, 4, counts).map((line) => line.replace(/\x1b\[[0-9;]*m/g, ""));
  assert.deepEqual(lines, [
    "  [1] Web    3 windows",
    "  [6] Docs   No windows  ● active",
    "  [·] Spare  1 window",
  ]);
  assert.match(layerListLines(layers, 0)[0], /3 entries/);
});

test("layer list: exiting removes the active mark and keeps configured layers", () => {
  const layers = [
    { index: 0, label: "Web", projectCount: 3 },
    { index: 4, label: "Docs", projectCount: 1 },
  ];
  const activeLines = layerListLines(layers, 4);
  const exitedLines = layerListLines(layers, null);
  assert.deepEqual(exitedLines, [
    "  [1] Web   3 entries",
    "  [6] Docs  1 entry",
  ]);
  assert.equal(activeLines[0], exitedLines[0]);
  assert.equal(activeLines[1].slice(0, exitedLines[1].length), exitedLines[1]);
  assert.ok(exitedLines.every((line) => !line.includes("active")));
});

test("layer switch: the pad's centre fails without touching the daemon", () => {
  const { status, stdout, stderr } = runCliRaw(["layer", "5"]);
  const combined = `${stdout}\n${stderr}`;
  assert.equal(status, 1, `expected exit 1, got ${status}: ${combined}`);
  assert.match(combined, /pad's centre/);
  assert.doesNotMatch(combined, /Daemon not running|Switched/);
});

// ── search --deep ────────────────────────────────────────────────────

test("search --deep: does not crash when daemon is running", async (t) => {
  if (!daemonRunning) {
    t.skip("daemon not running — start with: lats app");
    return;
  }
  const { status, stdout, stderr } = runCliRaw(["search", "foo", "--deep"]);
  const combined = `${stdout}\n${stderr}`;
  assert.equal(status, 0, `expected exit 0, got ${status}: ${combined}`);
});

test("search --deep: exits non-zero with friendly message when daemon is down", async (t) => {
  if (daemonRunning) {
    t.skip("daemon is running — stop daemon to exercise daemon-down path");
    return;
  }
  const { status, stdout, stderr } = runCliRaw(["search", "foo", "--deep"]);
  const combined = `${stdout}\n${stderr}`.trim();
  assert.equal(status, 1, `expected exit 1, got ${status}: ${combined}`);
  assert.match(combined, /Daemon not running/i);
  assert.match(combined, /(?:lats|lattices) app/i);
});
