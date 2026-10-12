import Foundation

/// Manages the Mission Control "Move left/right a space" symbolic hotkeys
/// (com.apple.symbolichotkeys 79/80 = Ctrl+←/→) while Instant Space Switching
/// is active.
///
/// These shortcuts are dispatched inside the WindowServer *before* the event
/// reaches any session event tap, so the tap cannot suppress the slide
/// animation — the hotkeys must be unregistered for
/// `SpaceSwitchInterceptor` to own the chord. The original `enabled` flags
/// are backed up in app preferences and restored when the feature turns off
/// or the app quits. A saved backup also allows the next launch to restore
/// the shortcuts after an interrupted previous process.
enum SpaceSwitchHotkeys {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let dictKey = "AppleSymbolicHotKeys" as CFString
    private static let backupKey = "spaceSwitchKeys.hotkeyBackup"

    private static let ownership = SpaceSwitchHotkeyOwnership(
        readHotkeys: currentDict,
        writeHotkeys: writeDict,
        readBackup: { UserDefaults.standard.dictionary(forKey: backupKey) as? [String: Bool] },
        writeBackup: { backup in
            if let backup {
                UserDefaults.standard.set(backup, forKey: backupKey)
            } else {
                UserDefaults.standard.removeObject(forKey: backupKey)
            }
        },
        applySettings: applySettings
    )

    /// True while Lattices holds the Mission Control Ctrl+arrow hotkeys
    /// unregistered — a synthetic Ctrl+arrow does nothing then.
    static var isHoldingSystemHotkeys: Bool { ownership.isHoldingSystemHotkeys }

    static func disable() {
        if ownership.disable() {
            DiagnosticLog.shared.info("SpaceSwitch: Mission Control Ctrl+arrow hotkeys disabled")
        }
    }

    static func restore() {
        if ownership.restore() {
            DiagnosticLog.shared.info("SpaceSwitch: Mission Control Ctrl+arrow hotkeys restored")
        }
    }

    static func restoreForTermination() {
        if ownership.restoreForTermination() {
            DiagnosticLog.shared.info("SpaceSwitch: Mission Control Ctrl+arrow hotkeys restored for termination")
        }
    }

    private static func currentDict() -> [String: Any] {
        CFPreferencesCopyAppValue(dictKey, domain) as? [String: Any] ?? [:]
    }

    private static func writeDict(_ dict: [String: Any]) {
        CFPreferencesSetValue(dictKey, dict as CFPropertyList, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(domain)
    }

    /// Reloads per-user settings (including symbolic hotkeys) without logout.
    private static func applySettings() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        task.arguments = ["-u"]
        try? task.run()
    }
}

/// Injectable persistence keeps recovery tests away from the user's shortcuts.
final class SpaceSwitchHotkeyOwnership {
    private let hotkeyIDs = ["79", "80"]
    private let readHotkeys: () -> [String: Any]
    private let writeHotkeys: ([String: Any]) -> Void
    private let readBackup: () -> [String: Bool]?
    private let writeBackup: ([String: Bool]?) -> Void
    private let applySettings: () -> Void
    private let lock = NSLock()

    /// Whether this process currently holds the hotkeys disabled. Prevents
    /// repeated plist churn on every preference/permission re-emission.
    private var applied = false
    private var isTerminating = false

    init(
        readHotkeys: @escaping () -> [String: Any],
        writeHotkeys: @escaping ([String: Any]) -> Void,
        readBackup: @escaping () -> [String: Bool]?,
        writeBackup: @escaping ([String: Bool]?) -> Void,
        applySettings: @escaping () -> Void
    ) {
        self.readHotkeys = readHotkeys
        self.writeHotkeys = writeHotkeys
        self.readBackup = readBackup
        self.writeBackup = writeBackup
        self.applySettings = applySettings
    }

    var isHoldingSystemHotkeys: Bool {
        lock.lock(); defer { lock.unlock() }
        return applied
    }

    @discardableResult
    func disable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isTerminating, !applied else { return false }
        applied = true

        var dict = readHotkeys()
        var backup = readBackup() ?? [:]
        var changed = false

        for id in hotkeyIDs {
            let entry = dict[id] as? [String: Any]
            // Backup only the original enabled flag — `value` is never touched.
            // An absent entry means the default binding, which is enabled.
            if backup[id] == nil {
                backup[id] = (entry?["enabled"] as? Int ?? 1) != 0
            }
            if (entry?["enabled"] as? Int ?? 1) != 0 {
                var newEntry = entry ?? [:]
                newEntry["enabled"] = 0
                dict[id] = newEntry
                changed = true
            }
        }

        writeBackup(backup)
        if changed {
            writeHotkeys(dict)
            applySettings()
        }
        return changed
    }

    @discardableResult
    func restore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return restoreLocked()
    }

    /// Signal cleanup can race a main-queue refresh. Seal ownership before
    /// restoring so no later callback can disable the shortcuts again.
    @discardableResult
    func restoreForTermination() -> Bool {
        lock.lock(); defer { lock.unlock() }
        isTerminating = true
        return restoreLocked()
    }

    private func restoreLocked() -> Bool {
        applied = false

        // `applied` starts false in a new process. The durable backup is also
        // an outstanding ownership claim left by a crashed previous process.
        guard let backup = readBackup(), !backup.isEmpty else { return false }
        var dict = readHotkeys()
        var changed = false

        for id in hotkeyIDs {
            guard let wasEnabled = backup[id] else { continue }
            var newEntry = dict[id] as? [String: Any] ?? [:]
            let target = wasEnabled ? 1 : 0
            if (newEntry["enabled"] as? Int ?? 1) != target {
                newEntry["enabled"] = target
                dict[id] = newEntry
                changed = true
            }
        }

        if changed {
            writeHotkeys(dict)
            applySettings()
        }
        writeBackup(nil)
        return changed
    }
}
