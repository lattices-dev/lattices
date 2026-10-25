import Foundation

/// The physical desk: every monitor once, at its size in millimetres, placed
/// by stitching each host's arrangement through the monitors they share.
/// Pure; the inputs are plain values so any host's displays can feed it.
enum DeskLayout {
    struct Display: Equatable {
        /// The physical monitor (`model|serial`). Displays without one are not on the desk.
        var key: String?
        var model: String? = nil
        /// In the host's logical points, y down.
        var frame: CGRect
        var widthMm: Int? = nil
        var heightMm: Int? = nil
    }
    struct Host: Equatable {
        var name: String
        var displays: [Display]
    }
    enum Side: String { case left, right, above, below }
    /// Two monitors a host arranges differently from the desk.
    struct Pair: Hashable {
        var a: String
        var b: String
    }

    /// Without an EDID size, a typical desktop pixel pitch.
    static let mmPerPoint: CGFloat = 0.23
    /// Space between groups that share no host.
    static let gap: CGFloat = 100
    private static let epsilon: CGFloat = 0.5

    /// The first host is this one: its first desk monitor anchors the layout.
    /// User origins, in desk millimetres, win over the derived ones.
    static func stitch(hosts: [Host], origins: [String: CGPoint] = [:]) -> Desk {
        // Desk monitors in first-seen order, with the hosts cabled to each.
        var order: [String] = []
        var info: [String: (model: String?, size: CGSize, hosts: [String])] = [:]
        for host in hosts {
            for display in displays(of: host) {
                let key = display.key!
                if var entry = info[key] {
                    if entry.model == nil { entry.model = display.model }
                    if !entry.hosts.contains(host.name) { entry.hosts.append(host.name) }
                    info[key] = entry
                } else {
                    order.append(key)
                    info[key] = (display.model, size(display), [host.name])
                }
            }
        }
        // Prefer a measured size from any host over a derived one.
        for host in hosts {
            for display in displays(of: host) where display.widthMm != nil {
                info[display.key!]?.size = size(display)
            }
        }

        var placed: [String: CGRect] = [:]
        var bounds = CGRect.null
        for start in order where placed[start] == nil {
            var group: [String: CGRect] = [start: CGRect(origin: .zero, size: info[start]!.size)]
            var queue = [start]
            while !queue.isEmpty {
                let a = queue.removeFirst()
                for host in hosts {
                    let shown = displays(of: host)
                    guard let fa = shown.first(where: { $0.key == a })?.frame else { continue }
                    // Only a neighbour sharing an edge is placed from `a`; the
                    // rest of the row is reached through that neighbour.
                    for b in shown where group[b.key!] == nil && touches(fa, b.frame) {
                        let key = b.key!
                        group[key] = place(info[key]!.size, from: group[a]!, side: side(fa, b.frame),
                                           offset: offset(of: b.frame, from: fa, scaledTo: group[a]!))
                        queue.append(key)
                    }
                }
                // A display with a gap to every placed one: carry the gap over, scaled.
                if queue.isEmpty, let (host, b) = stray(hosts, group) {
                    let near = displays(of: host).filter { group[$0.key!] != nil }
                        .min { distance($0.frame, b.frame) < distance($1.frame, b.frame) }!
                    let to = group[near.key!]!
                    let o = offset(of: b.frame, from: near.frame, scaledTo: to)
                    group[b.key!] = CGRect(origin: CGPoint(x: to.minX + o.x, y: to.minY + o.y), size: info[b.key!]!.size)
                    queue.append(b.key!)
                }
            }
            // Each further group sits right of everything placed so far.
            let box = group.values.reduce(CGRect.null) { $0.union($1) }
            let target = bounds.isNull ? box.origin : CGPoint(x: bounds.maxX + gap, y: bounds.minY)
            for (key, rect) in group {
                placed[key] = rect.offsetBy(dx: target.x - box.minX, dy: target.y - box.minY)
            }
            bounds = bounds.union(group.values.reduce(CGRect.null) { $0.union($1) }
                .offsetBy(dx: target.x - box.minX, dy: target.y - box.minY))
        }
        // User origins share the derived frame, where the anchor sits at
        // (0,0), so they stay put relative to it as hosts come and go. The
        // whole desk, dragged monitors included, then starts at (0,0).
        for key in order { if let user = origins[key] { placed[key]!.origin = user } }
        let box = order.reduce(CGRect.null) { $0.union(placed[$1]!) }
        let shift = box.isNull ? .zero : CGPoint(x: -box.minX, y: -box.minY)
        let monitors = order.map { key -> DeskMonitor in
            let entry = info[key]!
            let rect = placed[key]!.offsetBy(dx: shift.x, dy: shift.y)
            return DeskMonitor(key: key, model: entry.model, size: rect.size, origin: rect.origin,
                               hosts: entry.hosts, source: origins[key] == nil ? .derived : .user)
        }
        return Desk(monitors: monitors, mismatches: mismatches(hosts: hosts, monitors: monitors), shift: shift)
    }

    /// Whether `b` shares an edge with `a`, overlapping along it.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlapX = b.minX < a.maxX - epsilon && b.maxX > a.minX + epsilon
        let overlapY = b.minY < a.maxY - epsilon && b.maxY > a.minY + epsilon
        let edgeX = abs(b.minX - a.maxX) <= epsilon || abs(b.maxX - a.minX) <= epsilon
        let edgeY = abs(b.minY - a.maxY) <= epsilon || abs(b.maxY - a.minY) <= epsilon
        return (edgeX && overlapY) || (edgeY && overlapX) || (overlapX && overlapY)
    }

    /// `b`'s offset from `a` in the host's points, scaled to `a`'s desk size.
    private static func offset(of b: CGRect, from a: CGRect, scaledTo desk: CGRect) -> CGPoint {
        CGPoint(x: (b.minX - a.minX) * desk.width / a.width, y: (b.minY - a.minY) * desk.height / a.height)
    }

    /// The first unplaced display of a host that has one placed.
    private static func stray(_ hosts: [Host], _ group: [String: CGRect]) -> (Host, Display)? {
        for host in hosts {
            let shown = displays(of: host)
            guard shown.contains(where: { group[$0.key!] != nil }),
                  let b = shown.first(where: { group[$0.key!] == nil }) else { continue }
            return (host, b)
        }
        return nil
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(0, max(a.minX - b.maxX, b.minX - a.maxX)), max(0, max(a.minY - b.maxY, b.minY - a.maxY)))
    }

    /// Where `b` sits relative to `a`. Overlapping or diagonal frames take
    /// the axis their centres differ along most.
    static func side(_ a: CGRect, _ b: CGRect) -> Side {
        let apartX = b.minX >= a.maxX - epsilon || b.maxX <= a.minX + epsilon
        let apartY = b.minY >= a.maxY - epsilon || b.maxY <= a.minY + epsilon
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        let horizontal = apartX != apartY ? apartX : abs(dx) >= abs(dy)
        return horizontal ? (dx < 0 ? .left : .right) : (dy < 0 ? .above : .below)
    }

    /// Per host with two or more desk monitors, the pairs whose side differs on the desk.
    static func mismatches(hosts: [Host], monitors: [DeskMonitor]) -> [String: [Pair]] {
        let desk = Dictionary(monitors.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a })
        var result: [String: [Pair]] = [:]
        for host in hosts {
            let shown = displays(of: host)
            guard shown.count >= 2 else { continue }
            var pairs: [Pair] = []
            for i in shown.indices {
                for j in shown.indices where j > i {
                    let a = shown[i], b = shown[j]
                    guard let da = desk[a.key!], let db = desk[b.key!] else { continue }
                    if side(a.frame, b.frame) != side(da, db) { pairs.append(Pair(a: a.key!, b: b.key!)) }
                }
            }
            if !pairs.isEmpty { result[host.name] = pairs }
        }
        return result
    }

    /// A host's desk monitors, each key once.
    private static func displays(of host: Host) -> [Display] {
        var seen = Set<String>()
        return host.displays.filter { display in
            guard let key = display.key, !key.isEmpty, display.frame.width > 0, display.frame.height > 0 else { return false }
            return seen.insert(key).inserted
        }
    }

    /// Measured when known, keeping the frame's aspect for a missing side.
    private static func size(_ display: Display) -> CGSize {
        let aspect = display.frame.height / display.frame.width
        switch (display.widthMm.flatMap { $0 > 0 ? $0 : nil }, display.heightMm.flatMap { $0 > 0 ? $0 : nil }) {
        case let (w?, h?): return CGSize(width: w, height: h)
        case let (w?, nil): return CGSize(width: CGFloat(w), height: CGFloat(w) * aspect)
        case let (nil, h?): return CGSize(width: CGFloat(h) / aspect, height: CGFloat(h))
        case (nil, nil): return CGSize(width: display.frame.width * mmPerPoint, height: display.frame.height * mmPerPoint)
        }
    }

    /// `b` edge to edge with `a`, offset along the other axis.
    private static func place(_ size: CGSize, from a: CGRect, side: Side, offset: CGPoint) -> CGRect {
        switch side {
        case .right: return CGRect(x: a.maxX, y: a.minY + offset.y, width: size.width, height: size.height)
        case .left: return CGRect(x: a.minX - size.width, y: a.minY + offset.y, width: size.width, height: size.height)
        case .below: return CGRect(x: a.minX + offset.x, y: a.maxY, width: size.width, height: size.height)
        case .above: return CGRect(x: a.minX + offset.x, y: a.minY - size.height, width: size.width, height: size.height)
        }
    }
}

struct DeskMonitor: Identifiable, Equatable {
    enum Source: String { case derived, user }
    var key: String
    var model: String?
    /// Millimetres, y down.
    var size: CGSize
    var origin: CGPoint
    /// Hosts cabled to it, in host order.
    var hosts: [String]
    var source: Source
    var id: String { key }
    var rect: CGRect { CGRect(origin: origin, size: size) }
}

struct Desk: Equatable {
    var monitors: [DeskMonitor]
    /// Host name → the monitor pairs it arranges differently from the desk.
    var mismatches: [String: [DeskLayout.Pair]]
    /// Added to a stored origin to place it on this desk; subtract it to store one.
    var shift: CGPoint = .zero
    var bounds: CGRect { monitors.reduce(CGRect.null) { $0.union($1.rect) } }
    func monitor(_ key: String) -> DeskMonitor? { monitors.first { $0.key == key } }
}

/// Origins the user dragged, by monitor key, relative to the anchor monitor's
/// derived position. They win over derived ones until reset. Version 1 kept
/// desk coordinates, which drift as hosts come and go, so it is dropped.
final class DeskStore: ObservableObject {
    static let shared = DeskStore()
    @Published private(set) var origins: [String: CGPoint]

    private struct Point: Codable { var x: Double; var y: Double }
    private struct Stored: Codable {
        var version = 2
        var origins: [String: Point]
    }
    private let defaults: UserDefaults
    private static let storeKey = "desk.layout"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 2 {
            origins = stored.origins.mapValues { CGPoint(x: $0.x, y: $0.y) }
        } else {
            origins = [:]
        }
    }

    func set(_ key: String, origin: CGPoint) {
        origins[key] = origin
        save()
    }

    /// The whole map as last seen, so one move pins every monitor where it
    /// was drawn. Monitors not on the desk right now keep their old entry.
    func set(_ next: [String: CGPoint]) {
        origins.merge(next) { $1 }
        save()
    }

    func reset() {
        origins = [:]
        defaults.removeObject(forKey: Self.storeKey)
    }

    private func save() {
        let stored = Stored(origins: origins.mapValues { Point(x: Double($0.x), y: Double($0.y)) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}
