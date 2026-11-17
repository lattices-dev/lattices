import AppKit
import ApplicationServices

/// The recovery receipt is durable before the first AX mutation. This service
/// also runs without the UI, during SIGTERM and startup after a crash.
final class DesktopCanvasSession {
    struct Record: Codable {
        let id: UInt32
        let pid: Int32
        let launched: Date
        let frame: CGRect
        let minimized: Bool
        let space: Int
    }
    struct State { let frame: CGRect; let minimized: Bool; let launched: Date }
    struct Backend {
        var read: (UInt32, Int32) -> State?
        var spaces: (UInt32) -> [Int]
        var move: (UInt32, Int32, CGRect) -> Bool
        var minimize: (UInt32, Int32, Bool) -> Bool
        var exists: (UInt32, Int32, Date?) -> Bool?
        var recoveryFrame: (CGRect) -> CGRect = { $0 }
        var canManage: (UInt32, Int32) -> Bool = { _, _ in true }
    }
    static let shared = DesktopCanvasSession()
    let queue = DispatchQueue(label: "lattices.desktop-canvas", qos: .userInitiated)
    private let lock = NSRecursiveLock()
    private let url: URL
    private let backend: Backend
    private var records: [Record] = []
    private var loadError = false

    init(url: URL? = nil, backend: Backend = .native) {
        let base = ProcessInfo.processInfo.environment["LATTICES_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.lattices/run"
        self.url = url ?? URL(fileURLWithPath: base).appendingPathComponent("desktop-canvas-recovery.json")
        self.backend = backend
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: self.url)) }
            catch { loadError = true }
        }
    }

    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    /// The desktop inventory can retain a previous AX answer. Only admit a
    /// window after a live read and capability check, before promising a move.
    func candidateState(_ item: DesktopCanvasModel.Item, space: Int) -> State? {
        guard backend.spaces(item.id) == [space],
              let state = backend.read(item.id, item.pid),
              backend.canManage(item.id, item.pid) else {
            DiagnosticLog.shared.info("DesktopCanvas: excluded window=\(item.id) reason=unavailable")
            return nil
        }
        return state
    }

    final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    func apply(_ model: DesktopCanvasModel, screen: CGRect, space: Int, cancellation: Cancellation? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loadError, cancellation?.isCancelled != true else {
            DiagnosticLog.shared.warn("DesktopCanvas: apply rejected unreadable recovery journal")
            return false
        }
        DiagnosticLog.shared.info("DesktopCanvas: validating windows=\(model.items.count) space=\(space)")
        // Validate the entire batch and save every original before touching one.
        var states: [UInt32: State] = [:]
        for item in model.items {
            guard cancellation?.isCancelled != true else { return false }
            guard backend.spaces(item.id) == [space] else {
                DiagnosticLog.shared.warn("DesktopCanvas: validation failed window=\(item.id) reason=space")
                return false
            }
            guard let state = backend.read(item.id, item.pid) else {
                DiagnosticLog.shared.warn("DesktopCanvas: validation failed window=\(item.id) reason=accessibility")
                return false
            }
            states[item.id] = state
            if let original = records.first(where: { $0.id == item.id }) {
                guard original.pid == item.pid, original.launched == state.launched else { return false }
            } else {
                records.append(Record(id: item.id, pid: item.pid, launched: state.launched,
                                      frame: state.frame, minimized: state.minimized, space: space))
            }
        }
        guard save() else {
            DiagnosticLog.shared.warn("DesktopCanvas: apply rejected recovery journal write")
            return false
        }
        for item in model.items.reversed() {
            guard cancellation?.isCancelled != true else { return false }
            guard backend.spaces(item.id) == [space], let state = states[item.id] else { return false }
            if let frame = DesktopCanvasModel.physicalFrame(item.frame, viewport: model.viewport, screen: screen) {
                let visible = !state.minimized || backend.minimize(item.id, item.pid, false)
                guard cancellation?.isCancelled != true else { return false }
                let moved = visible && (state.frame == frame || backend.move(item.id, item.pid, frame))
                guard moved else {
                    DiagnosticLog.shared.warn("DesktopCanvas: placement failed window=\(item.id)")
                    return false
                }
            } else if !state.minimized && !backend.minimize(item.id, item.pid, true) {
                DiagnosticLog.shared.warn("DesktopCanvas: parking failed window=\(item.id)")
                return false
            }
        }
        return true
    }

    /// Closed windows and exited processes need no restoration. Reused PIDs or
    /// IDs are never mutated. Failed AX writes remain journaled for another try.
    @discardableResult func restore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loadError else { return false }
        var remaining: [Record] = []
        for record in records.reversed() {
            guard let state = backend.read(record.id, record.pid) else {
                // A still-running process can be temporarily unresponsive.
                if backend.exists(record.id, record.pid, record.launched) != false { remaining.append(record) }
                continue
            }
            guard state.launched == record.launched else { continue }
            let target = backend.recoveryFrame(record.frame)
            if state.frame == target && state.minimized == record.minimized { continue }
            let visible = !state.minimized || backend.minimize(record.id, record.pid, false)
            let moved = visible && (state.frame == target || backend.move(record.id, record.pid, target))
            let minimized = !record.minimized || backend.minimize(record.id, record.pid, true)
            if !moved || !minimized { remaining.append(record) }
        }
        records = remaining.reversed()
        guard save() else { return false }
        return records.isEmpty
    }

    /// The user chose to leave the remaining windows where they are. This is
    /// also the way out of an unreadable journal, whose originals are lost.
    @discardableResult func abandon() -> Bool {
        lock.lock(); defer { lock.unlock() }
        DiagnosticLog.shared.info("DesktopCanvas: abandoned recovery windows=\(records.map(\.id))")
        records = []
        guard save() else { return false }
        loadError = false
        return true
    }

    /// Apps that still own journaled windows, to name them to the user.
    var pendingApps: [String] {
        lock.lock(); defer { lock.unlock() }
        let names = records.map { NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? "pid \($0.pid)" }
        return Array(Set(names)).sorted()
    }

    func read(_ item: DesktopCanvasModel.Item) -> State? { backend.read(item.id, item.pid) }
    func exists(_ item: DesktopCanvasModel.Item) -> Bool? { backend.exists(item.id, item.pid, nil) }
    var recoverySpace: Int? {
        lock.lock(); defer { lock.unlock() }
        return records.first?.space
    }
}

extension DesktopCanvasSession.Backend {
    static let native = Self(read: { id, pid in
        guard let launched = NSRunningApplication(processIdentifier: pid)?.launchDate,
              let ax = EditorMutationJournal.axWindow(id, pid: pid),
              let frame = readFrame(ax) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else { return nil }
        return .init(frame: frame, minimized: minimized, launched: launched)
    }, spaces: { WindowTiler.getSpacesForWindow($0) }, move: { id, pid, frame in
        guard let ax = EditorMutationJournal.axWindow(id, pid: pid) else { return false }
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, dimensions)
        if waitForReadback({
            guard let actual = readFrame(ax) else { return false }
            return abs(actual.minX - frame.minX) < 4 && abs(actual.minY - frame.minY) < 4
                && abs(actual.width - frame.width) < 4 && abs(actual.height - frame.height) < 4
        }) { return true }
        // Aspect-locked or quantized windows (iPhone Mirroring) settle near,
        // never on, the requested size. Position is the contract; take the
        // size the app allows rather than journaling the window forever.
        guard let actual = readFrame(ax),
              abs(actual.minX - frame.minX) < 4, abs(actual.minY - frame.minY) < 4 else { return false }
        DiagnosticLog.shared.info("DesktopCanvas: size constrained window=\(id) wanted=\(frame.size) got=\(actual.size)")
        return true
    }, minimize: { id, pid, value in
        guard let ax = EditorMutationJournal.axWindow(id, pid: pid) else { return false }
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &current) == .success,
           (current as? Bool) == value { return true }
        guard AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success else { return false }
        return waitForReadback {
            current = nil
            return AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &current) == .success && (current as? Bool) == value
        }
    }, exists: { id, pid, launched in
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if let launched, launched != app.launchDate { return false }
        // AXWindows only describes the application's currently exposed windows.
        // A successful but empty result can mean another Space, not closure.
        let inventory = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        let owners = inventory.map { entries in
            entries.reduce(into: [UInt32: Int32]()) { result, entry in
                if let wid = entry[kCGWindowNumber as String] as? NSNumber,
                   let owner = entry[kCGWindowOwnerPID as String] as? NSNumber {
                    result[wid.uint32Value] = owner.int32Value
                }
            }
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        let windows = result == .success ? value as? [AXUIElement] : nil
        let ids = windows.map { windows in windows.compactMap { ax -> UInt32? in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(ax, &wid) == .success ? wid : nil
        } }
        return windowPresence(id: id, pid: pid, axIDs: ids, serverOwners: owners,
                              spaces: WindowTiler.getSpacesForWindow(id))
    }, recoveryFrame: { frame in
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return frame }
        let active = Array(ids.prefix(Int(count)))
        let main = CGMainDisplayID()
        let ordered = active.sorted { $0 == main && $1 != main }.map { CGDisplayBounds($0) }
        return DesktopCanvasModel.recoveryFrame(frame, displays: ordered)
    }, canManage: { id, pid in
        guard let ax = EditorMutationJournal.axWindow(id, pid: pid) else { return false }
        for attribute in [kAXPositionAttribute, kAXMinimizedAttribute] {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(ax, attribute as CFString, &settable) == .success,
                  settable.boolValue else { return false }
        }
        // Fixed-size windows such as Calculator still support moving/parking.
        return true
    })

    /// Positive global evidence wins over a Space-local AX omission. Retire a
    /// missing window only when both inventories completed and no Space owns it.
    static func windowPresence(id: UInt32, pid: Int32, axIDs: [UInt32]?,
                               serverOwners: [UInt32: Int32]?, spaces: [Int]) -> Bool? {
        if let owner = serverOwners?[id] { return owner == pid }
        if axIDs?.contains(id) == true || !spaces.isEmpty { return true }
        return axIDs != nil && serverOwners != nil ? false : nil
    }

    private static func waitForReadback(_ read: () -> Bool) -> Bool {
        for _ in 0..<20 {
            if read() { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return read()
    }

    private static func readFrame(_ ax: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
