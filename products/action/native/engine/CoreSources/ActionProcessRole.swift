import Darwin
import Foundation

/// Action's launcher, display owners and recorders share one bundle identity.
/// Read argv rather than treating every copy of the bundle as the launcher.
public enum ActionProcessRole {
    public static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return decode(Data(bytes.prefix(size)))
    }

    public static func decode(_ data: Data) -> [String]? {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var index = 4
        // Kernel executable path, then padding before argv[0].
        while index < bytes.count && bytes[index] != 0 { index += 1 }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            guard let value = String(bytes: bytes[index..<end], encoding: .utf8) else { return nil }
            args.append(value)
            index = end + 1
        }
        return args
    }

    public static func isLauncher(_ arguments: [String]?) -> Bool {
        guard let arguments, !arguments.isEmpty else { return false }
        let command = arguments.dropFirst().first { !$0.hasPrefix("-psn_") }
        return command == nil || command == "launcher"
    }
}
