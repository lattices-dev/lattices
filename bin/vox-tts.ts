/**
 * Hudson / Vox on-device TTS client for Lattices workers.
 *
 * Speaks through the embedded Lattices voice runtime (Kokoro via mlx-audio by default).
 */

import { constants, closeSync, fstatSync, openSync, readFileSync } from "node:fs";
import { daemonCallTo, type DaemonEndpoint } from "../packages/desktop-client/daemon-client.ts";
import { readLocalToken, validateLocalSocket } from "../packages/desktop-client/local-ipc.ts";
import { homedir } from "os";
import { join } from "path";
import { spawn } from "child_process";

export const KOKORO_MODEL_ID = "mlx-community/Kokoro-82M-bf16";
export const KOKORO_VOICE_ID = "af_heart";
export const AVSPEECH_MODEL_ID = "avspeech:system";

const DEFAULT_CAPABILITY_PATH = join(
  homedir(),
  "Library/Application Support/Lattices/Voice/hudson-voice-runtime.json"
);

type Capability = {
  transport?: string;
  socketPath?: string;
  tokenPath?: string;
  webSocketUrl?: string;
  host?: string;
  port?: number;
  authToken?: string;
};

type VoxRuntime = {
  capability: Capability;
  wsUrl: string;
  endpoint: DaemonEndpoint;
};

let cachedRuntime: VoxRuntime | null | undefined;

function resolveCapabilityPath(): string {
  return process.env.LATTICES_VOICE_CAPABILITY?.trim() || DEFAULT_CAPABILITY_PATH;
}

function loadCapability(): Capability | null {
  let fd: number | undefined;
  try {
    fd = openSync(resolveCapabilityPath(), constants.O_RDONLY | constants.O_NOFOLLOW);
    const info = fstatSync(fd);
    if (!info.isFile() || info.nlink !== 1 || (info.mode & 0o077) !== 0
      || info.uid !== process.getuid?.() || info.size > 65_536) return null;
    return JSON.parse(readFileSync(fd, "utf8")) as Capability;
  } catch { return null; }
  finally { if (fd !== undefined) closeSync(fd); }
}

export function resolveVoxRuntime(): VoxRuntime | null {
  if (cachedRuntime !== undefined) return cachedRuntime;
  const capability = loadCapability();
  if (capability?.transport !== "unix+ws+json-rpc" || !capability.socketPath?.startsWith("/") || !capability.tokenPath?.startsWith("/")) {
    cachedRuntime = null; return null;
  }
  try {
    validateLocalSocket(capability.socketPath);
    readLocalToken(capability.tokenPath);
  } catch { cachedRuntime = null; return null; }
  const endpoint = { host: "localhost", port: 0, socketPath: capability.socketPath, tokenFile: capability.tokenPath };
  cachedRuntime = { capability, wsUrl: `unix:${capability.socketPath}`, endpoint };
  return cachedRuntime;
}

export function resetVoxRuntimeCache() {
  cachedRuntime = undefined;
}

function playWavFile(filePath: string): Promise<number> {
  const start = performance.now();
  return new Promise((resolve, reject) => {
    const player = spawn("/usr/bin/afplay", [filePath], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    player.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    player.on("close", (code) => {
      const ms = Math.round(performance.now() - start);
      if (code === 0) resolve(ms);
      else reject(new Error(`afplay failed (${code ?? "unknown"}): ${stderr.slice(0, 160)}`));
    });
    player.on("error", reject);
  });
}

async function voxRpc(
  runtime: VoxRuntime,
  method: string,
  params: Record<string, unknown>,
  timeoutMs = 120_000
): Promise<Record<string, unknown>> {
  return await daemonCallTo(runtime.endpoint, method, { clientId: "handsoff-worker", ...params }, timeoutMs) as Record<string, unknown>;
}

export async function synthesizeWithVox(
  text: string,
  options: {
    modelId?: string;
    voiceId?: string;
    format?: string;
  } = {}
): Promise<{ wav: Buffer; elapsedMs: number; modelId: string; voiceId: string }> {
  const runtime = resolveVoxRuntime();
  if (!runtime) {
    throw new Error("Hudson voice runtime capability is unavailable");
  }

  const result = await voxRpc(runtime, "synthesize.generate", {
    text,
    modelId: options.modelId,
    voiceId: options.voiceId,
    format: options.format ?? "wav",
  });

  const audioBase64 = String(result.audioBase64 ?? "");
  if (!audioBase64) {
    throw new Error("Vox synthesize.generate returned no audio");
  }

  const wav = Buffer.from(audioBase64, "base64");
  return {
    wav,
    elapsedMs: Number(result.elapsedMs ?? 0),
    modelId: String(result.modelId ?? options.modelId ?? KOKORO_MODEL_ID),
    voiceId: String(result.voiceId ?? options.voiceId ?? KOKORO_VOICE_ID),
  };
}

export async function speakWithVox(
  text: string,
  options: {
    modelId?: string;
    voiceId?: string;
    cachePath?: string;
  } = {}
): Promise<number> {
  const { wav, elapsedMs } = await synthesizeWithVox(text, {
    modelId: options.modelId,
    voiceId: options.voiceId,
  });

  if (options.cachePath) {
    const { writeFileSync } = await import("fs");
    writeFileSync(options.cachePath, wav);
    return elapsedMs;
  }

  const { mkdtempSync, writeFileSync, rmSync } = await import("fs");
  const { tmpdir } = await import("os");
  const dir = mkdtempSync(join(tmpdir(), "lattices-vox-tts-"));
  const filePath = join(dir, "speech.wav");
  writeFileSync(filePath, wav);
  try {
    const playbackMs = await playWavFile(filePath);
    return Math.max(playbackMs, elapsedMs);
  } finally {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {}
  }
}

export async function playCachedWav(filePath: string): Promise<number> {
  return playWavFile(filePath);
}

export function describeVoxRuntime(): string {
  const runtime = resolveVoxRuntime();
  if (!runtime) return "unavailable";
  return runtime.wsUrl;
}
