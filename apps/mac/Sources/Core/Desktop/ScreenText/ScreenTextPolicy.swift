import Foundation

/// Policy for the searchable screen-text index, not explicit screenshot tools.
/// Ordinary apps stay eligible; users can exclude any app by stable bundle ID.
struct ScreenTextPolicy {
    static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password"
    ]

    let enabled: Bool
    let excludedBundleIDs: Set<String>

    func allows(bundleID: String?, isOwnProcess: Bool, isOnScreen: Bool,
                layer: Int = 0, width: Double, height: Double) -> Bool {
        guard enabled, !isOwnProcess, isOnScreen, layer == 0,
              width >= 50, height >= 50,
              let bundleID, !bundleID.isEmpty else { return false }
        return !excludedBundleIDs.contains(bundleID)
    }

    static func allowsAccessibilityNode(subrole: String?, hidden: Bool) -> Bool {
        !hidden && subrole != "AXSecureTextField"
    }

    /// AX text areas can expose their entire document. Respect the visible
    /// character range when the app provides it; invalid ranges expose nothing.
    static func visibleText(_ text: String, range: NSRange?) -> String {
        guard let range else { return text }
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.location <= source.length,
              range.length >= 0, range.length <= source.length - range.location else { return "" }
        return source.substring(with: range)
    }
}

/// A scan can finish after it was stopped, disabled, or its policy changed.
/// The same permit guards publication and the eventual database write.
final class ScreenTextScanGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func current() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }

    func isCurrent(_ permit: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return permit == generation
    }

    @discardableResult
    func commit(_ permit: UInt64, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard permit == generation else { return false }
        body()
        return true
    }
}
