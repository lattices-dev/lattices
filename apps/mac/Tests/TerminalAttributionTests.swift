import XCTest
@testable import Lattices

final class TerminalAttributionTests: XCTestCase {

    // MARK: - Fixtures

    private func window(
        _ wid: UInt32, app: String, pid: Int32, title: String,
        bundleId: String? = nil, zIndex: Int = 0
    ) -> WindowEntry {
        var entry = WindowEntry(
            wid: wid, app: app, pid: pid, title: title,
            frame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
            spaceIds: [1], isOnScreen: true, latticesSession: nil
        )
        entry.zIndex = zIndex
        entry.bundleId = bundleId
        return entry
    }

    private func proc(_ pid: Int, _ ppid: Int, tty: String = "??", comm: String, args: String? = nil, cwd: String? = nil) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, pgid: pid, tty: tty, comm: comm, args: args ?? comm, cwd: cwd)
    }

    private func table(_ entries: [ProcessEntry]) -> [Int: ProcessEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
    }

    /// Ghostty launches shells through login: ghostty → login → -zsh.
    private func ghosttyTree(ghosttyPid: Int = 500) -> [ProcessEntry] {
        [
            proc(ghosttyPid, 1, comm: "ghostty", args: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            proc(601, ghosttyPid, tty: "ttys010", comm: "login", args: "/usr/bin/login -flp arach /bin/bash"),
            proc(602, 601, tty: "ttys010", comm: "-zsh", cwd: "/Users/test/dev/lattices"),
            proc(611, ghosttyPid, tty: "ttys011", comm: "login", args: "/usr/bin/login -flp arach /bin/bash"),
            proc(612, 611, tty: "ttys011", comm: "-zsh", cwd: "/Users/test/dev/vox"),
        ]
    }

    // MARK: - Terminal identity

    func testTerminalFromBundleIdCoversWarpChannels() {
        XCTAssertEqual(Terminal.from(bundleId: "dev.warp.Warp-Stable"), .warp)
        XCTAssertEqual(Terminal.from(bundleId: "dev.warp.Warp-Preview"), .warp)
        XCTAssertEqual(Terminal.from(bundleId: "com.mitchellh.ghostty"), .ghostty)
        XCTAssertEqual(Terminal.from(bundleId: "net.kovidgoyal.kitty"), .kitty)
        XCTAssertNil(Terminal.from(bundleId: "com.apple.Safari"))
    }

    func testTerminalFromWindowAppIsCaseInsensitive() {
        XCTAssertEqual(Terminal.from(windowApp: "kitty"), .kitty)
        XCTAssertEqual(Terminal.from(windowApp: "iTerm 2"), .iterm2)
        XCTAssertEqual(Terminal.from(windowApp: "Ghostty"), .ghostty)
        XCTAssertNil(Terminal.from(windowApp: "Finder"))
    }

    func testTerminalFromExecutableReadsTheAppBundle() {
        XCTAssertEqual(Terminal.from(executable: "/Applications/Warp.app/Contents/MacOS/stable --flag"), .warp)
        XCTAssertEqual(Terminal.from(executable: "/Applications/kitty.app/Contents/MacOS/kitty"), .kitty)
        XCTAssertNil(Terminal.from(executable: "/bin/zsh -l"))
    }

    // MARK: - Owner walk

    func testOwnerWalksThroughLoginToTheWindowOwningPid() {
        let processes = table(ghosttyTree())
        let owner = TerminalSynthesizer.owner(ofPid: 601, processTable: processes, terminalPids: [500: .ghostty])
        XCTAssertEqual(owner, TerminalOwner(app: .ghostty, pid: 500))
    }

    func testOwnerFallsBackToTheExecutablePathWithoutAWindowOwner() {
        let processes = table([
            proc(700, 1, comm: "stable", args: "/Applications/Warp.app/Contents/MacOS/stable"),
            proc(701, 700, tty: "ttys020", comm: "-zsh"),
        ])
        let owner = TerminalSynthesizer.owner(ofPid: 701, processTable: processes, terminalPids: [:])
        XCTAssertEqual(owner, TerminalOwner(app: .warp, pid: nil))
    }

    func testOwnerIsNilForTmuxPanes() {
        let processes = table([
            proc(800, 1, comm: "tmux", args: "tmux new -d"),
            proc(801, 800, tty: "ttys030", comm: "-zsh"),
        ])
        XCTAssertNil(TerminalSynthesizer.owner(ofPid: 801, processTable: processes, terminalPids: [500: .ghostty]))
    }

    // MARK: - Owned window resolution

    func testSingleTitledWindowIsAttributedAtWindowLevel() {
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Ghostty", pid: 500, title: "zsh"),
            11: window(11, app: "Ghostty", pid: 500, title: ""),   // hidden helper window
        ]
        let result = TerminalSynthesizer.resolveOwnedWindow(
            owner: TerminalOwner(app: .ghostty, pid: 500), cwd: "/tmp/somewhere", allWindows: windows)
        XCTAssertEqual(result.window?.wid, 10)
        XCTAssertEqual(result.attribution, .singleWindow)
    }

    func testTitleNamingTheCwdPicksOneOfSeveralWindows() {
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Ghostty", pid: 500, title: "mini: lattices-try"),
            11: window(11, app: "Ghostty", pid: 500, title: "/Users/test/dev/lattices"),
            12: window(12, app: "Ghostty", pid: 500, title: "claude"),
        ]
        let result = TerminalSynthesizer.resolveOwnedWindow(
            owner: TerminalOwner(app: .ghostty, pid: 500), cwd: "/Users/test/dev/lattices", allWindows: windows)
        XCTAssertEqual(result.window?.wid, 11)
        XCTAssertEqual(result.attribution, .cwdTitle)
    }

    func testSeveralWindowsWithoutEvidenceStayAtAppLevel() {
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Warp", pid: 700, title: "zsh", zIndex: 3),
            11: window(11, app: "Warp", pid: 700, title: "claude", zIndex: 1),
            12: window(12, app: "Safari", pid: 900, title: "zsh"),
        ]
        let result = TerminalSynthesizer.resolveOwnedWindow(
            owner: TerminalOwner(app: .warp, pid: 700), cwd: "/Users/test/dev/vox", allWindows: windows)
        XCTAssertNil(result.window)
        XCTAssertEqual(result.attribution, .app)
        XCTAssertEqual(result.candidates, [11, 10])
    }

    func testOwnerWithoutPidMatchesWindowsByApp() {
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Warp", pid: 700, title: "zsh", bundleId: "dev.warp.Warp-Stable"),
            12: window(12, app: "Terminal", pid: 900, title: "zsh"),
        ]
        let result = TerminalSynthesizer.resolveOwnedWindow(
            owner: TerminalOwner(app: .warp, pid: nil), cwd: nil, allWindows: windows)
        XCTAssertEqual(result.window?.wid, 10)
        XCTAssertEqual(result.attribution, .singleWindow)
    }

    func testTitleNamesRespectsPathBoundaries() {
        XCTAssertTrue(TerminalSynthesizer.titleNames("mini: ~/dev/lattices", fragment: "~/dev/lattices"))
        XCTAssertTrue(TerminalSynthesizer.titleNames("~/dev/lattices — zsh", fragment: "~/dev/lattices"))
        XCTAssertTrue(TerminalSynthesizer.titleNames("~/dev/lattices/apps", fragment: "~/dev/lattices"))
        XCTAssertFalse(TerminalSynthesizer.titleNames("~/dev/lattices-try", fragment: "~/dev/lattices"))
        XCTAssertTrue(TerminalSynthesizer.titleNames("~/dev/lattices-try ~/dev/lattices", fragment: "~/dev/lattices"))
        XCTAssertFalse(TerminalSynthesizer.titleNames("anything", fragment: ""))
    }

    // MARK: - Synthesis

    func testSynthesizeAttributesGhosttyTTYsFromTheProcessTree() {
        let processes = table(ghosttyTree())
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Ghostty", pid: 500, title: "/Users/test/dev/lattices"),
            11: window(11, app: "Ghostty", pid: 500, title: "claude"),
        ]
        let instances = TerminalSynthesizer.synthesize(
            processTable: processes, interesting: [], tmuxSessions: [], terminalTabs: [], windows: windows)
        let byTTY = Dictionary(uniqueKeysWithValues: instances.map { ($0.tty, $0) })

        // ttys010's cwd is named by one window title; ttys011's is not.
        XCTAssertEqual(byTTY["ttys010"]?.app, .ghostty)
        XCTAssertEqual(byTTY["ttys010"]?.windowId, 10)
        XCTAssertEqual(byTTY["ttys010"]?.windowAttribution, .cwdTitle)
        XCTAssertEqual(byTTY["ttys011"]?.app, .ghostty)
        XCTAssertNil(byTTY["ttys011"]?.windowId)
        XCTAssertEqual(byTTY["ttys011"]?.windowAttribution, .app)
        XCTAssertEqual(Set(byTTY["ttys011"]?.windowCandidates ?? []), [10, 11])
    }

    func testPromptWorkerShellsDoNotHideTheUsersShell() {
        // zsh prompt workers fork, reparent to launchd and sit in "/".
        let processes = table(ghosttyTree() + [
            proc(650, 1, tty: "ttys011", comm: "-zsh", cwd: "/"),
            proc(651, 650, tty: "ttys011", comm: "gitstatusd-darwin-arm64"),
        ])
        let windows: [UInt32: WindowEntry] = [10: window(10, app: "Ghostty", pid: 500, title: "zsh")]
        let instances = TerminalSynthesizer.synthesize(
            processTable: processes, interesting: [], tmuxSessions: [], terminalTabs: [], windows: windows)
        let inst = instances.first { $0.tty == "ttys011" }
        XCTAssertEqual(inst?.shellPid, 612)
        XCTAssertEqual(inst?.cwd, "/Users/test/dev/vox")
        XCTAssertEqual(inst?.app, .ghostty)
    }

    func testSynthesizeUsesGhosttyWindowTitleWhenUnique() {
        let processes = table(ghosttyTree())
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Ghostty", pid: 500, title: "build"),
            11: window(11, app: "Ghostty", pid: 500, title: "claude"),
        ]
        let tab = TerminalTab(
            app: .ghostty, windowId: nil, windowIndex: 0, tabIndex: 0, tty: "ttys011",
            isActiveTab: true, title: "claude", sessionId: "UUID-1", windowTitle: "claude")
        let instances = TerminalSynthesizer.synthesize(
            processTable: processes, interesting: [], tmuxSessions: [], terminalTabs: [tab], windows: windows)
        let inst = instances.first { $0.tty == "ttys011" }
        XCTAssertEqual(inst?.windowId, 11)
        XCTAssertEqual(inst?.windowAttribution, .terminalTitle)
        XCTAssertEqual(inst?.tabTitle, "claude")
        XCTAssertEqual(inst?.terminalSessionId, "UUID-1")
    }

    func testDuplicateGhosttyWindowTitlesFallBackToAppLevel() {
        let processes = table(ghosttyTree())
        let windows: [UInt32: WindowEntry] = [
            10: window(10, app: "Ghostty", pid: 500, title: "zsh"),
            11: window(11, app: "Ghostty", pid: 500, title: "zsh"),
        ]
        let tab = TerminalTab(
            app: .ghostty, windowId: nil, windowIndex: 1, tabIndex: 0, tty: "ttys011",
            isActiveTab: true, title: "zsh", sessionId: nil, windowTitle: "zsh")
        let instances = TerminalSynthesizer.synthesize(
            processTable: processes, interesting: [], tmuxSessions: [], terminalTabs: [tab], windows: windows)
        let inst = instances.first { $0.tty == "ttys011" }
        XCTAssertNil(inst?.windowId)
        XCTAssertEqual(inst?.windowAttribution, .app)
    }

    func testKittyPlatformWindowIdAttributesDirectly() {
        let windows: [UInt32: WindowEntry] = [
            42: window(42, app: "kitty", pid: 300, title: "vim"),
            43: window(43, app: "kitty", pid: 300, title: "zsh"),
        ]
        let tab = TerminalTab(
            app: .kitty, windowId: 43, windowIndex: 1, tabIndex: 0, tty: "ttys040",
            isActiveTab: true, title: "zsh", sessionId: "3")
        let processes = table([proc(301, 300, tty: "ttys040", comm: "-zsh")])
        let instances = TerminalSynthesizer.synthesize(
            processTable: processes, interesting: [], tmuxSessions: [], terminalTabs: [tab], windows: windows)
        XCTAssertEqual(instances.first?.windowId, 43)
        XCTAssertEqual(instances.first?.windowAttribution, .terminal)
    }

    // MARK: - Ghostty AppleScript output

    func testParseGhosttySurfaces() {
        let fs = "\u{1F}", rs = "\u{1E}"
        let raw = [
            ["0", "0", "true", "T-1", "/Users/test/dev/lattices", "zsh", "lattices", "mini: lattices"].joined(separator: fs),
            ["0", "1", "false", "T-2", "", "claude\twith tab", "claude", "mini: lattices"].joined(separator: fs),
            "garbage",
        ].joined(separator: rs) + rs
        let surfaces = TerminalQuery.parseGhosttySurfaces(raw)
        XCTAssertEqual(surfaces.count, 2)
        XCTAssertEqual(surfaces[0], GhosttySurface(
            windowIndex: 0, windowName: "mini: lattices", tabIndex: 0, tabName: "lattices",
            isSelectedTab: true, terminalId: "T-1", title: "zsh", workingDirectory: "/Users/test/dev/lattices"))
        XCTAssertEqual(surfaces[1].title, "claude\twith tab")
        XCTAssertEqual(surfaces[1].workingDirectory, "")
        XCTAssertFalse(surfaces[1].isSelectedTab)
    }

    func testAttributeGhosttyJoinsByUniqueCwd() {
        let surfaces = [
            GhosttySurface(windowIndex: 0, windowName: "w0", tabIndex: 0, tabName: "a", isSelectedTab: true,
                           terminalId: "T-1", title: "a", workingDirectory: "/Users/test/dev/lattices/"),
            GhosttySurface(windowIndex: 1, windowName: "w1", tabIndex: 0, tabName: "", isSelectedTab: true,
                           terminalId: "T-2", title: "vox title", workingDirectory: "file:///Users/test/dev/vox"),
            // Two surfaces share a cwd that two shells have: no guess.
            GhosttySurface(windowIndex: 1, windowName: "w1", tabIndex: 1, tabName: "x", isSelectedTab: false,
                           terminalId: "T-3", title: "x", workingDirectory: "/tmp/shared"),
            GhosttySurface(windowIndex: 1, windowName: "w1", tabIndex: 2, tabName: "y", isSelectedTab: false,
                           terminalId: "T-4", title: "y", workingDirectory: "/tmp/shared"),
        ]
        let shells = [
            TerminalShell(tty: "ttys010", cwds: ["/Users/test/dev/lattices"]),
            TerminalShell(tty: "ttys011", cwds: ["/Users/test/dev/vox"]),
            TerminalShell(tty: "ttys012", cwds: ["/tmp/shared"]),
            TerminalShell(tty: "ttys013", cwds: ["/tmp/shared"]),
        ]
        let tabs = TerminalQuery.attributeGhostty(surfaces: surfaces, shells: shells)
        let byId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.sessionId ?? "", $0) })
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(byId["T-1"]?.tty, "ttys010")
        XCTAssertEqual(byId["T-1"]?.windowTitle, "w0")
        XCTAssertEqual(byId["T-1"]?.app, .ghostty)
        XCTAssertNil(byId["T-1"]?.windowId)
        XCTAssertEqual(byId["T-2"]?.tty, "ttys011")
        XCTAssertEqual(byId["T-2"]?.title, "vox title")   // empty tab name falls back to the terminal title
    }

    func testTerminalShellsKeepsOnlyTTYsOwnedByTheTerminal() {
        let processes = table(ghosttyTree() + [
            proc(800, 1, comm: "tmux", args: "tmux new -d"),
            proc(801, 800, tty: "ttys030", comm: "-zsh"),
        ])
        let shells = TerminalQuery.terminalShells(ownedBy: [500], processTable: processes) { pids in
            var cwds: [Int: String] = [:]
            for pid in pids { if let cwd = processes[pid]?.cwd { cwds[pid] = cwd } }
            return cwds
        }
        XCTAssertEqual(shells.map(\.tty), ["ttys010", "ttys011"])
        XCTAssertEqual(shells.first?.cwds, ["/Users/test/dev/lattices"])
    }

    // MARK: - kitty remote control

    func testParseKittyLS() {
        let json = """
        [
          {"id": 1, "platform_window_id": 4242, "is_focused": true, "tabs": [
            {"id": 1, "title": "lattices", "is_active": true, "windows": [
              {"id": 7, "title": "nvim", "pid": 901, "cwd": "/Users/test/dev/lattices"},
              {"id": 8, "title": "", "pid": 902, "cwd": "/Users/test"}
            ]},
            {"id": 2, "title": "logs", "is_active": false, "windows": [
              {"id": 9, "title": "tail", "pid": 999, "cwd": "/var/log"}
            ]}
          ]}
        ]
        """
        let ttys = [901: "ttys050", 902: "ttys051"]
        let tabs = TerminalQuery.parseKittyLS(json) { ttys[$0] }
        XCTAssertEqual(tabs.count, 2)          // pid 999 has no TTY in the table
        XCTAssertEqual(tabs[0].windowId, 4242)
        XCTAssertEqual(tabs[0].tty, "ttys050")
        XCTAssertEqual(tabs[0].title, "nvim")
        XCTAssertEqual(tabs[0].sessionId, "7")
        XCTAssertTrue(tabs[0].isActiveTab)
        XCTAssertEqual(tabs[1].title, "lattices")   // empty window title falls back to the tab title
        XCTAssertEqual(TerminalQuery.parseKittyLS("not json") { _ in "ttys000" }.count, 0)
    }

    func testParseUnixSocketPaths() {
        let raw = "p300\nf5\nn/tmp/kitty-300\nf6\nn->0x1234\nf7\nn/tmp/kitty-300\nf8\nn\n"
        XCTAssertEqual(TerminalQuery.parseUnixSocketPaths(raw), ["/tmp/kitty-300"])
    }
}
