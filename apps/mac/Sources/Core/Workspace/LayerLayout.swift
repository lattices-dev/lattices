import CoreGraphics
import LatticesLayoutKit

/// Where a layer's windows go on its display, for the layer's `layout`, as
/// unit rects with y = 0 at the top. Native names and app classification adapt
/// to the value-only planner in LatticesLayoutKit.
///
/// `auto` sorts windows into lanes by app type: terminals and chat on the
/// left, editors and design in the middle, browsers and the rest on the
/// right. On an ultrawide each lane gets a column and stacks its windows; on
/// a standard display the main window takes the left half and the rest stack
/// on the right. A lone window sits centred at half width on an ultrawide,
/// and fills a standard display.
enum LayerLayout {
    enum Kind: Equatable {
        case auto
        /// Equal columns in entry order, each stacking its windows.
        case columns
        /// The first window on the left, the rest stacked on the right.
        case masterStack

        init?(_ name: String) {
            switch name.lowercased() {
            case "auto", "smart": self = .auto
            case "columns", "cols": self = .columns
            case "master-stack", "master", "main": self = .masterStack
            default: return nil
            }
        }

        /// What a layer's `layout` stores for it.
        var name: String {
            switch self {
            case .auto: return "auto"
            case .columns: return "columns"
            case .masterStack: return "master-stack"
            }
        }

        var title: String {
            switch self {
            case .auto: return "Auto"
            case .columns: return "Columns"
            case .masterStack: return "Master-stack"
            }
        }
    }

    /// The layouts the preview's L steps through, after none.
    static let cycle: [Kind] = [.auto, .columns, .masterStack]

    /// The layout after `name`: none, auto, columns, master-stack, then none
    /// again. A name it doesn't know goes to auto.
    static func next(after name: String?) -> String? {
        guard let name else { return cycle.first?.name }
        guard let kind = Kind(name), let at = cycle.firstIndex(of: kind) else { return Kind.auto.name }
        return at + 1 < cycle.count ? cycle[at + 1].name : nil
    }

    /// A layout as the preview names it. With none, a layer raises its
    /// windows where they are.
    static func title(_ name: String?) -> String {
        guard let name else { return "In place" }
        return Kind(name)?.title ?? name
    }

    typealias Lane = LayerLayoutPlanner.Lane

    static let ultrawide = LayerLayoutPlanner.ultrawide
    static let masterRatio = LayerLayoutPlanner.masterRatio
    static let laneWidths = LayerLayoutPlanner.laneWidths

    static func lane(for type: AppType) -> Lane {
        switch type {
        case .terminal, .chat: return .left
        case .editor, .design: return .middle
        case .browser, .media, .system, .other: return .right
        }
    }

    static func frames(_ kind: Kind, types: [AppType], aspect: CGFloat) -> [CGRect] {
        LayerLayoutPlanner.frames(plannerKind(kind), lanes: types.map { lane(for: $0) }, aspect: aspect)
    }

    private static func plannerKind(_ kind: Kind) -> LayerLayoutPlanner.Kind {
        switch kind {
        case .auto: return .auto
        case .columns: return .columns
        case .masterStack: return .masterStack
        }
    }

    struct PlannedWindow {
        let entry: WindowEntry
        let frame: CGRect
    }

    /// Native arrange, forecast and Editor preview share this adapter. Only
    /// immutable values cross the module boundary; no live desktop reads occur.
    static func plan(_ kind: Kind, members: [LayerMembership.Member], excluding: Set<UInt32>,
                     main: CGRect, otherDisplays: [CGRect], currentSpace: Int,
                     visibleFrame: CGRect, standardWindows: Set<UInt32>) -> [PlannedWindow] {
        let candidates = members.map { member in
            let entry = member.entry
            return LayerLayoutPlanner.Candidate(
                windowID: entry.wid,
                frame: CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.w, height: entry.frame.h),
                spaceIDs: entry.spaceIds, isPlaced: member.placed, hasTitle: entry.hasTitle,
                lane: lane(for: AppTypeClassifier.classify(entry.app))
            )
        }
        let context = LayerLayoutPlanner.Context(
            mainBounds: main, otherDisplayBounds: otherDisplays, currentSpaceID: currentSpace,
            visibleFrame: visibleFrame, excludedWindowIDs: excluding, standardWindowIDs: standardWindows
        )
        return LayerLayoutPlanner.plan(plannerKind(kind), candidates: candidates, context: context).map {
            PlannedWindow(entry: members[$0.inputIndex].entry, frame: $0.frame)
        }
    }
}
