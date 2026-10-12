export type HomeContext = {
  dir: string;
  sessionName: string;
  configLabel: string;
  paneNames: string;
  sessionsStatus: string;
  appStatus: string;
  tmuxReady: boolean;
};

export function printHome(ctx: HomeContext): void {
  console.log(`lats — let's get you situated

Current directory:
  ${ctx.dir}

Workspace:
  session   ${ctx.sessionName}
  config    ${ctx.configLabel}
  panes     ${ctx.paneNames}
  sessions  ${ctx.sessionsStatus}
  app       ${ctx.appStatus}

Common commands:
  lats start        Start or reattach this directory's workspace
  lats init         Create a .lattices.json for this project
  lats app          Launch the menu bar app
  lats ls           List active sessions
  lats help         Show the full command reference
`);

  if (!ctx.tmuxReady) {
    console.log("tmux is not installed. Run: brew install tmux");
  }
}

export function printUsage(): void {
  console.log(`lats — workspace launcher for sessions, windows, layers, and the menu bar app
(also installed as lattices)

Machines and displays:
  lats @<host> <command...>  Run a daemon command on a configured host (@local for here)
  lats machines [--json]    Reachability, builds, displays, pairing and placement
  lats bring <display>     Bring every other display's windows here
  lats bring --undo        Restore gathered windows
  lats main <display> [--keep]  Make main (15-second trial unless kept)
  lats elsewhere <display> [machine]  Mark a display elsewhere
  lats here <display>      Bring a display back here
  lats visit <machine>     Visit a paired machine now
  lats home                End a visit and bring the cursor home
  lats display list        List displays (numbers or name fragments work)

  lats display gather <display> [--to <display>]  Move a display's windows onto another, laid out as they were
  lats display restore [display]  Put gathered windows back where they sat
  lats display lend <display>     Ask on the other screens where to gather a display's windows (for an input switch the Mac can't see)
  lats hosts [--discover] Reachable lattices hosts (Macs, Linux lattices-host)
  lats --host <name> ...  Send daemon calls to another host
  lats --host <name> pair Pair with a lattices-host (approve on the host)
  lats mouse              Find mouse — sonar pulse at cursor position
  lats mouse summon       Summon mouse to screen center
  lats mouse home         End visit, cursor to the main display
  lats visit pair <host> [host:port] [side]  Pair with a host to visit it with a second cursor
  lats visit forget <host>  Forget a visit pairing
  lats visit side <host> <side>  Place beside the outermost display
  lats visit on|off       Arm crossing into paired hosts at the screen edge
  lats visit status       Paired hosts and this Mac's code
  lats visit end          End a visit (or ⌃⌥⌘ Home)
  lats visit place <name> <x> <y>  Place in global display coordinates
  lats visit arrangement <keep|revert>  Resolve a display trial started with Apply
  lats visit host <on|off>  Allow receiving visits on this Mac (bundle)
  lats hosts add <name> [address] [port]  Add a Lattices host
  lats visit screens      This Mac's displays, and which are elsewhere
  lats visit elsewhere <display>  Display n is plugged into another machine; "here <n>" undoes it
  lats visit main <display>       Make display n the main one; reverts in 15s unless "arrangement keep"

Usage:
  lats                    Show workspace status and common commands
  lats start              Start or reattach the current directory's workspace
  lats init               Generate .lattices.json config for this project
  lats ls                 List active sessions
  lats status             Show managed vs unmanaged session inventory
  lats kill [name]        Kill a session (defaults to current project)
  lats sync               Reconcile session to match declared config
  lats restart [pane]     Restart a pane's process (by name or index)
  lats group [id]         List tab groups or launch/attach a group
  lats groups             List all tab groups with status
  lats tab <group> [tab]  Switch tab within a group (by label or index)
  lats search <query>     Search windows by title, app, session, OCR
  lats search <q> --deep  Deep search: index + live terminal inspection
  lats search <q> --wid   Print matching window IDs only (pipeable)
  lats search <q> --json  JSON output
  lats place <query> [pos]  Deep search + focus + tile (default: bottom-right)
  lats focus <session>    Raise a session's window
  lats windows [--json]   List all desktop windows (daemon required)
  lats map [--display n]  Render displays and visible windows as an ASCII map
  lats map --json         Return the structured display/window map for agents
  lats sessions [--json]  List active sessions via daemon
  lats terminals [--json] [--refresh]
                         List synthesized terminal instances
  lats capture window [wid]  Save a screenshot run artifact
  lats capture display [index]  Save a full-display screenshot run artifact
  lats capture record window [wid]  Record a window/visible region as a .mov artifact
  lats capture record-command --app Scout -- <cmd>
                         Record a target while running an action command
  lats capture stop <run-id> Stop a running capture recording
  lats runs [id] [--json] List recent runs or inspect one run
  lats computer prepare      Resolve/stage a safe terminal action
  lats computer focus-window Focus and verify a target window
  lats computer launch-app  Launch/focus a normal macOS app
  lats computer type-window Type into a normal app window
  lats computer click       Stage or post a window-relative click
  lats cua click            CLI alias for the CUA SDK click action
  lats computer scout       Scout warm-up run for memo/demo recording
  lats computer cursor       Show a recorded cursor appearance
  lats computer type-text    Type text into a safe terminal target
  lats computer demo-terminal  Record/focus/type a safe terminal demo
  lats tile <position>    Tile the frontmost window (left, right, top, etc.)
  lats tile family [app] [region]  Smart-grid the frontmost app family, or a named app
  lats window move <wid> --display <n> [--placement <slot>]
                         Move a window to another display, keeping its
                         normalized frame or snapping to a slot (daemon required)
  lats window place <wid> <slot> [--display <n>]
                         Snap a window into a named or grid placement slot
  lats distribute [app] [region]   Smart-grid visible windows or just one app (daemon required)
  lats layer [name|slot] [--tile|--launch]  List layers, or switch as ⌘⌥ does; slots are the pad's 1-4, 6-9 (daemon required)
  lats layer exit          Exit Layers: restore windows and turn layer focus off
  lats layer reveal        Alias for exit (also: off, show-all)
  lats layer classic [--one-space]  Every window back as if Lattices weren't running (⌘⌥0); --one-space also gathers onto one desktop per display
  lats layer undo                   Take back the last layer edit (⌘⌥Z); no window moves until the next switch
  lats layer create <name> [wid:N ...] [--json '<specs>']  Save windows (default: on screen) as a new layer
  lats layer snap [name]   Save the windows on screen as a new layer
  lats layer add wid:N ... [--to <layer>]  Add windows to a layer (default: the active one)
  lats layer remove wid:N ... [--from <layer>]  Take windows out of a layer (default: the active one)
  lats layer rename <layer> <name>  Rename a layer
  lats state [list] [--since 2h] [--named]  Desktop maps recorded after each change, kept 72h (daemon required)
  lats state show [id]      One map: displays, their desktops and what's on each
  lats state save <name>    Record the desktop now under a name, before a risky change
  lats state restore <id|name> [--plan]  Put windows back on the desktops and frames a map has (never touches display settings)
  lats layer delete <layer> Delete a layer from workspace.json
  lats voice say <text>   Speak text through the Voice helper
  lats voice stop         Stop speaking (pause, resume, skip, seek, list, select too)
  lats voice stopListening  Stop voice capture
  lats voice status       Listening state and Voice helper status
  lats voice simulate <t> Parse and execute a voice command
  lats voice intents      List all available intents
  lats actor app <app> [message]  Show a clickable app-icon actor
  lats actor switcher [apps...]   Show a clickable app switcher row
  lats actor hud <id> <url>       Attach a hover web HUD to an actor
  lats actor toggle       Hide/show the sticky actor layer
  lats hud register [manifest]    Register a .lattices/hud/manifest.json
  lats hud publish [id|manifest]  Publish a registered/static HUD actor
  lats assistant plan <t> Preview the TS assistant planner
  lats call <method> [p]  Raw daemon API call (params as JSON)
  lats scan               Show text from all visible windows
  lats scan --full        Full text dump
  lats scan search <q>    Full-text search across scanned windows
  lats scan recent [n]    Show recent scans chronologically
  lats scan deep          Trigger a deep Vision OCR scan
  lats scan history <wid> Scan timeline for a specific window
  lats dev                Run dev server (auto-detected)
  lats dev build          Build the project (swift/node/rust/go/make)
  lats dev restart        Build + restart (swift app) or just build
  lats dev placement-smoke [a] [b]  Move two named sessions through verified placements
  lats dev type           Print detected project type
  lats long [show|hide]   Long, on the desktop; click him for controls
  lats mcp                MCP server over stdio (agent config: command "lattices", args ["mcp"])
  lats mcp --list         List MCP toolsets and their tools
  lats mcp --print-config <harness>  Print the agent config snippet
  lats daemon status      Show daemon status
  lats logs [limit]       Show activity log entries (aliases: log, activity, diag)
  lats update             Update lattices (CLI + app), keep startup, relaunch
  lats app                Launch the menu bar companion app
  lats app update         Swap in the latest app release only (not the CLI)
  lats app build          Rebuild the menu bar app
  lats app restart        Rebuild and relaunch the menu bar app
  lats app quit           Stop the menu bar app
  lats action             Action product status (install, agent, checkout)
  lats action install     Download the latest Action.app release to /Applications
  lats action launch      Open Action.app (--launch with install)
  lats action call <m>    Raw Action agent call (ws://127.0.0.1:4319)
  lats action <cmd>       Forward to the Action CLI (monorepo checkout)
  lats help               Show this help

Config (.lattices.json):
  Place in your project root to customize the layout:

  {
    "ensure": true,
    "panes": [
      { "name": "shell", "size": 60 },
      { "name": "server", "cmd": "pnpm dev" },
      { "name": "tests",  "cmd": "pnpm test --watch" }
    ]
  }

  size      Width % for the first pane (default: 60)
  cmd       Command to run in the pane
  name      Label (for your reference)
  ensure    Auto-restart exited commands on reattach
  prefill   Type commands into idle panes on reattach (you hit Enter)

Recovery:
  lats sync       Recreates missing panes, restores commands, fixes layout.
                  Use when a pane was killed and you want to get back to the
                  declared state without killing the whole session.

  lats restart    Kills the process in a pane and re-runs its declared command.
                  Accepts a pane name or 0-based index (default: 0 / first pane).
                  Examples:  lats restart         (restarts the first pane)
                             lats restart server  (restarts "server" by name)
                             lats restart 1       (restarts pane at index 1)

Layouts:
  1 pane   →  single full-width (default when no dev server detected)
  2 panes  →  side-by-side split
  3+ panes →  main-vertical (first pane left, rest stacked right)

  ┌────────────────────┐    ┌──────────┬─────────┐    ┌──────────┬─────────┐
  │      shell          │    │  shell    │ server  │    │  shell    │ server  │
  │                     │    │  (60%)   │ (40%)   │    │  (60%)   ├─────────┤
  └────────────────────┘    └──────────┴─────────┘    │          │ tests   │
                                                       └──────────┴─────────┘
`);
}
