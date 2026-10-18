/** @type {import('@arach/dewey').DeweyConfig} */
export default {
  project: {
    name: 'lattices',
    tagline: 'macOS developer workspace manager — tmux sessions with a native menu bar app for tiling, navigation, and project management',
    type: 'cli-tool',
    version: '0.6.3',
  },

  agent: {
    criticalContext: [
      'lattices has TWO primary interfaces: a TypeScript CLI (`bin/lattices.ts`) and a native Swift menu bar app (`apps/mac/Sources/`)',
      'Session names are `<basename>-<sha256-6chars>` — both CLI and app must produce identical hashes',
      'The app finds terminal windows via a `[lattices:session-name]` tag embedded in the tmux window title',
      'Window navigation falls through CG → AX → AppleScript depending on macOS permissions',
      'Space switching uses private SkyLight framework APIs loaded via dlopen at runtime',
      'The daemon runs on ws://127.0.0.1:9399 with 40+ typed RPC methods and real-time events',
      'Computer-use work must preserve treatment semantics, run receipts, artifacts, and explicit browser automation gates',
    ],

    entryPoints: {
      'cli': 'bin/lattices.ts',
      'app-helper': 'bin/lattices-app.ts',
      'menu-bar-app': 'apps/mac/Sources/',
      'docs': 'docs/',
      'site': 'apps/site/',
      'marketing-site': 'apps/site/',
    },

    rules: [
      { pattern: 'cli', instruction: 'Check bin/lattices.ts for CLI commands and session logic' },
      { pattern: 'app', instruction: 'Check apps/mac/Sources/ for Swift menu bar app code' },
      { pattern: 'config', instruction: 'Check docs/config.md for .lattices.json format and CLI reference' },
      { pattern: 'tiling', instruction: 'Check apps/mac/Sources/Core/Desktop/WindowTiler.swift and apps/mac/Sources/Core/Desktop/PlacementSpec.swift' },
      { pattern: 'palette', instruction: 'Check apps/mac/Sources/Core/Actions/PaletteCommand.swift for command palette actions' },
      { pattern: 'terminal', instruction: 'Check apps/mac/Sources/Core/Workspace/Terminal/Terminal.swift for supported terminals and launch logic' },
      { pattern: 'daemon', instruction: 'Check apps/mac/Sources/Core/Daemon/DaemonServer.swift and apps/mac/Sources/Core/Daemon/LatticesApi.swift for WebSocket API' },
      { pattern: 'api', instruction: 'Check docs/api.md for the daemon RPC reference' },
      { pattern: 'computer-use', instruction: 'Check docs/agent/cua-implementation.md and docs/proposals/LAT-008-pi-lattices-computer-use.md before changing CUA endpoints' },
      { pattern: 'cua', instruction: 'Check docs/agent/cua-implementation.md and docs/proposals/LAT-008-pi-lattices-computer-use.md before changing CUA endpoints' },
    ],

    sections: ['overview', 'quickstart', 'concepts', 'config', 'app', 'api', 'agent/cua-implementation', 'agent/dewey-agent-architecture', 'layers'],
  },

  docs: {
    path: './docs',
    output: './',
    required: ['overview', 'quickstart', 'concepts', 'config'],
  },

  install: {
    objective: 'Install the lattices CLI and optionally the native macOS menu bar companion app.',

    doneWhen: {
      command: 'lattices help',
      expectedOutput: 'Usage information for lattices CLI',
    },

    prerequisites: [
      'macOS 26.0+',
      'tmux (brew install tmux)',
      'Node.js >= 18',
      'Swift 6.2 / Xcode 26+ (only if building the menu bar app from source)',
    ],

    steps: [
      { description: 'Install tmux if not present', command: 'brew install tmux' },
      { description: 'Clone the repository', command: 'git clone https://github.com/lattices-dev/lattices && cd lattices' },
      { description: 'Link the CLI globally', command: 'bun link' },
      { description: 'Build and launch the menu bar app', command: 'lattices app' },
      { description: 'Create a config in your project', command: 'cd ~/your-project && lattices init' },
      { description: 'Start your first workspace', command: 'lattices' },
    ],
  },
}
