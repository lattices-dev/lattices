// Explicit safe process acceptance: SPEECH_REVIEW_APP must name a task-owned
// staged app. A separate control connection reserves playback before enqueue,
// then cancels the queued job before releasing; the probe produces no audio.
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
const app = process.env.SPEECH_REVIEW_APP;
if (!app) throw new Error('Set SPEECH_REVIEW_APP to the task-owned staged Voice.app.');
const dir = await mkdtemp(join(await realpath(tmpdir()), 'speech-lifecycle-'));
const capability = join(dir, 'capability');
const root = resolve(import.meta.dir, '..');
const probe = join(dir, 'speech-proxy-process');
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5',
  join(root, 'tests/fixtures/speech-proxy-process.swift'),
  join(root, 'apps/mac/Sources/Core/CompanionApps/SpeechCompanionConnection.swift'),
  join(root, 'apps/mac/Sources/Core/CompanionApps/SpeechUnixWebSocket.swift'),
  join(root, 'apps/mac/Sources/Core/Daemon/DaemonProtocol.swift'), '-o', probe]);
const host = spawn(join(app, 'Contents/MacOS/Voice'), ['--diagnose-host', capability], { stdio: ['ignore', 'pipe', 'pipe'] });
const hostExit = once(host, 'exit');
let control: WebSocket | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
try {
  const lines = createInterface({ input: host.stdout });
  const line = await Promise.race([once(lines, 'line').then(([line]) => String(line)), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('Voice host startup timed out')), 10_000); })]);
  clearTimeout(timer); lines.close();
  const { port } = JSON.parse(line);
  const endpoint = `ws://127.0.0.1:${port}`;
  const token = await readFile(capability, 'utf8');
  control = new WebSocket(endpoint, { headers: { 'x-lattices-speech-token': token } });
  await new Promise<void>((resolve, reject) => { control!.onopen = () => resolve(); control!.onerror = () => reject(new Error('Control connection failed')); });
  const calls = new Map<string, { resolve(value: any): void; reject(reason: unknown): void }>();
  control.onmessage = event => { const result = JSON.parse(String(event.data)); const pending = calls.get(result.id); if (!pending) return; calls.delete(result.id); result.error ? pending.reject(new Error(result.error)) : pending.resolve(result.result); };
  const request = (id: string, method: string) => new Promise<any>((resolve, reject) => {
    const timeout = setTimeout(() => { calls.delete(id); reject(new Error(`RPC timeout: ${method}`)); }, 5000);
    calls.set(id, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); } });
    control!.send(JSON.stringify({ id, method }));
  });
  await request('reserve', 'speech.playback.reserve');
  const child = Bun.spawn([probe, endpoint, capability], { stdout: 'pipe', stderr: 'pipe' });
  const responseText = await new Response(child.stdout).text();
  if (await child.exited !== 0) throw new Error(`Proxy failed: ${await new Response(child.stderr).text()}`);
  const response = JSON.parse(responseText);
  const status = await request('status', 'speech.status');
  if (host.exitCode !== null || status.current !== null || status.queued?.[0]?.id !== response.result?.id) throw new Error('Voice did not retain the job after proxy process exit.');
  await request('stop', 'speech.stop');
  const stopped = await request('stopped', 'speech.status');
  if (stopped.queued.length || stopped.current) throw new Error('Probe queue cleanup failed.');
  console.log(JSON.stringify({ result: 'passed', speechHostPID: host.pid, proxyExited: true, queueSurvivedProxyExit: true, audioSuppressedByReservation: true }));
} finally {
  clearTimeout(timer);
  // Stop only this task-owned host before closing the reservation on failures.
  host.kill('SIGTERM');
  await hostExit;
  control?.close();
  await rm(dir, { recursive: true, force: true });
}
