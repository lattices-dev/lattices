#if LATTICES_VOICE && canImport(HudsonVoice)
import Darwin
import Foundation
import HudsonVoice
import XCTest
@testable import Lattices

final class VoicePrivateEndpointTests: XCTestCase {
    func testCanonicalCapabilityRequiresPrivateTransportUnlessLegacyIsExplicit() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lattices-voice-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("runtime.json")
        let keys = [HudsonVoiceRuntime.runtimePathEnvironmentKey, "LATTICES_VOICE_ALLOW_LEGACY_TCP"]
        let original = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = original[index] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv(keys[0], file.path, 1); unsetenv(keys[1])
        var capability: [String: Any] = [
            "schemaVersion": 1, "service": "hudson-voice", "transport": "ws+json-rpc",
            "host": "127.0.0.1", "port": 9398, "webSocketUrl": "ws://127.0.0.1:9398",
            "authToken": String(repeating: "a", count: 43), "pid": getpid()
        ]
        func write() throws {
            try JSONSerialization.data(withJSONObject: capability).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        try write()
        XCTAssertNil(HudsonVoiceRuntimeResolver.resolve())
        setenv(keys[1], "1", 1)
        XCTAssertEqual(HudsonVoiceRuntimeResolver.resolve()?.endpoint.port, 9398)
        unsetenv(keys[1])
        capability["transport"] = "unix+ws+json-rpc"
        capability["port"] = 0
        capability["socketPath"] = directory.appendingPathComponent("voice.sock").path
        try write()
        XCTAssertEqual(HudsonVoiceRuntimeResolver.resolve()?.endpoint.socketPath, capability["socketPath"] as? String)
    }
}
#endif
