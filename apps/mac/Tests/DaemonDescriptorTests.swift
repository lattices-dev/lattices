import Darwin
import Foundation
import XCTest
@testable import Lattices

final class DaemonDescriptorTests: XCTestCase {
    func testListenerAcceptedSocketAndLeaseDoNotSurviveExec() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/lats-fds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("lattices.sock").path
        let credential = directory.appendingPathComponent("lattices.token")
        let server = DaemonServer(socketPath: path, tokenURL: credential)
        server.start()
        defer { server.stop() }
        let token = try String(contentsOf: credential, encoding: .utf8)
        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        XCTAssertTrue(PrivateLocalEndpoint.preventInheritance(peer))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let request = Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nx-lattices-token: \(token)\r\n\r\n").utf8)
        XCTAssertEqual(request.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }, request.count)
        var response = [UInt8](repeating: 0, count: 4096)
        let count = read(peer, &response, response.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(String(decoding: response.prefix(max(0, count)), as: UTF8.self).hasPrefix("HTTP/1.1 101"))

        var lockInfo = stat()
        XCTAssertEqual(lstat(credential.path + ".lock", &lockInfo), 0)
        var descriptors: [(String, Int32)] = []
        for fd in Int32(3)..<getdtablesize() {
            var info = stat()
            if fstat(fd, &info) == 0, info.st_dev == lockInfo.st_dev, info.st_ino == lockInfo.st_ino {
                descriptors.append(("endpoint lock", fd)); continue
            }
            var bound = sockaddr_un()
            var size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            guard result == 0, bound.sun_family == sa_family_t(AF_UNIX) else { continue }
            let boundPath = withUnsafeBytes(of: bound.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard boundPath == path else { continue }
            var remote = sockaddr_storage()
            var remoteSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let connected = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &remoteSize) }
            }
            descriptors.append((connected == 0 ? "accepted client" : "listener", fd))
        }
        XCTAssertEqual(Set(descriptors.map(\.0)), ["endpoint lock", "listener", "accepted client"])
        XCTAssertEqual(descriptors.count, 3)
        // Prove the child probe can see an inheritable descriptor; this avoids
        // a false pass if the spawning helper silently closes every descriptor.
        let control = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(control, 0)
        defer { close(control) }
        XCTAssertTrue(try survivesExec(control))
        for (name, fd) in descriptors {
            XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, name)
            XCTAssertFalse(try survivesExec(fd), "Child inherited \(name)")
        }
    }

    func testProcessQueryClosesUnprotectedDescriptorsAndPreservesCommandOutput() throws {
        let control = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(control, 0)
        defer { close(control) }
        XCTAssertTrue(try survivesExec(control))
        let inspect = ["/usr/bin/stat", "-f", "%HT", "/dev/fd/\(control)"]
        XCTAssertEqual(ProcessQuery.shell(inspect), "")
        XCTAssertFalse(ProcessQuery.run(inspect))
        XCTAssertEqual(ProcessQuery.shell(["/bin/echo", "private IPC spawn"]), "private IPC spawn")
        XCTAssertTrue(ProcessQuery.run(["/usr/bin/true"]))
    }

    private func survivesExec(_ fd: Int32) throws -> Bool {
        var actions: posix_spawn_file_actions_t?
        XCTAssertEqual(posix_spawn_file_actions_init(&actions), 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let arguments = ["/usr/bin/stat", "-f", "%HT", "/dev/fd/\(fd)"]
        let args = arguments.map { strdup($0) } + [nil]
        defer { args.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/usr/bin/stat", &actions, nil, args, environ)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        return status == 0
    }
}
