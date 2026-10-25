import { test, expect } from "bun:test";
import { createServer } from "node:net";
import { createHash } from "node:crypto";
import { mkdtempSync, chmodSync, writeFileSync, rmSync, symlinkSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { resetVoxRuntimeCache, resolveVoxRuntime, synthesizeWithVox } from "../bin/vox-tts.ts";

function frame(text: string): Buffer {
  const payload = Buffer.from(text);
  const head = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 255]);
  return Buffer.concat([head, payload]);
}

test("worker TTS uses private IPC admission and preserves synthesis metadata", async () => {
  // Keep the Unix socket path short and resolve macOS's /tmp symlink.
  const dir = mkdtempSync(join(realpathSync("/tmp"), "voice-cli-")); chmodSync(dir, 0o700);
  const socketPath = join(dir, "voice.sock"); const tokenPath = join(dir, "voice.token"); const capabilityPath = join(dir, "runtime.json");
  const token = "a".repeat(43); writeFileSync(tokenPath, token, { mode: 0o600 });
  const previous = process.env.LATTICES_VOICE_CAPABILITY;
  let observed: any;
  let admitted = false;
  const peers = new Set<import("node:net").Socket>();
  const server = createServer(socket => {
    peers.add(socket); socket.on("close", () => peers.delete(socket));
    let buffer = Buffer.alloc(0); let upgraded = false;
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf("\r\n\r\n"); if (end < 0) return;
        const header = buffer.subarray(0, end).toString(); buffer = buffer.subarray(end + 4);
        expect(header).toContain(`x-lattices-token: ${token}`);
        const key = /Sec-WebSocket-Key: ([^\r\n]+)/i.exec(header)![1];
        const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        upgraded = admitted = true;
      }
      if (buffer.length < 6) return;
      let size = buffer[1] & 127; let offset = 2;
      if (size === 126) { if (buffer.length < 8) return; size = buffer.readUInt16BE(2); offset = 4; }
      if (buffer.length < offset + 4 + size) return;
      const mask = buffer.subarray(offset, offset + 4); const payload = buffer.subarray(offset + 4, offset + 4 + size);
      const decoded = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));
      observed = JSON.parse(decoded.toString());
      socket.write(frame(JSON.stringify({ id: observed.id, result: { audioBase64: Buffer.from("fake-audio").toString("base64"), elapsedMs: 9, modelId: "test-model", voiceId: "test-voice" } })));
    });
  });
  try {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); }); chmodSync(socketPath, 0o600);
    writeFileSync(capabilityPath, JSON.stringify({ transport: "unix+ws+json-rpc", socketPath, tokenPath }), { mode: 0o600 });
    process.env.LATTICES_VOICE_CAPABILITY = capabilityPath; resetVoxRuntimeCache();
    const result = await synthesizeWithVox("test", { modelId: "test-model", voiceId: "test-voice" });
    expect(admitted).toBe(true); expect(result.wav.toString()).toBe("fake-audio");
    expect(result.modelId).toBe("test-model"); expect(result.voiceId).toBe("test-voice");
    expect(observed.method).toBe("synthesize.generate"); expect(observed.params.clientId).toBe("handsoff-worker");
    chmodSync(capabilityPath, 0o644); resetVoxRuntimeCache(); expect(resolveVoxRuntime()).toBeNull();
    chmodSync(capabilityPath, 0o600); const linked = join(dir, "linked.json"); symlinkSync(capabilityPath, linked);
    process.env.LATTICES_VOICE_CAPABILITY = linked; resetVoxRuntimeCache(); expect(resolveVoxRuntime()).toBeNull();
    process.env.LATTICES_VOICE_CAPABILITY = capabilityPath;
    writeFileSync(capabilityPath, JSON.stringify({ webSocketUrl: "ws://127.0.0.1:9398", authToken: token })); resetVoxRuntimeCache();
    expect(resolveVoxRuntime()).toBeNull();
  } finally {
    for (const socket of peers) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
    if (previous === undefined) delete process.env.LATTICES_VOICE_CAPABILITY; else process.env.LATTICES_VOICE_CAPABILITY = previous;
    resetVoxRuntimeCache(); rmSync(dir, { recursive: true, force: true });
  }
});
