#!/usr/bin/env bun

import { mkdir, readFile, writeFile, appendFile } from "node:fs/promises";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { analyzeScreenshotVision } from "../../runtime/src/vision.ts";
import { port } from "./mira-chrome.mjs";
import { createMjClient } from "./mj-orchestrator.mjs";

const root = fileURLToPath(new URL("../../..", import.meta.url));
const cdpScript = join(root, "native/engine/scripts/mira-midjourney-cdp.mjs");
const debugPort = String(port);
const { runCdp } = createMjClient({ cdpScript, debugPort, background: true });
const logoRoot = join(root, "assets/brand/project-logos");
const outputDir = join(logoRoot, "midjourney");
const reviewsDir = join(logoRoot, "reviews");
const statePath = join(logoRoot, "analyze-state.json");
const analysesPath = join(reviewsDir, "analyses.json");
const round4Path = join(logoRoot, "directions-round4.json");
const logPath = join(logoRoot, "analyze.log");
const promptsFile = join(logoRoot, "midjourney-prompts.txt");
const batchFile = join(logoRoot, "batch-prompts.txt");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const force = args.includes("--force");
const skipCollect = args.includes("--skip-collect");
const skipAnalyze = args.includes("--skip-analyze");
const skipRefine = args.includes("--skip-refine");
const refineThreshold = Number(argValue("--refine-threshold") || process.env.ACTION_LOGO_REFINE_THRESHOLD || "7");
const only = args.includes("--only")
  ? args[args.indexOf("--only") + 1]?.split(",").map((entry) => entry.trim()).filter(Boolean)
  : undefined;

function argValue(flag) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

async function loadJson(path, fallback) {
  if (!existsSync(path)) return fallback;
  return JSON.parse(await readFile(path, "utf8"));
}

async function saveJson(path, data) {
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, `${JSON.stringify(data, null, 2)}\n`);
}

async function logLine(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  await appendFile(logPath, line).catch(() => {});
  console.log(message);
}

function promptNeedleFor(prompt) {
  const appIcon = prompt.match(/app icon of (?:an |a |the )?([^,.]{8,64})/i);
  if (appIcon) return appIcon[1].trim().toLowerCase().split(/\s+/).slice(0, 4).join(" ");
  if (/flat vector app icon/i.test(prompt)) return "flat vector app icon";
  return "";
}

function parsePromptBlocks(text) {
  const blocks = [];
  let current;
  for (const line of text.split("\n")) {
    const heading = line.match(/^(\d{2}(?:-[\w-]+)?)\s+(.+)$/);
    if (heading) {
      if (current?.prompt) blocks.push(current);
      current = { id: heading[1], title: heading[2], prompt: "" };
      continue;
    }
    if (!current) continue;
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || /^Action (brand|character)/i.test(trimmed)) continue;
    current.prompt = current.prompt ? `${current.prompt} ${trimmed}` : trimmed;
  }
  if (current?.prompt) blocks.push(current);
  return blocks;
}

async function loadAllPrompts() {
  const files = [promptsFile, batchFile];
  const byId = new Map();
  for (const path of files) {
    if (!existsSync(path)) continue;
    for (const block of parsePromptBlocks(await readFile(path, "utf8"))) {
      byId.set(block.id, block);
    }
  }
  const manifest = await loadJson(join(outputDir, "manifest.json"), []);
  for (const entry of manifest) {
    if (!entry.id || !entry.prompt) continue;
    if (!byId.has(entry.id)) {
      byId.set(entry.id, { id: entry.id, title: entry.title || entry.id, prompt: entry.prompt });
    }
  }
  return [...byId.values()];
}

async function loadDirectionPool() {
  const pools = ["directions.json", "directions-round2.json", "directions-round3.json", "directions-round4.json"];
  const merged = [];
  for (const name of pools) {
    const path = join(logoRoot, name);
    if (!existsSync(path)) continue;
    merged.push(...await loadJson(path, []));
  }
  return merged;
}

function directionIdFromEntryId(entryId) {
  const match = entryId.match(/^\d{2}-(.+)$/);
  return match?.[1] ?? entryId;
}

function projectBriefFor(briefs, projectName) {
  const needle = projectName.trim().toLowerCase();
  return briefs.projects?.find((project) =>
    project.id === needle || project.name.toLowerCase() === needle,
  );
}

function tilesOnDisk(entryId) {
  try {
    return readdirSync(outputDir)
      .filter((name) => name.startsWith(`${entryId}-`) && name.endsWith(".webp"))
      .sort();
  } catch {
    return [];
  }
}

function averageScore(scores) {
  const values = Object.values(scores || {}).filter((value) => typeof value === "number");
  if (values.length === 0) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function buildTilePrompt({ brief, direction, promptBlock, tileIndex }) {
  const avoid = [...new Set([...(direction?.avoid ?? []), ...(brief?.avoid ?? [])])];
  return [
    "You are a brand design critic reviewing one Midjourney app icon tile from a logo sprint.",
    `Tile index: ${tileIndex}`,
    brief ? `Project: ${brief.name} — ${brief.category}` : "",
    brief ? `Product truth: ${brief.truth}` : "",
    direction ? `Direction: ${direction.title}` : "",
    direction ? `Rationale: ${direction.rationale}` : "",
    direction ? `Keywords: ${(direction.keywords || []).join(", ")}` : "",
    avoid.length ? `Must avoid: ${avoid.join(", ")}` : "",
    promptBlock ? `Original prompt: ${promptBlock.prompt}` : "",
    "",
    "Score 0-10 on directionFit, brandFit, simplicity, smallSizeReadability, flatVectorFidelity.",
    "Return strict JSON only:",
    "{",
    '  "summary": "one sentence",',
    '  "scores": { "directionFit": 0, "brandFit": 0, "simplicity": 0, "smallSizeReadability": 0, "flatVectorFidelity": 0 },',
    '  "strengths": ["..."],',
    '  "issues": ["..."],',
    '  "hasText": false,',
    '  "hasGradient": false,',
    '  "hasPhotorealism": false,',
    '  "verdict": "advance" | "refine" | "reject"',
    "}",
  ].filter(Boolean).join("\n");
}

function buildRefinementPrompt({ brief, direction, promptBlock, review }) {
  const winner = review.tiles.find((tile) => tile.index === review.winnerIndex);
  return [
    "You are refining a Midjourney app icon prompt after reviewing generated tiles.",
    brief ? `Project: ${brief.name}` : "",
    direction ? `Direction: ${direction.title} — ${direction.rationale}` : "",
    promptBlock ? `Original prompt: ${promptBlock.prompt}` : "",
    winner ? `Best tile summary: ${winner.summary}` : "",
    winner ? `Best tile issues: ${(winner.issues || []).join("; ")}` : "",
    `Aggregate issues across tiles: ${(review.aggregateIssues || []).join("; ")}`,
    "",
    "Write one improved Midjourney prompt that keeps the concept but fixes the issues.",
    "Keep --ar 1:1 --style raw and a strong --no clause. No text, mockup, photorealism, gradient.",
    "Return strict JSON only:",
    "{",
    '  "title": "short direction title",',
    '  "rationale": "why this refinement should work",',
    '  "mjPrompt": "full midjourney prompt string",',
    '  "keywords": ["..."],',
    '  "avoid": ["..."]',
    "}",
  ].filter(Boolean).join("\n");
}

function parseVisionPayload(result) {
  if (result.parsed && typeof result.parsed === "object") {
    return result.parsed;
  }
  const text = result.answer || result.summary || "";
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1) return {};
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return { summary: text.slice(0, 500) };
  }
}

async function downloadTile(url, destPath) {
  const response = await fetch(url.replace("_640_", "_1024_"));
  if (!response.ok) {
    throw new Error(`Download failed ${response.status}`);
  }
  await writeFile(destPath, Buffer.from(await response.arrayBuffer()));
}

async function loadManifest() {
  return await loadJson(join(outputDir, "manifest.json"), []);
}

async function saveManifest(manifest) {
  await saveJson(join(outputDir, "manifest.json"), manifest);
}

async function collectEntryBacklog(block) {
  const needle = promptNeedleFor(block.prompt);
  if (!needle) {
    return { ok: false, error: `no needle for ${block.id}` };
  }

  await logLine(`harvest-find ${block.id} (needle: ${needle})`);
  const found = runCdp("harvest-find", [
    "--expected-prompt-substring", needle,
    "--min-fresh", "4",
    "--max-scrolls", "80",
  ], { soft: true });

  if (!found.ok || !found.data?.ok) {
    const reason = found.error || found.data?.reason || "harvest-find failed";
    return { ok: false, error: reason };
  }

  const slug = block.title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  const picks = (found.data.fresh || [])
    .filter((result) => result.imageUrl && !/\/video\//i.test(result.imageUrl))
    .slice(0, 4);
  const saved = [];

  for (const [index, result] of picks.entries()) {
    const filename = `${block.id}-${slug}-${index + 1}.webp`;
    const destPath = join(outputDir, filename);
    try {
      await downloadTile(result.imageUrl, destPath);
      saved.push({ filename, href: result.href, imageUrl: result.imageUrl });
      await logLine(`saved ${filename}`);
    } catch (error) {
      await logLine(`download failed ${filename}: ${error.message || error}`);
    }
  }

  if (saved.length === 0) {
    return { ok: false, error: `no tiles saved for ${block.id}` };
  }

  const manifest = await loadManifest();
  const record = {
    id: block.id,
    title: block.title,
    prompt: block.prompt,
    status: saved.length >= 4 ? "ok" : "partial",
    outcome: saved.length >= 4 ? "success" : "partial",
    attempts: 1,
    saved,
    waited: false,
    matchedJobId: found.data.jobId,
    collectedAt: new Date().toISOString(),
  };
  const index = manifest.findIndex((entry) => entry.id === block.id);
  if (index >= 0) manifest[index] = { ...manifest[index], ...record };
  else manifest.push(record);
  await saveManifest(manifest);
  return { ok: true, saved, jobId: found.data.jobId };
}

async function runCollect(promptBlocks) {
  const candidates = promptBlocks.filter((block) => {
    if (only?.length && !only.some((needle) => block.id === needle || block.id.includes(needle))) {
      return false;
    }
    return tilesOnDisk(block.id).length < 4;
  });

  if (candidates.length === 0) {
    await logLine("collect: all matched entries already have tiles on disk");
    return { ok: true, skipped: true };
  }

  if (dryRun) {
    await logLine(`dry-run: would harvest-find ${candidates.length} entr(y/ies)`);
    return { ok: true, dryRun: true };
  }

  let okCount = 0;
  let failCount = 0;
  for (const block of candidates) {
    const outcome = await collectEntryBacklog(block);
    if (outcome.ok) okCount += 1;
    else {
      failCount += 1;
      await logLine(`collect failed ${block.id}: ${outcome.error}`);
    }
  }

  await logLine(`collect done: ok=${okCount}, failed=${failCount}`);
  return failCount === 0 ? { ok: true } : { ok: false, error: `${failCount} failed` };
}

async function analyzeEntry({
  entryId,
  promptBlock,
  direction,
  brief,
  state,
}) {
  const tiles = tilesOnDisk(entryId);
  if (tiles.length === 0) {
    return null;
  }

  const prior = state.analyzed?.[entryId];
  if (prior && !force && prior.tileCount === tiles.length) {
    await logLine(`skip analyze ${entryId}: already reviewed ${tiles.length} tile(s)`);
    return prior;
  }

  const tileReviews = [];
  for (const [index, filename] of tiles.entries()) {
    const imagePath = join(outputDir, filename);
    const prompt = buildTilePrompt({
      brief,
      direction,
      promptBlock,
      tileIndex: index + 1,
    });

    if (dryRun) {
      tileReviews.push({
        index: index + 1,
        filename,
        summary: "dry-run",
        scores: {},
        verdict: "refine",
      });
      continue;
    }

    const reviewPath = join(reviewsDir, entryId, `tile-${index + 1}.json`);
    const { result } = await analyzeScreenshotVision(imagePath, {
      prompt,
      outputPath: reviewPath,
    });

    if (!result.available) {
      await logLine(`vision failed ${entryId} tile ${index + 1}: ${result.error}`);
      continue;
    }

    const parsed = parseVisionPayload(result);
    tileReviews.push({
      index: index + 1,
      filename,
      imagePath,
      summary: parsed.summary || result.summary,
      scores: parsed.scores || {},
      strengths: parsed.strengths || [],
      issues: parsed.issues || [],
      flags: {
        hasText: parsed.hasText,
        hasGradient: parsed.hasGradient,
        hasPhotorealism: parsed.hasPhotorealism,
      },
      verdict: parsed.verdict || "refine",
      provider: result.provider,
      model: result.model,
    });
    await logLine(`analyzed ${entryId} tile ${index + 1}: ${parsed.verdict || "refine"} (${averageScore(parsed.scores).toFixed(1)})`);
  }

  if (tileReviews.length === 0) {
    return null;
  }

  const ranked = [...tileReviews].sort((left, right) => averageScore(right.scores) - averageScore(left.scores));
  const winner = ranked[0];
  const aggregateIssues = [...new Set(tileReviews.flatMap((tile) => tile.issues || []))];

  const review = {
    entryId,
    directionId: direction?.directionId ?? directionIdFromEntryId(entryId),
    project: direction?.project ?? promptBlock?.title?.split("—")?.[0]?.trim(),
    title: direction?.title ?? promptBlock?.title,
    prompt: promptBlock?.prompt,
    tileCount: tiles.length,
    winnerIndex: winner.index,
    winnerFilename: winner.filename,
    winnerScore: averageScore(winner.scores),
    tiles: tileReviews,
    aggregateIssues,
    verdict: averageScore(winner.scores) >= refineThreshold && winner.verdict === "advance" ? "advance" : "refine",
    analyzedAt: new Date().toISOString(),
  };

  if (!dryRun) {
    await saveJson(join(reviewsDir, `${entryId}.json`), review);
  }
  state.analyzed = state.analyzed || {};
  state.analyzed[entryId] = {
    entryId,
    tileCount: review.tileCount,
    winnerIndex: review.winnerIndex,
    winnerScore: review.winnerScore,
    verdict: review.verdict,
    analyzedAt: review.analyzedAt,
  };
  return review;
}

async function refineFromReview({ review, direction, brief, promptBlock, round4, state }) {
  if (!review || review.verdict === "advance") {
    return null;
  }

  const directionId = `${review.directionId}-refine`;
  if (round4.some((entry) => entry.directionId === directionId)) {
    await logLine(`skip refine ${review.entryId}: ${directionId} already exists`);
    return null;
  }
  if (state.refined?.includes(review.entryId) && !force) {
    return null;
  }

  let refinement;
  if (dryRun) {
    refinement = {
      title: `${direction?.title || review.title} Refine`,
      rationale: "dry-run refinement",
      mjPrompt: promptBlock?.prompt || "",
      keywords: direction?.keywords || [],
      avoid: direction?.avoid || [],
    };
  } else if (review.winnerFilename) {
    const winnerPath = join(outputDir, review.winnerFilename);
    const prompt = buildRefinementPrompt({ brief, direction, promptBlock, review });
    const { result } = await analyzeScreenshotVision(winnerPath, {
      prompt,
      outputPath: join(reviewsDir, review.entryId, "refinement.json"),
    });
    refinement = parseVisionPayload(result);
    if (!refinement.mjPrompt) {
      await logLine(`refine ${review.entryId}: no mjPrompt in vision response`);
      return null;
    }
  } else {
    return null;
  }

  const entry = {
    project: direction?.project || review.project,
    directionId,
    parentDirectionId: review.directionId,
    parentEntryId: review.entryId,
    title: refinement.title || `${direction?.title || review.title} Refine`,
    rationale: refinement.rationale || `Refinement after analyzing ${review.entryId}`,
    keywords: refinement.keywords || direction?.keywords || [],
    avoid: refinement.avoid || direction?.avoid || [],
    mjPrompt: refinement.mjPrompt,
    source: "logo-analyze-loop",
    winnerScore: review.winnerScore,
    createdAt: new Date().toISOString(),
  };

  round4.push(entry);
  state.refined = state.refined || [];
  state.refined.push(review.entryId);
  await logLine(`refinement queued: ${directionId} (from ${review.entryId})`);
  return entry;
}

function visionConfigured() {
  if (process.env.ACTION_VISION_PROVIDER === "moondream") return true;
  if (process.env.ACTION_MOONDREAM_PYTHON) return true;
  return false;
}

async function main() {
  await mkdir(reviewsDir, { recursive: true });

  if (!dryRun && !skipAnalyze && !visionConfigured()) {
    throw new Error(
      "Moondream not configured. Set ACTION_MOONDREAM_PYTHON to a Python with moondream installed, then rerun bun run logo:analyze",
    );
  }

  let state = await loadJson(statePath, { analyzed: {}, refined: [] });
  const briefs = await loadJson(join(logoRoot, "briefs.json"), { projects: [] });
  const directions = await loadDirectionPool();
  const directionById = new Map(directions.map((direction) => [direction.directionId, direction]));
  const promptBlocks = await loadAllPrompts();

  const entries = promptBlocks.filter((block) => {
    if (only?.length) {
      return only.some((needle) => block.id === needle || block.id.includes(needle));
    }
    return true;
  });

  await logLine(`logo analyze loop (${entries.length} entries, dryRun=${dryRun})`);

  if (!skipCollect) {
    await runCollect(entries);
  }

  const reviews = [];
  if (!skipAnalyze) {
    for (const block of entries) {
      const tiles = tilesOnDisk(block.id);
      if (tiles.length === 0) continue;

      const directionId = directionIdFromEntryId(block.id);
      const direction = directionById.get(directionId);
      const brief = projectBriefFor(briefs, direction?.project || block.title?.split("—")?.[0] || "");
      const review = await analyzeEntry({
        entryId: block.id,
        promptBlock: block,
        direction,
        brief,
        state,
      });
      if (review) reviews.push(review);
    }
    await saveJson(statePath, state);
  } else {
    for (const block of entries) {
      const saved = await loadJson(join(reviewsDir, `${block.id}.json`), null);
      if (saved) reviews.push(saved);
    }
  }

  const summarize = (list) => list.map((review) => ({
    entryId: review.entryId,
    directionId: review.directionId,
    project: review.project,
    title: review.title,
    winnerIndex: review.winnerIndex,
    winnerScore: review.winnerScore,
    verdict: review.verdict,
    winnerFilename: review.winnerFilename,
    aggregateIssues: review.aggregateIssues,
  }));

  const prior = await loadJson(analysesPath, { reviews: [] });
  const mergedById = new Map((prior.reviews || []).map((review) => [review.entryId, review]));
  for (const review of reviews) {
    mergedById.set(review.entryId, summarize([review])[0]);
  }

  // Also pick up any per-entry review files not in this run (e.g. --skip-analyze collect-only).
  if (existsSync(reviewsDir)) {
    for (const name of readdirSync(reviewsDir)) {
      if (!name.endsWith(".json") || name === "analyses.json") continue;
      const saved = await loadJson(join(reviewsDir, name), null);
      if (saved?.entryId && !mergedById.has(saved.entryId)) {
        mergedById.set(saved.entryId, summarize([saved])[0]);
      }
    }
  }

  const mergedReviews = [...mergedById.values()];
  const aggregate = {
    updatedAt: new Date().toISOString(),
    entryCount: mergedReviews.length,
    advance: mergedReviews.filter((review) => review.verdict === "advance").length,
    refine: mergedReviews.filter((review) => review.verdict === "refine").length,
    reviews: mergedReviews,
  };
  await saveJson(analysesPath, aggregate);

  if (!skipRefine && !dryRun && reviews.length > 0) {
    const round4 = await loadJson(round4Path, []);
    for (const review of reviews) {
      const direction = directionById.get(review.directionId);
      const brief = projectBriefFor(briefs, review.project || "");
      const promptBlock = promptBlocks.find((block) => block.id === review.entryId);
      await refineFromReview({
        review,
        direction,
        brief,
        promptBlock,
        round4,
        state,
      });
    }
    await saveJson(round4Path, round4);
    await saveJson(statePath, state);
  }

  await logLine(`done: ${reviews.length} review(s), advance=${aggregate.advance}, refine=${aggregate.refine}`);
  await logLine(`artifacts → ${reviewsDir}`);
}

main().catch(async (error) => {
  await logLine(`fatal: ${error.message || String(error)}`);
  process.exitCode = 1;
});