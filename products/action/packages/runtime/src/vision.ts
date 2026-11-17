import { execFile } from "node:child_process";
import { access, mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import type { RuntimeArtifact } from "@action/protocol";

const execFileAsync = promisify(execFile);

export type VisionProviderId = "moondream";

export interface OCRTextBlock {
  text: string;
  confidence: number;
  frame: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
}

export interface OCRResult {
  imagePath: string;
  imageWidth: number;
  imageHeight: number;
  blockCount: number;
  fullText: string;
  blocks: OCRTextBlock[];
}

export interface VisionAnalysisResult {
  available: boolean;
  provider: VisionProviderId;
  summary?: string;
  answer?: string;
  parsed?: Record<string, unknown>;
  error?: string;
  imagePath: string;
  model?: string;
  device?: string;
  timingMs?: Record<string, number>;
}

function repoRootFromRuntime(): string {
  const runtimeDir = dirname(fileURLToPath(import.meta.url));
  return resolve(runtimeDir, "../../..");
}

function defaultVisionPrompt(): string {
  return [
    "Analyze this macOS screenshot for automation.",
    "Describe visible UI elements, buttons, dialogs, headings, and any error messages.",
    "Return compact JSON with keys: summary, elements, buttons, errors.",
    "Use top-left screen coordinates when mentioning positions.",
  ].join(" ");
}

export function resolveVisionProvider(
  requested?: VisionProviderId,
): VisionProviderId {
  // Moondream, running locally, is the only provider.
  return requested ?? "moondream";
}

export function searchOCRText(result: OCRResult, query: string): OCRTextBlock[] {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    return [];
  }

  return result.blocks.filter((block) => block.text.toLowerCase().includes(needle));
}

export async function ocrScreenshot(
  imagePath: string,
  outputPath: string,
  nativeHostPath = "native/engine/scripts/run-app-host.sh",
): Promise<{ artifact: RuntimeArtifact; result: OCRResult }> {
  await mkdir(dirname(outputPath), { recursive: true });
  const { stdout } = await execFileAsync(nativeHostPath, [
    "ocr-screenshot",
    "--input",
    imagePath,
    "--output",
    outputPath,
  ]);
  const result = JSON.parse(stdout) as OCRResult;
  await writeFile(outputPath, JSON.stringify(result, null, 2));

  return {
    result,
    artifact: {
      kind: "ocr-snapshot",
      path: outputPath,
      metadata: {
        imagePath,
        blockCount: result.blockCount,
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
      },
    },
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function resolveMoondreamPython(): Promise<string | undefined> {
  const candidates = [
    process.env.ACTION_MOONDREAM_PYTHON,
    process.env.MOONDREAM_PYTHON,
    join(homedir(), "dev/moondream-local-poc/.venv/bin/python"),
  ].filter((value): value is string => Boolean(value));

  for (const candidate of candidates) {
    if (await pathExists(candidate)) {
      try {
        await execFileAsync(candidate, ["-c", "import torch, transformers"]);
        return candidate;
      } catch {
        continue;
      }
    }
  }

  return undefined;
}

async function analyzeWithMoondream(
  imagePath: string,
  prompt: string,
  outputPath: string,
  scriptPath: string,
): Promise<VisionAnalysisResult> {
  const python = await resolveMoondreamPython();
  if (!python) {
    return {
      available: false,
      provider: "moondream",
      imagePath,
      error: "Moondream python environment not configured. Set ACTION_MOONDREAM_PYTHON to a venv with torch and transformers.",
    };
  }

  const env = {
    ...process.env,
    MOONDREAM_PROMPT: prompt,
  };

  const { stdout } = await execFileAsync(
    python,
    [scriptPath, imagePath],
    { env, maxBuffer: 10 * 1024 * 1024 },
  );

  const result = JSON.parse(stdout) as VisionAnalysisResult;
  return {
    ...result,
    available: result.available ?? true,
    provider: "moondream",
    imagePath,
    summary: typeof result.parsed?.summary === "string"
      ? result.parsed.summary
      : result.answer?.slice(0, 500),
  };
}

export async function analyzeScreenshotVision(
  imagePath: string,
  options: {
    prompt?: string;
    outputPath?: string;
    scriptPath?: string;
    provider?: VisionProviderId;
  } = {},
): Promise<{ artifact: RuntimeArtifact; result: VisionAnalysisResult }> {
  const outputPath = options.outputPath
    ?? resolve(dirname(imagePath), "vision-analysis.json");
  const prompt = options.prompt
    ?? process.env.ACTION_VISION_PROMPT
    ?? defaultVisionPrompt();
  const provider = resolveVisionProvider(options.provider);
  const scriptPath = options.scriptPath
    ?? resolve(repoRootFromRuntime(), "native/engine/scripts/moondream-verify-screenshot.py");

  let result: VisionAnalysisResult;
  try {
    result = await analyzeWithMoondream(imagePath, prompt, outputPath, scriptPath);
  } catch (error) {
    result = {
      available: false,
      provider,
      imagePath,
      error: error instanceof Error ? error.message : String(error),
    };
  }

  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, JSON.stringify(result, null, 2));

  return {
    result,
    artifact: {
      kind: "vision-analysis",
      path: outputPath,
      metadata: {
        imagePath,
        available: result.available,
        provider: result.provider,
        model: result.model,
      },
    },
  };
}