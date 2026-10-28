import Foundation

/// Finds the CLI that belongs to this app without adopting an unrelated checkout.
/// All inputs are explicit so Finder launches and command-line launches use the
/// same rules, and the filesystem layouts can be tested without starting the app.
enum LatticesCLIRootResolver {
    enum Source: String {
        case explicit
        case bundle
        case installed
    }

    struct Resolution: Equatable {
        let root: String
        let source: Source
    }

    struct SearchPaths {
        var executables: [URL] = []
        var packageRoots: [URL] = []
    }

    private static let packageNames = ["@lattices/lattices", "@lattices/cli", "@arach/lattices"]

    static func resolve(
        arguments: [String],
        bundleURL: URL,
        appVersion: String,
        searchPaths: SearchPaths,
        fileManager: FileManager = .default
    ) -> Resolution? {
        // An explicit CLI launcher remains the authority for deliberate source
        // builds, including a checkout whose version is being changed locally.
        if let index = arguments.firstIndex(of: "--lattices-cli-root"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            let root = canonical(URL(fileURLWithPath: arguments[index + 1]))
            if hasHelper(root, fileManager: fileManager) {
                return Resolution(root: root.path, source: .explicit)
            }
        }

        // Both npm bundles and source builds live in <root>/apps/mac. Resolve
        // /Applications symlinks before walking: two parents only reaches apps/.
        let bundle = canonical(bundleURL)
        var ancestor = bundle.deletingLastPathComponent()
        while ancestor.path != "/" {
            if bundle.path.hasPrefix(ancestor.appendingPathComponent("apps/mac").path + "/"),
               let version = packageVersion(ancestor, fileManager: fileManager),
               version == appVersion || isSourceCheckout(ancestor, fileManager: fileManager) {
                return Resolution(root: ancestor.path, source: .bundle)
            }
            ancestor.deleteLastPathComponent()
        }

        // Finder and login launches do not inherit a terminal's PATH. Follow
        // installed bin symlinks and inspect the usual package-manager roots.
        // Never run a shell startup script or a discovered CLI to identify it.
        let executableRoots = searchPaths.executables.compactMap { executable -> URL? in
            guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
            let target = canonical(executable)
            guard target.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
            return target.deletingLastPathComponent().deletingLastPathComponent()
        }
        var visited = Set<String>()
        for candidate in executableRoots + searchPaths.packageRoots {
            let root = canonical(candidate)
            guard visited.insert(root.path).inserted,
                  !isSourceCheckout(root, fileManager: fileManager),
                  let version = packageVersion(root, fileManager: fileManager),
                  version == appVersion else { continue }
            return Resolution(root: root.path, source: .installed)
        }
        return nil
    }

    static func installedSearchPaths(home: URL, environment: [String: String]) -> SearchPaths {
        let bunHome = absoluteURL(environment["BUN_INSTALL"]) ?? home.appendingPathComponent(".bun")
        var binDirectories = [
            bunHome.appendingPathComponent("bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
        ]
        var moduleDirectories = [
            bunHome.appendingPathComponent("install/global/node_modules"),
            home.appendingPathComponent(".npm-global/lib/node_modules"),
            home.appendingPathComponent(".local/lib/node_modules"),
            home.appendingPathComponent("Library/pnpm/global/5/node_modules"),
            home.appendingPathComponent(".local/share/pnpm/global/5/node_modules"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules"),
        ]
        if let prefix = absoluteURL(environment["npm_config_prefix"] ?? environment["NPM_CONFIG_PREFIX"]) {
            binDirectories.insert(prefix.appendingPathComponent("bin"), at: 0)
            moduleDirectories.insert(prefix.appendingPathComponent("lib/node_modules"), at: 0)
        }
        if let pnpmHome = absoluteURL(environment["PNPM_HOME"]) {
            binDirectories.insert(pnpmHome, at: 0)
            moduleDirectories.insert(pnpmHome.appendingPathComponent("global/5/node_modules"), at: 0)
        }
        // Ignore empty/relative PATH entries: they depend on the launcher's cwd.
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .compactMap { absoluteURL(String($0)) }
        binDirectories.insert(contentsOf: pathDirectories, at: 0)
        return SearchPaths(
            executables: binDirectories.flatMap { directory in
                ["lattices", "lats"].map { directory.appendingPathComponent($0) }
            },
            packageRoots: moduleDirectories.flatMap { directory in
                packageNames.map { directory.appendingPathComponent($0) }
            }
        )
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func absoluteURL(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static func hasHelper(_ root: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: root.appendingPathComponent("bin/lattices-app.ts").path)
    }

    private static func packageVersion(_ root: URL, fileManager: FileManager) -> String? {
        guard hasHelper(root, fileManager: fileManager),
              fileManager.fileExists(atPath: root.appendingPathComponent("bin/lattices.ts").path),
              let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = package["name"] as? String, packageNames.contains(name),
              let version = package["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    private static func isSourceCheckout(_ root: URL, fileManager: FileManager) -> Bool {
        // .git can be a directory or a worktree pointer. The Swift manifest also
        // identifies source archives without Git; it is absent from npm packs.
        [".git", "apps/mac/Package.swift", "apps/mac/Sources"].contains {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }
}
