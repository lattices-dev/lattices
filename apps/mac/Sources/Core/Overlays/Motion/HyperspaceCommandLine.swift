import Foundation

/// The `:` command line in Hyperspace. Parsing and matching are pure;
/// MotionPanel runs the command against the live desktop.
enum HyperspaceCommandLine {
    enum Command: Equatable {
        case pick(String), only(String), drop(String), all, clear
        case go(String)
        case grid(columns: Int, rows: Int)
        case balanced, columns, rows
        case main(leading: Bool)
        case place(PlacementSpec, name: String)
        case fill, swap
        case layer(String), save, tabs
        case undo, apply(leave: Bool), quit
    }

    struct Verb {
        let names: [String]
        let usage: String
        let argument: Argument
        enum Argument { case none, optional, required }
        var name: String { names[0] }
    }

    /// Order is completion order, so the common verbs come first.
    static let verbs: [Verb] = [
        .init(names: ["go", "goto"], usage: "go <app, title, tab or dir>", argument: .required),
        .init(names: ["pick", "p"], usage: "pick <app or title>", argument: .required),
        .init(names: ["only", "o"], usage: "only <app or title>", argument: .required),
        .init(names: ["drop", "d"], usage: "drop <app or title>", argument: .required),
        .init(names: ["all", "a"], usage: "all · picks every window here", argument: .none),
        .init(names: ["clear", "c"], usage: "clear · drops every pick", argument: .none),
        .init(names: ["grid", "g"], usage: "grid [3x2] · grids the picks", argument: .optional),
        .init(names: ["columns", "cols"], usage: "columns · side by side", argument: .none),
        .init(names: ["rows"], usage: "rows · stacked", argument: .none),
        .init(names: ["main", "mainl"], usage: "main · first pick large on the left", argument: .none),
        .init(names: ["mainr"], usage: "mainr · first pick large on the right", argument: .none),
        .init(names: ["left", "l", "right", "r", "top", "bottom", "max", "full", "center",
                      "tl", "tr", "bl", "br", "l3", "c3", "r3"],
              usage: "left · right · top · bottom · max · tl · l3 · 3x2:1,1", argument: .none),
        .init(names: ["fill", "f"], usage: "fill · grows the picks into open space", argument: .none),
        .init(names: ["swap", "s"], usage: "swap · trades the first two picks", argument: .none),
        .init(names: ["layer", "ly"], usage: "layer <name> · picks a layer's windows", argument: .required),
        .init(names: ["save"], usage: "save · saves the picks as a layer", argument: .none),
        .init(names: ["tabs", "t"], usage: "tabs · stacks the picks as tabs", argument: .none),
        .init(names: ["undo", "u"], usage: "undo · reverts the last arrangement", argument: .none),
        .init(names: ["apply", "w"], usage: "apply · moves the windows, stays here", argument: .none),
        .init(names: ["wq", "x"], usage: "wq · moves the windows and leaves", argument: .none),
        .init(names: ["quit", "q", "q!"], usage: "quit · restores and leaves", argument: .none),
    ]

    private static let placements: [String: String] = [
        "l": "left", "r": "right", "max": "maximize", "full": "maximize",
        "tl": "top-left", "tr": "top-right", "bl": "bottom-left", "br": "bottom-right",
        "l3": "left-third", "c3": "center-third", "r3": "right-third",
    ]

    struct Failure: Error, Equatable { let message: String }

    static func parse(_ raw: String) -> Result<Command, Failure> {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .failure(.init(message: "Type a command")) }
        let head = line.prefix { $0 != " " }.lowercased()
        let rest = line.dropFirst(head.count).trimmingCharacters(in: .whitespaces)

        func needs(_ make: (String) -> Command) -> Result<Command, Failure> {
            rest.isEmpty ? .failure(.init(message: "\(head) needs a name")) : .success(make(rest))
        }

        switch head {
        case "go", "goto": return needs { .go($0) }
        case "pick", "p": return needs { .pick($0) }
        case "only", "o": return needs { .only($0) }
        case "drop", "d": return needs { .drop($0) }
        case "all", "a": return .success(.all)
        case "clear", "c": return .success(.clear)
        case "grid", "g":
            if rest.isEmpty { return .success(.balanced) }
            let dims = rest.lowercased().split(separator: "x")
            guard dims.count == 2, let c = Int(dims[0]), let r = Int(dims[1]),
                  (1...12).contains(c), (1...12).contains(r) else {
                return .failure(.init(message: "grid takes a size like 3x2"))
            }
            return .success(.grid(columns: c, rows: r))
        case "columns", "cols": return .success(.columns)
        case "rows": return .success(.rows)
        case "main", "mainl": return .success(.main(leading: true))
        case "mainr": return .success(.main(leading: false))
        case "fill", "f": return .success(.fill)
        case "swap", "s": return .success(.swap)
        case "layer", "ly": return needs { .layer($0) }
        case "save": return .success(.save)
        case "tabs", "t": return .success(.tabs)
        case "undo", "u": return .success(.undo)
        case "apply", "w": return .success(.apply(leave: false))
        case "wq", "x": return .success(.apply(leave: true))
        case "quit", "q", "q!": return .success(.quit)
        default:
            let name = placements[head] ?? head
            if let spec = PlacementSpec(string: name) { return .success(.place(spec, name: head)) }
            return .failure(.init(message: "No command \"\(head)\""))
        }
    }

    /// The verb the line is typing, for the usage hint.
    static func verb(for line: String) -> Verb? {
        let head = line.trimmingCharacters(in: .whitespaces).prefix { $0 != " " }.lowercased()
        guard !head.isEmpty else { return nil }
        return verbs.first { $0.names.contains(head) }
            ?? verbs.first { $0.names.contains { $0.hasPrefix(head) } }
    }

    /// Full-line completions for Tab. The verb completes first; then the
    /// argument completes from `arguments` (app names, layer names).
    static func completions(for line: String, arguments: [String]) -> [String] {
        guard let space = line.firstIndex(of: " ") else {
            let head = line.lowercased()
            return unique(verbs.flatMap(\.names).filter { $0.count > 2 && $0.hasPrefix(head) && $0 != head })
        }
        let head = String(line[..<space])
        let partial = line[line.index(after: space)...].lowercased()
        return unique(arguments.filter { $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial }
            + arguments.filter { !$0.lowercased().hasPrefix(partial) && $0.lowercased().contains(partial) })
            .map { "\(head) \($0)" }
    }

    struct Candidate: Equatable {
        let wid: UInt32
        let app: String
        let title: String
        /// Extra searchable text: terminal cwd, tab titles, tmux sessions.
        var extra: [String] = []
    }

    /// Every word of the query must appear in the window's app, title or extra
    /// text. Exact app names rank first, then title hits, then extra hits.
    /// Only the best-scoring tier comes back, in the given (front-to-back) order.
    static func matches(_ query: String, in candidates: [Candidate]) -> [Candidate] {
        let scored = score(query, in: candidates)
        guard let top = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 == top }.sorted { $0.2 < $1.2 }.map(\.0)
    }

    /// Every match, best first, for the suggestion list. An empty query
    /// lists every candidate front to back.
    static func ranked(_ query: String, in candidates: [Candidate]) -> [Candidate] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return candidates }
        return score(query, in: candidates).sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }.map(\.0)
    }

    private static func score(_ query: String, in candidates: [Candidate]) -> [(Candidate, Int, Int)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return candidates.enumerated().compactMap { index, c in
            let app = c.app.lowercased(), title = c.title.lowercased()
            let extra = c.extra.map { $0.lowercased() }
            var score = 0
            for word in words {
                if app == word { score += 4 }
                else if app.hasPrefix(word) { score += 3 }
                else if app.contains(word) || title.contains(word) { score += 2 }
                else if extra.contains(where: { $0.contains(word) }) { score += 1 }
                else { return nil }
            }
            return (c, score, index)
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Spatial keyboard aim: the nearest window whose centre lies in the direction,
/// weighting sideways drift twice as heavily as travel.
enum HyperspaceSpatialAim {
    enum Direction { case left, right, up, down }

    /// Frames are AppKit (y up). Returns the index into `frames`.
    static func next(from current: CGRect, direction: Direction, among frames: [CGRect]) -> Int? {
        let origin = CGPoint(x: current.midX, y: current.midY)
        var best: (Int, CGFloat)?
        for (index, frame) in frames.enumerated() {
            let dx = frame.midX - origin.x, dy = frame.midY - origin.y
            let (travel, drift): (CGFloat, CGFloat) = switch direction {
            case .right: (dx, dy)
            case .left: (-dx, dy)
            case .up: (dy, dx)
            case .down: (-dy, dx)
            }
            guard travel > 8 else { continue }
            let cost = travel + 2 * abs(drift)
            if best == nil || cost < best!.1 { best = (index, cost) }
        }
        return best?.0
    }
}
