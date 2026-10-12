import AppKit

/// Puts the desktop back the way a recorded map has it, as far as macOS
/// lets an app: windows go back to their desktop (by Mission Control carry)
/// and their frame. It never changes the display arrangement or which
/// display is main; a difference there is reported instead. Desktops are
/// matched by position on their display, since desktop ids change on reboot,
/// and windows by id, then app and title, then app and tmux session.
enum StateRestore {
    struct Live: Equatable {
        var displays: [StateMap.Display]
        var windows: [Live.Window]

        struct Window: Equatable {
            var wid: UInt32
            var pid: Int32
            var app: String
            var title: String
            var session: String?
            var frame: StateMap.Rect
            var desktops: [Int]
        }
    }

    struct Move: Equatable {
        var wid: UInt32
        var pid: Int32
        var app: String
        var title: String
        /// The desktop to carry it to; nil when it's already there.
        var carryTo: Int?
        var frame: StateMap.Rect
    }

    struct Plan: Equatable {
        var moves: [Move] = []
        /// Windows in the map that aren't open now.
        var missing: [String] = []
        var notes: [String] = []
    }

    // MARK: Planning

    static func plan(_ map: StateMap, live: Live) -> Plan {
        var plan = Plan()
        let liveDisplays = Dictionary(live.displays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for display in map.displays {
            guard let now = liveDisplays[display.id] else {
                plan.notes.append("\(display.name) isn't connected; its windows stay where they are")
                continue
            }
            if display.main && !now.main {
                plan.notes.append("\(display.name) was the main display; Lattices leaves display settings alone")
            }
            if now.desktops.count < display.desktops.count {
                plan.notes.append("\(display.name) had \(display.desktops.count) desktops, now \(now.desktops.count); windows past desktop \(now.desktops.count) go to the last one")
            }
        }

        // Ids first, across every window, so a closed window's title can't
        // claim a live one that's still there under its own id.
        var found: [UInt32: Live.Window] = [:]
        for want in map.windows {
            if let same = live.windows.first(where: { $0.wid == want.wid && $0.app == want.app }) { found[want.wid] = same }
        }
        var taken = Set(found.values.map(\.wid))
        let rest = map.windows.filter { found[$0.wid] == nil }
            .sorted { a, b in (a.session != nil ? 0 : 1, a.wid) < (b.session != nil ? 0 : 1, b.wid) }
        for want in rest {
            if let match = match(want, in: live.windows, excluding: taken) {
                found[want.wid] = match
                taken.insert(match.wid)
            }
        }

        for want in map.windows {
            guard let found = found[want.wid] else {
                plan.missing.append(label(want.app, want.title))
                continue
            }
            guard let (display, index) = locate(want.desktops, in: map.displays),
                  let now = liveDisplays[display.id], !now.desktops.isEmpty else { continue }
            let target = now.desktops[min(index, now.desktops.count - 1)]
            let frame = StateMap.Rect(
                x: want.frame.x - display.frame.x + now.frame.x,
                y: want.frame.y - display.frame.y + now.frame.y,
                w: want.frame.w, h: want.frame.h
            )
            let carry = found.desktops.contains(target) ? nil : target
            guard carry != nil || !same(frame, found.frame) else { continue }
            plan.moves.append(Move(wid: found.wid, pid: found.pid, app: found.app, title: found.title, carryTo: carry, frame: frame))
        }
        return plan
    }

    static func match(_ want: StateMap.Window, in live: [Live.Window], excluding taken: Set<UInt32>) -> Live.Window? {
        let open = live.filter { !taken.contains($0.wid) && $0.app == want.app }
        if let same = open.first(where: { $0.wid == want.wid }) { return same }
        if let session = want.session, let bySession = open.first(where: { $0.session == session }) { return bySession }
        if !want.title.isEmpty, let byTitle = open.first(where: { $0.title == want.title }) { return byTitle }
        return open.count == 1 ? open[0] : nil
    }

    /// The display a window sat on and its desktop's position there.
    static func locate(_ desktops: [Int], in displays: [StateMap.Display]) -> (StateMap.Display, Int)? {
        for display in displays {
            if let index = display.desktops.firstIndex(where: { desktops.contains($0) }) {
                return (display, index)
            }
        }
        return nil
    }

    private static func same(_ a: StateMap.Rect, _ b: StateMap.Rect) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 && abs(a.w - b.w) < 2 && abs(a.h - b.h) < 2
    }

    static func label(_ app: String, _ title: String) -> String {
        title.isEmpty ? app : "\(app): \(title)"
    }

    // MARK: Applying

    /// Reads what's on screen now. Call on the main thread.
    static func live() -> Live {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = StateHistory.capture()
        let pids = Dictionary(DesktopModel.shared.refreshNow().map { ($0.wid, $0.pid) }, uniquingKeysWith: { a, _ in a })
        return Live(
            displays: now.displays,
            windows: now.windows.compactMap { w in
                guard let pid = pids[w.wid] else { return nil }
                return Live.Window(wid: w.wid, pid: pid, app: w.app, title: w.title, session: w.session, frame: w.frame, desktops: w.desktops)
            }
        )
    }

    /// Records the current state as "before-restore", then carries and
    /// places. Carries block for seconds each, so this runs off the main
    /// thread; `done` gets the windows it couldn't put back.
    static func apply(_ plan: Plan, map: StateMap, done: (([String]) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        StateHistory.shared.record(name: "before-restore")
        let log = DiagnosticLog.shared
        log.info("Restore \(map.id): \(plan.moves.count) window(s), \(plan.moves.filter { $0.carryTo != nil }.count) across desktops")
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for move in plan.moves {
                guard let target = move.carryTo else { continue }
                if case .failed(let reason) = WindowSpaceCarry.carry(wid: move.wid, pid: move.pid, to: target) {
                    failed.append("\(label(move.app, move.title)) (\(reason))")
                }
            }
            DispatchQueue.main.async {
                _ = DesktopModel.shared.refreshNow()
                WindowTiler.batchMoveAndRaiseWindows(
                    plan.moves.map { (wid: $0.wid, pid: $0.pid, frame: CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h)) },
                    activation: .frontmostOnly
                )
                if failed.isEmpty {
                    log.success("Restore \(map.id): done")
                } else {
                    log.warn("Restore \(map.id): couldn't carry \(failed.joined(separator: ", "))")
                }
                done?(failed)
            }
        }
    }
}
