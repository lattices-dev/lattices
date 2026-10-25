import CoreGraphics
import Foundation

/// Owns optimization eligibility, scope resolution and distribution requests.
/// Inventory reads and queued desktop effects are supplied by the caller, so
/// the operation can be exercised without reading or moving live windows.
struct SpaceOptimizationService {
    typealias Target = (wid: UInt32, pid: Int32)
    typealias Region = (CGFloat, CGFloat, CGFloat, CGFloat)

    private let allWindows: () -> [WindowEntry]
    private let frontmostAppName: () -> String?
    private let enqueueDistribution: ([Target], Region?) -> Void

    init(allWindows: @escaping () -> [WindowEntry],
         frontmostAppName: @escaping () -> String?,
         enqueueDistribution: @escaping ([Target], Region?) -> Void) {
        self.allWindows = allWindows
        self.frontmostAppName = frontmostAppName
        self.enqueueDistribution = enqueueDistribution
    }

    /// Compatibility entry point for layout.distribute.
    func distribute(params: JSON?) throws -> JSON {
        var dict: [String: JSON] = [:]
        if case .object(let obj) = params {
            dict = obj
        }
        // Explicit filters select the matching scope automatically.
        if dict["app"] != nil && dict["scope"] == nil {
            dict["scope"] = .string("app")
        } else if dict["type"] != nil && dict["scope"] == nil {
            dict["scope"] = .string("type")
        } else {
            dict["scope"] = dict["scope"] ?? .string("visible")
        }
        dict["strategy"] = dict["strategy"] ?? .string("balanced")
        return try optimize(params: .object(dict))
    }

    func optimize(params: JSON?) throws -> JSON {
        let scope = try parseOptimizationScope(from: params)
        let strategy = try parseOptimizationStrategy(params?["strategy"]?.stringValue)
        var trace: [JSON] = [.string("resolved scope \(scope)"), .string("resolved strategy \(strategy)")]
        let windows = resolveOptimizationTargets(scope: scope, params: params, trace: &trace)

        // Resolve optional region constraint (e.g. "right" → right half of screen)
        var region: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil
        if let regionStr = params?["region"]?.stringValue {
            if let spec = PlacementSpec(string: regionStr) {
                region = spec.fractions
                trace.append(.string("region \(regionStr) → fractions \(spec.fractions)"))
            } else {
                trace.append(.string("unknown region \(regionStr), using full screen"))
            }
        }

        if strategy == "mosaic" {
            trace.append(.string("strategy mosaic currently uses the smart-grid distributor"))
        }

        guard !windows.isEmpty else {
            trace.append(.string("no eligible windows resolved"))
            return .object([
                "ok": .bool(true),
                "scope": .string(scope),
                "strategy": .string(strategy),
                "windowCount": .int(0),
                "wids": .array([]),
                "trace": .array(trace),
            ])
        }

        let targets = windows.map { (wid: $0.wid, pid: $0.pid) }
        enqueueDistribution(targets, region)

        return .object([
            "ok": .bool(true),
            "scope": .string(scope),
            "strategy": .string(strategy),
            "windowCount": .int(windows.count),
            "wids": .array(windows.map { .int(Int($0.wid)) }),
            "trace": .array(trace),
        ])
    }

    private func parseOptimizationScope(from params: JSON?) throws -> String {
        if params?["windowIds"] != nil {
            return "selection"
        }
        if params?["app"] != nil {
            return "app"
        }
        if params?["type"] != nil {
            return "type"
        }

        let scope = normalizeToken(params?["scope"]?.stringValue ?? "visible")
        switch scope {
        case "visible", "selection", "app", "type",
             "active-app", "frontmost-app", "current-app",
             "active-type", "frontmost-type", "current-type":
            return scope
        default:
            throw RouterError.custom("Unsupported optimization scope: \(params?["scope"]?.stringValue ?? scope)")
        }
    }

    private func parseOptimizationStrategy(_ raw: String?) throws -> String {
        let strategy = normalizeToken(raw ?? "balanced")
        switch strategy {
        case "balanced", "mosaic":
            return strategy
        default:
            throw RouterError.custom("Unsupported optimization strategy: \(raw ?? strategy)")
        }
    }

    private func resolveOptimizationTargets(scope: String, params: JSON?, trace: inout [JSON]) -> [WindowEntry] {
        let visible = distributableWindows()
        let titleFilter = params?["title"]?.stringValue

        switch scope {
        case "selection":
            let ids = selectedWindowIds(from: params?["windowIds"])
            trace.append(.string("selection size \(ids.count)"))
            return dedupeWindows(visible.filter { ids.contains($0.wid) })

        case "app":
            guard let app = params?["app"]?.stringValue else {
                trace.append(.string("missing app for app scope"))
                return []
            }
            trace.append(.string("filtered by app \(app)"))
            if let titleFilter {
                trace.append(.string("title contains \(titleFilter)"))
            }
            return dedupeWindows(visible.filter {
                $0.app.localizedCaseInsensitiveCompare(app) == .orderedSame &&
                (titleFilter == nil || $0.titleContains(titleFilter!))
            })

        case "type":
            guard let typeName = params?["type"]?.stringValue,
                  let appType = parseOptimizationAppType(typeName) else {
                trace.append(.string("missing or unknown type for type scope"))
                return []
            }
            trace.append(.string("filtered by type \(appType.rawValue)"))
            if let titleFilter {
                trace.append(.string("title contains \(titleFilter)"))
            }
            return dedupeWindows(visible.filter {
                AppTypeClassifier.matches($0.app, type: appType) &&
                (titleFilter == nil || $0.titleContains(titleFilter!))
            })

        case "active-app", "frontmost-app", "current-app":
            let activeApp = params?["app"]?.stringValue ?? frontmostOptimizableApp()
            guard let activeApp else {
                trace.append(.string("no active app available"))
                return []
            }
            trace.append(.string("resolved active app \(activeApp)"))
            if let titleFilter {
                trace.append(.string("title contains \(titleFilter)"))
            }
            return dedupeWindows(visible.filter {
                $0.app.localizedCaseInsensitiveCompare(activeApp) == .orderedSame &&
                (titleFilter == nil || $0.titleContains(titleFilter!))
            })

        case "active-type", "frontmost-type", "current-type":
            let activeApp = params?["app"]?.stringValue ?? frontmostOptimizableApp()
            guard let activeApp else {
                trace.append(.string("no active app available"))
                return []
            }
            let grouping = AppTypeClassifier.grouping(for: activeApp)
            trace.append(.string("resolved active type \(grouping.label) from \(activeApp)"))
            if let titleFilter {
                trace.append(.string("title contains \(titleFilter)"))
            }
            return dedupeWindows(visible.filter {
                AppTypeClassifier.matches($0.app, grouping: grouping) &&
                (titleFilter == nil || $0.titleContains(titleFilter!))
            })

        default:
            trace.append(.string("using visible window scope"))
            return dedupeWindows(visible)
        }
    }

    private func parseOptimizationAppType(_ raw: String) -> AppType? {
        let normalized = normalizeToken(raw)
        return AppType.allCases.first { $0.rawValue == normalized }
    }

    private func selectedWindowIds(from json: JSON?) -> [UInt32] {
        guard case .array(let values) = json else { return [] }
        return values.compactMap(\.uint32Value)
    }

    private func distributableWindows() -> [WindowEntry] {
        allWindows().filter { entry in
            entry.isOnScreen &&
            entry.app != "Lattices" &&
            entry.frame.w > 50 &&
            entry.frame.h > 50
        }
    }

    private func dedupeWindows(_ windows: [WindowEntry]) -> [WindowEntry] {
        var seen: Set<UInt32> = []
        var result: [WindowEntry] = []
        for window in windows where !seen.contains(window.wid) {
            seen.insert(window.wid)
            result.append(window)
        }
        return result
    }

    private func frontmostOptimizableApp() -> String? {
        if let app = frontmostAppName(),
           !app.localizedCaseInsensitiveContains("lattices") {
            return app
        }
        return distributableWindows().first?.app
    }

    private func normalizeToken(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}
