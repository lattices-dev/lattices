import Foundation

enum LatticesRuntime {
    static let releaseBundleIdentifier = "dev.lattices.app"
    static let devBundleIdentifier = "dev.lattices.app.dev"

    private static let cliResolution = LatticesCLIRootResolver.resolve(
        arguments: CommandLine.arguments,
        bundleURL: Bundle.main.bundleURL,
        appVersion: appVersion,
        searchPaths: LatticesCLIRootResolver.installedSearchPaths(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
    )

    static var cliRoot: String? { cliResolution?.root }

    static var cliRootSource: String { cliResolution?.source.rawValue ?? "unavailable" }

    static var appHelperScriptPath: String? {
        guard let cliRoot else { return nil }
        let path = cliRoot + "/bin/lattices-app.ts"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static var cliExecutablePath: String? {
        if let cliRoot {
            let path = cliRoot + "/bin/lattices.ts"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    static var cliExecutableURL: URL? {
        cliExecutablePath.map { URL(fileURLWithPath: $0) }
    }

    static var cliShellCommand: String {
        guard let path = cliExecutablePath else { return "lattices" }
        return terminalShellEscape(path)
    }

    static var bunPath: String? {
        let candidates = [
            NSHomeDirectory() + "/.bun/bin/bun",
            "/usr/local/bin/bun",
            "/opt/homebrew/bin/bun",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let resolved = ProcessQuery.shell(["/bin/zsh", "-lc", "command -v bun 2>/dev/null"])
        if !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) {
            return resolved
        }

        return nil
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "unknown"
    }

    static var appDisplayVersion: String {
        let base = appVersion == "unknown" ? "unknown" : "v\(appVersion)"
        guard isDevBuild else { return base }

        let track = buildTrack ?? "latest"
        return "\(base)-dev.\(track)"
    }

    static var buildChannel: String {
        let raw = Bundle.main.infoDictionary?["LatticesBuildChannel"] as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "release"
    }

    static var buildTrack: String? {
        normalizedInfoValue("LatticesBuildTrack")
    }

    static var buildRevision: String? {
        normalizedInfoValue("LatticesBuildRevision")
    }

    static var buildTimestamp: String? {
        normalizedInfoValue("LatticesBuildTimestamp")
    }

    static var isDevBuild: Bool {
        buildChannel == "dev"
    }

    static var buildStatusLabel: String {
        isDevBuild ? "Latest local dev build" : "Signed release build"
    }

    static var buildChannelLabel: String {
        isDevBuild ? "DEV" : "RELEASE"
    }

    static func isLatticesBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == releaseBundleIdentifier || bundleIdentifier == devBundleIdentifier
    }

    private static func terminalShellEscape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if " \\\"$`!&;()[]{}<>|*?".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static func normalizedInfoValue(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "unknown" ? nil : value
    }
}
