import AppKit
import Combine

/// A full, immutable map of the desktop: displays, their desktops, and every
/// content window with its frame and desktop. One is written after each
/// change settles, so any earlier arrangement can be looked up again.
struct StateMap: Codable, Equatable {
    struct Rect: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double
    }

    struct Display: Codable, Equatable {
        /// The display's UUID, stable across reboots.
        var id: String
        var name: String
        /// Top-left global coordinates.
        var frame: Rect
        var main: Bool
        /// Desktop (CGS space) ids in Mission Control order.
        var desktops: [Int]
        var current: Int
    }

    struct Window: Codable, Equatable {
        var wid: UInt32
        var app: String
        var bundleId: String?
        var title: String
        var session: String?
        var frame: Rect
        var desktops: [Int]
        var hidden: Bool
    }

    var id: String
    var taken: Date
    /// Set for snapshots taken on purpose, e.g. before a risky operation.
    var name: String?
    var displays: [Display]
    var windows: [Window]
    var layer: Int?

    /// What makes two maps the same arrangement: geometry and placement,
    /// not titles, stacking or when they were taken.
    var fingerprint: String {
        var parts = displays.map { d in
            "D\(d.id)@\(Int(d.frame.x)),\(Int(d.frame.y)),\(Int(d.frame.w)),\(Int(d.frame.h))\(d.main ? "*" : "")[\(d.desktops.map(String.init).joined(separator: ","))]"
        }
        parts += windows.sorted { $0.wid < $1.wid }.map { w in
            "W\(w.wid)@\(Int(w.frame.x)),\(Int(w.frame.y)),\(Int(w.frame.w)),\(Int(w.frame.h))[\(w.desktops.map(String.init).joined(separator: ","))]\(w.hidden ? "h" : "")"
        }
        if let layer { parts.append("L\(layer)") }
        return parts.joined(separator: "|")
    }

    static func id(for date: Date, name: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = f.string(from: date)
        guard let name, !name.isEmpty else { return stamp }
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return stamp + "-" + String(safe.prefix(40))
    }
}

/// Keeps a couple of days of maps in `~/.lattices/states/`, one JSON file
/// each. Recording rides on DesktopModel's own updates and display/desktop
/// notifications, debounced, so it adds no polling of its own.
final class StateHistory {
    static let shared = StateHistory()

    static let retention: TimeInterval = 72 * 3600
    static let cap = 2000
    static let settle: TimeInterval = 1.0

    let directory: URL
    private let io = DispatchQueue(label: "com.arach.lattices.state-history", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var pending: DispatchWorkItem?
    private var lastFingerprint: String?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lattices/states", isDirectory: true)) {
        self.directory = directory
    }

    // MARK: Recording

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard cancellables.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lastFingerprint = (try? latest())?.fingerprint

        DesktopModel.shared.$windows
            .dropFirst()
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.record(name: nil) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Captures now. A named map is always written; an unnamed one only
    /// when the arrangement changed.
    @discardableResult
    func record(name: String?) -> StateMap? {
        dispatchPrecondition(condition: .onQueue(.main))
        let map = Self.capture(name: name)
        let print = map.fingerprint
        guard name != nil || print != lastFingerprint else { return nil }
        lastFingerprint = print
        io.async { [directory] in
            Self.write(map, to: directory)
            Self.prune(in: directory)
        }
        return map
    }

    static func capture(name: String? = nil, at date: Date = Date()) -> StateMap {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let displays: [StateMap.Display] = WindowTiler.getDisplaySpaces().map { d in
            let screen = DisplayGeometryMapper.screen(for: d, in: screens)
            let frame = screen.map { DisplayGeometryMapper.topLeftFrame($0.frame, primaryHeight: primaryHeight) } ?? .zero
            return StateMap.Display(
                id: d.displayId,
                name: screen?.localizedName ?? d.displayId,
                frame: rect(frame),
                main: screen != nil && screen === screens.first,
                desktops: d.spaces.map(\.id),
                current: d.currentSpaceId
            )
        }
        let windows = DesktopModel.shared.allWindows()
            .filter(DesktopModel.isContent)
            .map { w in
                StateMap.Window(
                    wid: w.wid, app: w.app, bundleId: w.bundleId,
                    title: w.fullTitle ?? w.title, session: w.latticesSession,
                    frame: StateMap.Rect(x: w.frame.x, y: w.frame.y, w: w.frame.w, h: w.frame.h),
                    desktops: w.spaceIds, hidden: w.appHidden
                )
            }
        let wm = WorkspaceManager.shared
        return StateMap(
            id: StateMap.id(for: date, name: name),
            taken: date,
            name: name,
            displays: displays,
            windows: windows,
            layer: wm.activeLayerSelection
        )
    }

    private static func rect(_ r: CGRect) -> StateMap.Rect {
        StateMap.Rect(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height)
    }

    // MARK: Storage

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func write(_ map: StateMap, to directory: URL) {
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: directory.appendingPathComponent(map.id + ".json"), options: .atomic)
    }

    /// Ids newest first. Ids sort by time since they start with a UTC stamp.
    func ids() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    func load(_ id: String) throws -> StateMap {
        let data = try Data(contentsOf: directory.appendingPathComponent(id + ".json"))
        return try Self.decoder.decode(StateMap.self, from: data)
    }

    /// An exact id, an id prefix, or a name; the newest match wins.
    func resolve(_ ref: String) -> String? {
        let ids = ids()
        if ids.contains(ref) { return ref }
        if let byPrefix = ids.first(where: { $0.hasPrefix(ref) }) { return byPrefix }
        let wanted = StateMap.id(for: Date(), name: ref).dropFirst(20)
        return ids.first { $0.count > 19 && $0.dropFirst(20) == wanted }
    }

    func latest() throws -> StateMap? {
        guard let id = ids().first else { return nil }
        return try load(id)
    }

    /// Which ids to delete: anything past the retention window, then the
    /// oldest unnamed ones beyond the cap. Named maps only age out.
    static func expired(_ ids: [String], now: Date, retention: TimeInterval = retention, cap: Int = cap) -> [String] {
        let oldest = StateMap.id(for: now.addingTimeInterval(-retention))
        let newestFirst = ids.sorted(by: >)
        var drop = newestFirst.filter { String($0.prefix(19)) < oldest }
        let kept = newestFirst.filter { !drop.contains($0) }
        let unnamed = kept.filter { $0.count == 19 }
        if kept.count > cap {
            drop += unnamed.suffix(min(unnamed.count, kept.count - cap))
        }
        return drop
    }

    private static func prune(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ids = names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        for id in expired(ids, now: Date()) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
        }
    }
}
