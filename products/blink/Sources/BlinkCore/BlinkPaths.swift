import Foundation

/// Canonical locations for Canvas, shared by the app and both CLI names.
///
/// Keep the original storage directory and socket name so upgrading never
/// separates existing notes, settings, attachments, or compatible clients.
public enum BlinkPaths {
    /// `CANVAS_HOME` takes precedence over the compatible `BLINK_HOME` override.
    /// Empty values are treated as unset by both the app and CLI.
    public static func homeOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for key in ["CANVAS_HOME", "BLINK_HOME"] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// Scratch homes must never start the normal paired-device sync host.
    public static func hasHomeOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        homeOverride(environment: environment) != nil
    }

    /// The existing home directory: `~/Library/Application Support/Blink`,
    /// or `$CANVAS_HOME` / `$BLINK_HOME` when set. No migration is needed.
    public static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = homeOverride(environment: environment) {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blink", isDirectory: true)
    }

    /// Where the note files live: `<home>/Notes`.
    public static func notes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("Notes", isDirectory: true)
    }

    public static func desks(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("desks", isDirectory: true)
    }

    public static func socket(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("blink.sock", isDirectory: false)
    }

    /// The agent-first config file: `<home>/config.json`.
    public static func config(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("config.json", isDirectory: false)
    }

    /// Append-only edit ledger: `<home>/edits.sqlite`. Not note truth —
    /// markdown files stay authoritative if this file is missing or unwritable.
    public static func edits(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("edits.sqlite", isDirectory: false)
    }

    /// Durable deletion evidence for peer replication. Full snapshots are
    /// authoritative today; this journal preserves delete intent for later
    /// incremental sync and multi-writer conflict handling.
    public static func tombstones(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("tombstones.json", isDirectory: false)
    }

    /// Where note attachments live: `<home>/attachments`. A note can embed an
    /// image it owns via `![](blink://attachments/pic.png)`; the app serves this
    /// directory to the editor webview over the `blink://` scheme (see
    /// `EditorWebView`) rather than granting broad file-system read access.
    public static func attachments(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        home(environment: environment).appendingPathComponent("attachments", isDirectory: true)
    }

    /// Where installed brand marks live: `<home>/attachments/marks`. A
    /// subdirectory rather than the attachments root so an installed brand asset
    /// is never confused with a note's own embedded image.
    public static func marks(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        attachments(environment: environment).appendingPathComponent("marks", isDirectory: true)
    }

    /// Resolve a treatment-supplied attachment reference to a real file URL, or
    /// `nil` if it does not name a regular file *inside* the attachments
    /// directory. This is the single containment rule for brand assets: the app
    /// renders through it and the CLI validates through it, so the two can never
    /// disagree about what is in bounds.
    ///
    /// Accepts a plain relative path (`marks/acme.svg`) or the `blink://`
    /// attachment form the editor uses. Rejects absolute paths, and resolves
    /// symlinks before the containment check so a link cannot escape the root.
    /// A typo becomes an absent mark, never an arbitrary file read.
    public static func attachment(
        named raw: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }

        let prefix = "blink://attachments/"
        let relative = trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        guard !relative.isEmpty else { return nil }

        let root = attachments(environment: environment)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return candidate
    }
}
