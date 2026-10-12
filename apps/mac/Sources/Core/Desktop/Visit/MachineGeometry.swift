import Foundation

/// All coordinates are CG global display points (top-left origin).
enum MachineGeometry {
    struct Placement: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double = 1920
        var height: Double = 1080
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
        init(x: Double, y: Double, width: Double = 1920, height: Double = 1080) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    }
    struct Contact: Equatable {
        var side: VisitTrust.Side
        var lower: Double
        var upper: Double
        func contains(_ point: CGPoint) -> Bool {
            let value = side == .left || side == .right ? point.y : point.x
            return value >= lower && value < upper
        }
        func fraction(_ point: CGPoint) -> Double {
            let value = side == .left || side == .right ? point.y : point.x
            return min(1, max(0, (value - lower) / (upper - lower)))
        }
        func span(in display: CGRect) -> CGRect {
            var r = display
            if side == .left || side == .right { r.origin.y = lower; r.size.height = upper - lower }
            else { r.origin.x = lower; r.size.width = upper - lower }
            return r
        }
    }
    static func entry(displays: [CGRect], machine: CGRect) -> (display: CGRect, side: VisitTrust.Side, point: CGPoint)? {
        for display in displays {
            if let contact = contacts(display: display, machine: machine).first {
                let middle = (contact.lower + contact.upper) / 2
                let point: CGPoint
                switch contact.side {
                case .left: point = CGPoint(x: display.minX, y: middle)
                case .right: point = CGPoint(x: display.maxX - 0.5, y: middle)
                case .top: point = CGPoint(x: middle, y: display.minY)
                case .bottom: point = CGPoint(x: middle, y: display.maxY - 0.5)
                }
                return (display, contact.side, point)
            }
        }
        return nil
    }
    static func contacts(display d: CGRect, machine m: CGRect) -> [Contact] {
        var result: [Contact] = []
        let y0 = max(d.minY, m.minY), y1 = min(d.maxY, m.maxY)
        let x0 = max(d.minX, m.minX), x1 = min(d.maxX, m.maxX)
        if y1 > y0 {
            if abs(d.maxX - m.minX) < 1 { result.append(.init(side: .right, lower: y0, upper: y1)) }
            if abs(d.minX - m.maxX) < 1 { result.append(.init(side: .left, lower: y0, upper: y1)) }
        }
        if x1 > x0 {
            if abs(d.maxY - m.minY) < 1 { result.append(.init(side: .bottom, lower: x0, upper: x1)) }
            if abs(d.minY - m.maxY) < 1 { result.append(.init(side: .top, lower: x0, upper: x1)) }
        }
        return result
    }
    static func owner(at point: CGPoint, side: VisitTrust.Side, display: CGRect,
                      machines: [(String, CGRect)]) -> (String, Contact)? {
        for (name, rect) in machines.sorted(by: { $0.0 < $1.0 }) {
            if let contact = contacts(display: display, machine: rect).first(where: { $0.side == side && $0.contains(point) }) {
                return (name, contact)
            }
        }
        return nil
    }
    static func migrate(side: VisitTrust.Side, displays: [CGRect], size: CGSize = CGSize(width: 1920, height: 1080)) -> CGRect {
        let sorted = displays.sorted {
            switch side {
            case .left: return $0.minX < $1.minX
            case .right: return $0.maxX > $1.maxX
            case .top: return $0.minY < $1.minY
            case .bottom: return $0.maxY > $1.maxY
            }
        }
        let d = sorted.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        switch side {
        case .left: return CGRect(x: d.minX - size.width, y: d.midY - size.height / 2, width: size.width, height: size.height)
        case .right: return CGRect(x: d.maxX, y: d.midY - size.height / 2, width: size.width, height: size.height)
        case .top: return CGRect(x: d.midX - size.width / 2, y: d.minY - size.height, width: size.width, height: size.height)
        case .bottom: return CGRect(x: d.midX - size.width / 2, y: d.maxY, width: size.width, height: size.height)
        }
    }
    static func snap(_ rect: CGRect, to displays: [CGRect], tolerance: Double) -> CGRect {
        var candidates: [(Double, CGRect)] = []
        for d in displays {
            for x in [d.minX - rect.width, d.maxX] where abs(x - rect.minX) <= tolerance {
                let r = CGRect(x: x, y: rect.minY, width: rect.width, height: rect.height)
                if r.maxY > d.minY && r.minY < d.maxY { candidates.append((abs(x - rect.minX), r)) }
            }
            for y in [d.minY - rect.height, d.maxY] where abs(y - rect.minY) <= tolerance {
                let r = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
                if r.maxX > d.minX && r.minX < d.maxX { candidates.append((abs(y - rect.minY), r)) }
            }
        }
        return candidates.filter { candidate in !displays.contains { $0.intersection(candidate.1).width > 0 && $0.intersection(candidate.1).height > 0 } }
            .min(by: { $0.0 < $1.0 })?.1 ?? rect
    }
}
