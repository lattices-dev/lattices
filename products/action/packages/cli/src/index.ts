import { compileScenario, type ScenarioDocument } from "@action/compiler";
import type { GuidedSessionEvent, HudSnapshot } from "@action/protocol";
import { GuidedCaptureSession, MacOSCommandEngine, MockCaptureEngine, remoteEngineFromEnv } from "@action/runtime";
import { resolve } from "node:path";

export function describeCli(): string[] {
  return [
    "action inspect current-surface",
    "action session create",
    "action guided stage",
    "action guided start",
    "action guided pause",
    "action guided stop",
    "action guided replay-last-run",
    "action compose",
    "action export",
  ];
}

export interface GuidedCaptureDemoResult {
  snapshot: HudSnapshot;
  events: GuidedSessionEvent[];
  scenario: ScenarioDocument;
}

/** `remote` drives the lattices host named by ACTION_REMOTE_HOST (LAT-013). */
export type DemoEngineMode = "mock" | "macos" | "remote";

function createSession(
  scenario: ScenarioDocument,
  engineMode: DemoEngineMode,
): GuidedCaptureSession {
  const engine = engineMode === "remote"
    ? remoteEngineFromEnv() ?? (() => { throw new Error("engine mode remote needs ACTION_REMOTE_HOST"); })()
    : engineMode === "macos"
      ? new MacOSCommandEngine()
      : new MockCaptureEngine();

  return new GuidedCaptureSession(engine, {
    sessionId: `session_${scenario.id.replace(/[^a-z0-9]+/gi, "_")}`,
    outputDir: resolve(process.cwd(), "artifacts", "sessions", scenario.id),
    captureProfile: "draft",
    stageHoldMsAfterComplete: 0,
    initialActionDelayMs: scenario.run?.initialActionDelayMs ?? 650,
    actionCadenceMs: scenario.run?.actionCadenceMs ?? 900,
  });
}

export async function runScenarioGuidedCaptureDemo(
  scenario: ScenarioDocument,
  engineMode: DemoEngineMode = "mock",
): Promise<GuidedCaptureDemoResult> {
  const session = createSession(scenario, engineMode);

  const events: GuidedSessionEvent[] = [];
  session.onEvent((event) => {
    events.push(event);
  });

  await session.stageScene({
    backdrop: scenario.stage.backdrop,
    viewport: scenario.stage.viewport,
    targetApp: scenario.targetApp,
  });

  const { timeline } = compileScenario(scenario);

  await session.beginRun(timeline);
  await session.stop();
  try {
    await session.captureScreenshot("screenshot-viewport-final.png", "viewport");
    await session.captureScreenshot("screenshot-full-final.png", "full");
  } catch {}

  return {
    snapshot: session.snapshot(),
    events,
    scenario,
  };
}

export async function previewScenarioStage(
  scenario: ScenarioDocument,
  engineMode: DemoEngineMode = "mock",
): Promise<{ snapshot: HudSnapshot; scenario: ScenarioDocument }> {
  const previousStageControls = process.env.ACTION_STAGE_CONTROLS;
  if (engineMode === "macos") {
    process.env.ACTION_STAGE_CONTROLS = "1";
  }

  const session = createSession(scenario, engineMode);

  try {
    await session.stageScene({
      backdrop: scenario.stage.backdrop,
      viewport: scenario.stage.viewport,
      targetApp: scenario.targetApp,
    });

    await new Promise<void>((resolve) => {
      let settled = false;
      const finish = async () => {
        if (settled) {
          return;
        }
        settled = true;
        clearInterval(interval);
        process.off("SIGINT", onSignal);
        process.off("SIGTERM", onSignal);
        await session.clearStage();
        resolve();
      };

      const onSignal = () => {
        void finish();
      };

      const interval = setInterval(() => {
        void (async () => {
          const commands = await session.consumeStageControls();
          if (commands.includes("quit") || commands.includes("clear")) {
            await finish();
          }
        })();
      }, 180);

      process.on("SIGINT", onSignal);
      process.on("SIGTERM", onSignal);
    });

    return {
      snapshot: session.snapshot(),
      scenario,
    };
  } finally {
    if (previousStageControls === undefined) {
      delete process.env.ACTION_STAGE_CONTROLS;
    } else {
      process.env.ACTION_STAGE_CONTROLS = previousStageControls;
    }
  }
}
