/** @type {import('@arach/dewey').DeweyConfig} */
export default {
  project: {
    name: 'action',
    tagline: 'Native-first macOS demo automation with an AppKit UI and a local agent runtime',
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
    objective: 'On an authorized development host, build the signed Action.app bundle and verify native health. Installation targets receive a matched app/runtime with rollback; this source-build flow does not prove desktop isolation.',
    doneWhen: {
      command: 'bun run native:doctor',
    },
    prerequisites: [
      'macOS on Apple Silicon',
      'Bun 1.3+',
      'Xcode command line tools and native build prerequisites for Swift/AppKit development',
      'Accessibility and Screen Recording permissions may be required for capture and automation smoke tests',
    ],
    steps: [
      { description: 'Clone the repository', command: 'git clone https://github.com/arach/lattices.git && cd lattices/products/action' },
      { description: 'Install JavaScript dependencies', command: 'bun install' },
      { description: 'Build and sign the native app', command: 'bun run native:app:build' },
      { description: 'Rebuild, sign, and verify native health on the development host', command: 'bun run native:doctor' },
      { description: 'Run a screenshot smoke test', command: 'bun run native:test:screenshot' },
    ],
  },
}
