import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

type Json = Record<string, unknown>;

/** A bounded read-only page observer. It never writes DOM, styles, or playback. */
export function animationSampleStartExpression(key: string, durationMs: number, selector: string, revisionSelector: string): string {
  return `(() => {
    const key = ${JSON.stringify(key)}, durationMs = ${durationMs};
    const selector = ${JSON.stringify(selector)}, revisionSelector = ${JSON.stringify(revisionSelector)};
    document.querySelector(selector); document.querySelector(revisionSelector);
    const report = { schemaVersion: 1, timeOrigin: performance.timeOrigin, startedAt: Date.now(), startedAtPerformance: performance.now(), durationMs, initialVisibility: document.visibilityState, frames: [], samples: [], longTasks: [], visibility: [], revisions: [], droppedFrames: 0, longTaskSupported: false, finished: false };
    let raf = 0, timer = 0, lastDetail = -Infinity;
    const revisionNode = document.querySelector(revisionSelector);
    const revision = () => revisionNode?.getAttribute('data-revision') ?? null;
    const changed = () => report.revisions.push({time: performance.now(), revision: revision()});
    const mutation = new MutationObserver(changed);
    if (revisionNode) mutation.observe(revisionNode, {attributes: true, attributeFilter: ['data-revision']});
    changed();
    const visibility = () => report.visibility.push({time: performance.now(), state: document.visibilityState});
    document.addEventListener('visibilitychange', visibility);
    let observer;
    if (PerformanceObserver.supportedEntryTypes.includes('longtask')) {
      observer = new PerformanceObserver(list => { for (const entry of list.getEntries()) if (report.longTasks.length < 300) report.longTasks.push({startTime: entry.startTime, duration: entry.duration}); });
      observer.observe({type: 'longtask'}); report.longTaskSupported = true;
    }
    const stop = () => { if (report.finished) return; report.finished = true; report.finishedAt = Date.now(); report.finishedAtPerformance = performance.now(); cancelAnimationFrame(raf); clearTimeout(timer); observer?.disconnect(); mutation.disconnect(); document.removeEventListener('visibilitychange', visibility); };
    const frame = time => {
      if (report.frames.length < 30000) report.frames.push(time); else report.droppedFrames++;
      if (time - lastDetail >= 50 && report.samples.length < 1200) {
        lastDetail = time;
        const animations = document.getAnimations(); const states = {};
        for (const animation of animations) states[animation.playState] = (states[animation.playState] ?? 0) + 1;
        const elements = Array.from(document.querySelectorAll(selector)).slice(0, 4).map(element => ({
          state: element.getAttribute('data-state'), animate: element.getAttribute('data-animate'), variant: element.getAttribute('data-variant'),
          opacity: getComputedStyle(element).opacity,
          children: Array.from(element.children).slice(0, 6).map(child => ({opacity: getComputedStyle(child).opacity, animations: child.getAnimations().slice(0, 2).map(a => ({playState: a.playState, currentTime: typeof a.currentTime === 'number' ? a.currentTime : null, startTime: typeof a.startTime === 'number' ? a.startTime : null}))}))
        }));
        report.samples.push({time, visibility: document.visibilityState, revision: revision(), animationCount: animations.length, animationStates: states, elements});
      }
      if (!report.finished) raf = requestAnimationFrame(frame);
    };
    globalThis[key] = {report, stop};
    raf = requestAnimationFrame(frame); timer = setTimeout(stop, durationMs);
    return {status: 'sampling', timeOrigin: report.timeOrigin, startedAt: report.startedAt, startedAtPerformance: report.startedAtPerformance, durationMs};
  })()`;
}

export class BrowserAnimationSamples {
  private current?: { id: string; tabId: string; key: string; result?: Json };
  constructor(private artifactRoot: string) {}

  async start(tabId: string, args: Json, evaluate: (expression: string) => Promise<unknown>): Promise<Json> {
    if (this.current && !this.current.result) throw new Error("Collect or stop the current animation sample first.");
    const durationMs = args.durationMs ?? 30_000;
    if (typeof durationMs !== "number" || !Number.isInteger(durationMs) || durationMs < 1000 || durationMs > 60_000) throw new Error("durationMs must be an integer from 1000 to 60000.");
    const parseSelector = (value: unknown, fallback: string) => {
      const result = value ?? fallback;
      if (typeof result !== "string" || !result.trim() || result.length > 300) throw new Error("Sample selectors must contain 1 to 300 characters.");
      return result;
    };
    const selector = parseSelector(args.selector, "[data-animate]");
    const revisionSelector = parseSelector(args.revisionSelector, "[data-revision]");
    const id = randomUUID(), key = `__actionAnimationSample_${id.replaceAll("-", "")}`;
    const state = {id, tabId, key}; this.current = state;
    try {
      const result = await evaluate(animationSampleStartExpression(key, durationMs, selector, revisionSelector));
      return {sampleId: id, tabId, ...(result as Json), readOnly: true, detailIntervalMs: 50, maximumFrames: 30_000};
    } catch (error) { if (this.current === state) this.current = undefined; throw error; }
  }

  async result(tabId: string, id: string, stop: boolean, evaluate: (expression: string) => Promise<unknown>): Promise<Json> {
    const current = this.current;
    if (!current || current.id !== id || current.tabId !== tabId) throw new Error("Unknown sampleId for this MCP owner and tab.");
    if (current.result) return current.result;
    const report = await evaluate(`(() => { const sample = globalThis[${JSON.stringify(current.key)}]; if (!sample) throw new Error('Animation sample lost after navigation'); ${stop ? "sample.stop();" : ""} return sample.report.finished ? sample.report : {finished: false}; })()`) as Json;
    if (!report.finished) return {sampleId: id, tabId, status: "sampling"};
    await mkdir(this.artifactRoot, {recursive: true, mode: 0o700});
    const outputPath = join(this.artifactRoot, `animation-${id}.json`);
    await writeFile(outputPath, JSON.stringify(report), {flag: "wx", mode: 0o600});
    await evaluate(`delete globalThis[${JSON.stringify(current.key)}]`);
    return current.result = {sampleId: id, tabId, status: "finished", outputPath, timeOrigin: report.timeOrigin, startedAt: report.startedAt, finishedAt: report.finishedAt, frames: (report.frames as unknown[]).length, droppedFrames: report.droppedFrames, samples: (report.samples as unknown[]).length, longTaskSupported: report.longTaskSupported};
  }
}
