import AppKit
import Combine
import Foundation
import SwiftUI

struct LatticesUpdateInfo: Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let publishedAt: Date
    let htmlURL: URL
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var isUpdating = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var availableUpdate: LatticesUpdateInfo?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    @AppStorage("appUpdater.autoCheck") var autoCheckEnabled = true
    @AppStorage("appUpdater.lastCheckTime") private var lastCheckTimeInterval: Double = 0
    @AppStorage("appUpdater.skippedVersion") private var skippedVersion = ""

    private let checkInterval: TimeInterval = 24 * 60 * 60

    private init() {}

    var currentVersion: String { LatticesRuntime.appVersion }
    var currentDisplayVersion: String { LatticesRuntime.appDisplayVersion }

    var canUpdate: Bool {
        LatticesRuntime.bunPath != nil && LatticesRuntime.appHelperScriptPath != nil
    }

    var unavailableReason: String? {
        if LatticesRuntime.bunPath == nil {
            return "Install Bun to enable in-app updates."
        }
        if LatticesRuntime.appHelperScriptPath == nil {
            return "Launch Lattices via `lattices app` so the updater can find the CLI bundle."
        }
        return nil
    }

    func checkIfNeeded() async {
        guard autoCheckEnabled else { return }

        let now = Date()
        let lastCheck = Date(timeIntervalSince1970: lastCheckTimeInterval)
        if now.timeIntervalSince(lastCheck) < checkInterval { return }

        await check()
    }

    func check() async {
        guard !isChecking else { return }

        isChecking = true
        lastError = nil

        defer {
            isChecking = false
            lastChecked = Date()
            lastCheckTimeInterval = Date().timeIntervalSince1970
        }

        do {
            let release = try await fetchLatestRelease()
            guard let update = parseRelease(release), isNewerVersion(update.version) else {
                availableUpdate = nil
                return
            }

            if update.version == skippedVersion {
                availableUpdate = nil
                return
            }

            availableUpdate = update
        } catch UpdateCheckError.noRelease {
            availableUpdate = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func skipCurrentUpdate() {
        guard let update = availableUpdate else { return }
        skippedVersion = update.version
        availableUpdate = nil
    }

    func viewCurrentRelease() {
        if let update = availableUpdate {
            NSWorkspace.shared.open(update.htmlURL)
        } else if let url = URL(string: "https://github.com/lattices-dev/lattices/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    func promptForUpdate() {
        guard canUpdate else {
            presentAlert(
                title: "Update Unavailable",
                message: unavailableReason ?? "Lattices could not locate its updater."
            )
            return
        }

        guard availableUpdate != nil else {
            Task {
                await check()
                if availableUpdate != nil {
                    presentUpdateConfirmation()
                } else if let error = lastError {
                    presentAlert(
                        title: "Could Not Check for Updates",
                        message: error
                    )
                } else {
                    presentAlert(
                        title: "Lattices Is Up to Date",
                        message: "You’re running \(currentDisplayVersion), which is the latest available build for this install."
                    )
                }
            }
            return
        }

        presentUpdateConfirmation()
    }

    private func presentUpdateConfirmation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let update = availableUpdate {
            alert.messageText = "Update Lattices?"
            alert.informativeText = """
            Current version: \(currentDisplayVersion)
            New version: \(update.version)

            Lattices will download the signed release, quit briefly, replace the app, and relaunch when the update is ready.
            """
        } else {
            alert.messageText = "Check and update Lattices?"
            alert.informativeText = """
            Current version: \(currentDisplayVersion)
            New version: latest published release

            Lattices will download the signed release, quit briefly, replace the app, and relaunch when the update is ready.
            """
        }
        alert.addButton(withTitle: availableUpdate == nil ? "Check & Update" : "Update")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startDetachedUpdate()
    }

    private func startDetachedUpdate() {
        guard !isUpdating else { return }
        guard let bunPath = LatticesRuntime.bunPath,
              let scriptPath = LatticesRuntime.appHelperScriptPath else {
            presentAlert(
                title: "Update Unavailable",
                message: unavailableReason ?? "Lattices could not locate its updater."
            )
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bunPath)
        proc.arguments = [scriptPath, "update", "--detach", "--launch"]
        if let cliRoot = LatticesRuntime.cliRoot {
            proc.currentDirectoryURL = URL(fileURLWithPath: cliRoot)
        }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        proc.environment = env

        do {
            try proc.run()
            isUpdating = true
            if let update = availableUpdate {
                statusMessage = "Preparing Lattices \(update.version). The app will relaunch when the update is ready."
            } else {
                statusMessage = "Preparing the latest Lattices release. The app will relaunch when the update is ready."
            }
        } catch {
            presentAlert(
                title: "Update Failed",
                message: "Lattices could not start the updater.\n\n\(error.localizedDescription)"
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repositories/1171006654/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lattices/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GitHubRelease.self, from: data)
        case 404:
            throw UpdateCheckError.noRelease
        case 403:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.httpError(http.statusCode)
        }
    }

    private func parseRelease(_ release: GitHubRelease) -> LatticesUpdateInfo? {
        guard !release.draft, !release.prerelease else { return nil }

        let asset = release.assets.first { asset in
            asset.name == "Lattices.dmg" ||
            (asset.name.hasPrefix("Lattices") && asset.name.hasSuffix(".dmg"))
        }

        guard let asset,
              let downloadURL = URL(string: asset.browserDownloadUrl),
              let htmlURL = URL(string: release.htmlUrl) else {
            return nil
        }

        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        return LatticesUpdateInfo(
            version: version,
            downloadURL: downloadURL,
            releaseNotes: release.body ?? "",
            publishedAt: release.publishedAt,
            htmlURL: htmlURL
        )
    }

    private func isNewerVersion(_ remoteVersion: String) -> Bool {
        guard currentVersion != "unknown" else { return false }
        return remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let htmlUrl: String
    let publishedAt: Date
    let assets: [GitHubAsset]
    let prerelease: Bool
    let draft: Bool
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
}

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case noRelease
    case rateLimited
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from GitHub."
        case .noRelease:
            return "No published release found."
        case .rateLimited:
            return "GitHub rate limited the update check."
        case .httpError(let code):
            return "GitHub returned HTTP \(code)."
        }
    }
}
