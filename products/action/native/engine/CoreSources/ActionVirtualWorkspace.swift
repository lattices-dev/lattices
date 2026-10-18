import Foundation

public struct ActionVirtualWorkspace: Equatable, Sendable {
    public let name: String

    public init(_ name: String = "default") throws {
        guard name.range(of: "^[a-z][a-z0-9-]{0,31}\\z", options: .regularExpression) != nil else {
            throw NSError(domain: "ActionVirtualWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workspace must contain 1–32 lowercase letters, digits, or hyphens and start with a letter"])
        }
        self.name = name
    }

    public var serialNumber: UInt32 {
        guard name != "default" else { return 0x41435401 }
        return name.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } | 0x80000000
    }

    public var ownerLockName: String {
        name == "default" ? "display-owner.lock" : "display-owner-\(name).lock"
    }

    public static func offscreenOrigin(otherBounds: [CGRect]) -> CGPoint? {
        guard !otherBounds.isEmpty,
              otherBounds.allSatisfy({ !$0.isNull && !$0.isInfinite && !$0.isEmpty }) else { return nil }
        let right = otherBounds.map(\.maxX).max()!
        let bottom = otherBounds.map(\.maxY).max()!
        guard right.isFinite, bottom.isFinite,
              right >= CGFloat(Int32.min), right <= CGFloat(Int32.max),
              bottom >= CGFloat(Int32.min), bottom <= CGFloat(Int32.max) else { return nil }
        return CGPoint(x: right, y: bottom)
    }

    public static func previewWouldCycle(source: UInt32, destination: UInt32, edges: [UInt32: UInt32]) -> Bool {
        var visited: Set<UInt32> = [source]
        var current: UInt32? = destination
        while let identifier = current {
            guard visited.insert(identifier).inserted else { return true }
            current = edges[identifier]
        }
        return false
    }
}

public final class ActionWorkspaceLock {
    private let descriptor: Int32

    public init(url: URL, shared: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSLocalizedDescriptionKey: "Action resource is busy: \(url.lastPathComponent)"])
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }
}
