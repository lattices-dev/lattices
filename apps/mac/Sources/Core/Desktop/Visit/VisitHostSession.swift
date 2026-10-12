import Foundation

/// Protocol reducer. No sockets, defaults, windows or input events; effects are
/// executed by the receiving host only after authenticated frame validation.
struct VisitHostSession {
    enum Effect: Equatable {
        case show(String, CGPoint), move(CGPoint), button(String, Bool, CGPoint)
        case scroll(Double, Double, CGPoint), key(String, [String]), text(String)
        case reply(String, String?, Double?), end
    }
    var displays: [CGRect]
    private(set) var position: CGPoint?
    private(set) var edge: VisitTrust.Side?
    private(set) var held: Set<String> = []
    var area: CGRect { displays.reduce(CGRect.null) { $0.union($1) } }
    mutating func finish() -> [Effect] {
        let releases = held.sorted().map { Effect.button($0, false, position ?? .zero) }
        position = nil; edge = nil; held = []
        return releases + [.end]
    }
    mutating func handle(_ m: [String: Any]) throws -> [Effect] {
        func bad() -> VisitTrust.Failure { .bad("Invalid visit message") }
        func number(_ key: String) throws -> Double {
            guard let n = m[key] as? Double, n.isFinite, abs(n) <= 1_000_000 else { throw bad() }; return n
        }
        guard let t = m["t"] as? String else { throw bad() }
        if t == "ping" { return [.reply("pong", nil, nil)] }
        if t == "leave" { return finish() }
        if t == "enter" {
            guard position == nil, !displays.isEmpty,
                  let raw = m["edge"] as? String, let side = VisitTrust.Side(rawValue: raw),
                  let name = m["name"] as? String, !name.isEmpty, name.count <= 128 else { throw bad() }
            let at = try number("at")
            guard (0...1).contains(at) else { throw bad() }
            edge = side
            position = nearest(VisitController.point(on: side, of: area, at: at))
            return [.show(name, position!), .reply("ready", nil, nil)]
        }
        guard let p = position, let side = edge else { throw bad() }
        switch t {
        case "move":
            let q = CGPoint(x: p.x + (try number("dx")), y: p.y + (try number("dy")))
            let exits = side == .left ? q.x < area.minX : side == .right ? q.x >= area.maxX : side == .top ? q.y < area.minY : q.y >= area.maxY
            if exits {
                let vertical = side == .left || side == .right
                let at = min(1, max(0, vertical ? (q.y - area.minY) / area.height : (q.x - area.minX) / area.width))
                return [.reply("exit", side.rawValue, at)] + finish()
            }
            position = nearest(q); return [.move(position!)]
        case "button":
            guard let button = m["button"] as? String, ["left", "right", "middle"].contains(button), let down = m["down"] as? Bool else { throw bad() }
            if down { held.insert(button) } else { held.remove(button) }
            return [.button(button, down, p)]
        case "scroll": return [.scroll(try number("dx"), try number("dy"), p)]
        case "key":
            guard let key = m["key"] as? String, key.count <= 64, let mods = m["mods"] as? [String], mods.allSatisfy({ ["ctrl", "shift", "alt", "super"].contains($0) }) else { throw bad() }
            return [.key(key, mods)]
        case "text":
            guard let text = m["text"] as? String, text.utf8.count <= 16384 else { throw bad() }
            return [.text(text)]
        default: throw bad()
        }
    }
    private func nearest(_ p: CGPoint) -> CGPoint {
        displays.map { r in CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1)) }
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) } ?? p
    }
}
