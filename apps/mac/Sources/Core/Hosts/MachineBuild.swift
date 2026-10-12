import Foundation

struct MachineBuild: Equatable {
    var version: String?
    var commit: String?
    init(_ info: [String: Any]) {
        let build = info["build"] as? [String: Any] ?? [:]
        version = build["version"] as? String ?? info["version"] as? String
        commit = build["commit"] as? String
    }
    static func behind(_ remote: String?, local: String?) -> Bool {
        guard let remote, let local else { return false }
        func numbers(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".")
            let values = parts.compactMap { Int($0) }
            return values.count == parts.count && !values.isEmpty ? values : nil
        }
        guard let r = numbers(remote), let l = numbers(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a < b }
        }
        return false
    }
    var label: String {
        let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let identity = "\(version ?? "?") · \(commit.map { String($0.prefix(8)) } ?? "?")"
        if Self.behind(version, local: local) { return identity + " · Behind" }
        if let commit, let current = LatticesRuntime.buildRevision,
           !commit.hasPrefix(current), !current.hasPrefix(commit) { return identity + " · Different build" }
        return identity
    }
}
