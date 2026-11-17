import Foundation

/// Uses the repository CLI so socket authentication stays owned by Lattices.
/// No startup requests, timers, subscriptions, shell evaluation, or daemon launch.
struct PlyLatticesClient: Sendable {
    let bun: URL
    let repository: URL
    var timeout: TimeInterval = 20

    static func bundled() -> Self? {
        guard let bun = Bundle.main.object(forInfoDictionaryKey: "PlyBunPath") as? String,
              let root = Bundle.main.object(forInfoDictionaryKey: "PlyRepositoryRoot") as? String else { return nil }
        return Self(bun: URL(fileURLWithPath: bun), repository: URL(fileURLWithPath: root))
    }

    func call(_ request: PlyWorkspaceRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = bun
                process.currentDirectoryURL = repository
                process.arguments = [repository.appendingPathComponent("bin/lattices.ts").path] + request.arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() }
                catch { continuation.resume(throwing: PlyWorkspaceError.unavailable); return }

                let deadline = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Drain while running, so a pipe-sized response cannot block termination.
                var data = Data()
                var oversized = false
                while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    if data.count + chunk.count <= 1_048_576 { data.append(chunk) }
                    else { oversized = true }
                }
                process.waitUntilExit()
                deadline.cancel()
                if process.terminationStatus != 0 || oversized {
                    continuation.resume(throwing: PlyWorkspaceError.failed)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
