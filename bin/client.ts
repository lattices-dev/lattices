// Public API — re-exports from daemon-client for a cleaner import path.
// Usage: import { daemonCall, isDaemonRunning } from '@lattices/lattices'
// Also published as @arach/lattices and @lattices/cli for compatibility.

export { daemonCall, isDaemonRunning } from "./daemon-client.ts";
export {
  ProjectTwin,
  createProjectTwin,
  readOpenScoutRelayContext,
  type OpenScoutRelayContext,
  type ProjectTwinEvent,
  type ProjectTwinInvokeRequest,
  type ProjectTwinOptions,
  type ProjectTwinResult,
  type ProjectTwinState,
  type ProjectTwinThinkingLevel,
} from "./project-twin.ts";
