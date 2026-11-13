/** @type {import('@arach/dewey').DeweyConfig} */
export default {
  project: {
    name: 'action',
    tagline: 'Computer use for agents on macOS, part of Lattices',
    type: 'monorepo',
    version: '0.3.1',
  },

  agent: {
    criticalContext: [
      'Migration is complete: the original Action main history was merged into arach/lattices at products/action on August 27, 2026 (import commit b1ad511adf509c0c60d7f3edce7cd15257601db2). Use arach/lattices for ongoing development; arach/action is historical.',
      "On Arach's Mac, /Users/arach/dev/action is a compatibility symlink to /Users/arach/dev/lattices/products/action. Both paths share the Lattices Git checkout and its uncommitted work. Verify the Git root and status before changing files.",
      'Read ../../AGENTS.md for Lattices workspace rules before applying these product instructions. Keep Action.app, its local agent, and its recording lifecycle independent from the Lattices menu bar app.',
      'Private layers: read docs/agent-layer.md. Check CLI/MCP capabilities, native/source provenance, host quarantine and acceptance.privateLayer.state=accepted before opening. MCP layer_open {browser:true} binds a CDP-only session; input failures never authorize native fallback. Reconnect after updates. Version and raw WS methods do not prove feature parity.',
      'Persistent monitor: layer prepare explicitly connects a display and may change desktop topology. Tasks attach with layer open; layer close restores task windows but leaves the monitor connected. Only explicit layer release disconnects it. Check layer display-status; never provision or release silently during a task.',
      'Installation targets use a matched signed app and MCP runtime with rollback. native:doctor rebuilds; use it only on an authorized development host.',
      'Use bun as the JavaScript package manager for this repo.',
      'Action lives at `products/action/` inside the Lattices monorepo. Run product-local commands from this directory or use the root `action:*` scripts.',
      'The public product page and published Action documentation live at `https://lattices.dev/action`; source links point into `arach/lattices`.',
      'Action releases use `action-vX.Y.Z` tags so they cannot collide with Lattices app tags.',
      'The native product lives in native/engine and builds a signed Action.app bundle.',
      'Action.app owns AppKit lifecycle, menus, WebKit, permissions UX, and the recording probe path.',
      'The local Action agent exposes WebSocket methods and should not own fragile AppKit lifecycle responsibilities directly.',
      'ScreenCaptureKit recording is currently stabilized by launching a fresh Action.app instance in recording-probe mode.',
      'Recording commands should be treated as asynchronous: the initial CLI reply acknowledges startup, while completion is represented by a finished marker file.',
      'The repo still contains older design docs in docs/*.md that describe architecture and product direction beyond the Dewey quickstart set.',
    ],

    entryPoints: {
      root: 'README.md',
      dewey: 'dewey.config.ts',
      native: 'native/engine/',
      appHost: 'native/engine/Sources/ActionHostMain.swift',
      agentRuntime: 'native/engine/CoreSources/ActionAgentRuntime.swift',
      recordingProbe: 'native/engine/Sources/RecordingProbeAppRunner.swift',
      launcher: 'native/engine/Sources/ActionLauncherViewModel.swift',
      docs: 'docs/',
    },

    rules: [
      { pattern: 'webkit', instruction: 'Read docs/native-runtime.md and native/engine/Sources/ActionHostMain.swift for the AppKit-owned UI lifecycle.' },
      { pattern: 'record', instruction: 'Read docs/recording.md and native/engine/CoreSources/ActionRecordingProbeLauncher.swift before changing recording behavior.' },
      { pattern: 'agent', instruction: 'Read docs/native-runtime.md and native/engine/CoreSources/ActionAgentRuntime.swift for the current app/agent split.' },
      { pattern: 'permission', instruction: 'Check native/engine/Sources/ActionLauncherViewModel.swift and the native wrapper scripts in native/engine/scripts/.' },
      { pattern: 'build', instruction: 'On the authorized development host, use native/engine/scripts/build-app.sh to produce a signed app bundle. native:doctor rebuilds; do not run it as read-only installation-target QA.' },
      { pattern: 'theme', instruction: 'Read docs/theming.agent.md before changing colour, type or metrics. Views paint through StageHUDTheme, which resolves whichever ActionTheme is installed; themes are patches authored as JSON.' },
    ],

    sections: ['overview', 'getting-started', 'native-runtime', 'recording', 'agent-layer'],
  },

  docs: {
    path: './docs',
    output: './',
    required: ['overview', 'getting-started', 'native-runtime', 'recording', 'agent-layer'],
  },

  install: {
    objective: 'Install Action.app in /Applications, grant its permissions, and confirm the agent answers. Use the Lattices CLI when it is present; otherwise use the Action CLI. Both install the same signed app from the latest action-v* release. Build from source only when asked; see docs/getting-started.md.',
    doneWhen: {
      command: 'action status',
    },
    prerequisites: [
      'macOS on Apple Silicon',
      'Bun 1.3+',
      'The user can approve Accessibility and Screen Recording prompts',
    ],
    steps: [
      { description: 'Install the Action CLI (skip if `lats` is installed; use `lats action` in place of `action` below)', command: 'bun add -g @lattices/action' },
      { description: 'Install and launch Action.app', command: 'action install --launch' },
      { description: 'Grant Accessibility and Screen Recording', command: 'action setup action-cua' },
      { description: 'Confirm the app and agent are ready', command: 'action status' },
    ],
  },
}
