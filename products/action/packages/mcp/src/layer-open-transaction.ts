import type { AgentLayerStatus } from "@action/protocol";

export function canRollbackLayerOpen(created: AgentLayerStatus, current: AgentLayerStatus): boolean {
  if (!current.active) return true;
  return Boolean(created.layer && current.layer
    && current.layer.pid === created.layer.pid
    && current.layer.displayId === created.layer.displayId
    && current.layer.startedAt === created.layer.startedAt);
}

export async function completeLayerOpen<T>(
  finish: () => Promise<T>,
  closeCreatedLayer: () => Promise<boolean>,
): Promise<T> {
  try {
    return await finish();
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause);
    let cleanup: string;
    try {
      cleanup = await closeCreatedLayer()
        ? "The created layer was closed."
        : "Cleanup did not confirm closure; stop interactions and inspect layer_status before recovery.";
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      cleanup = `Cleanup failed (${detail}); stop interactions and inspect layer_status before recovery.`;
    }
    throw new Error(`Layer open failed: ${reason}. ${cleanup}`, { cause });
  }
}
