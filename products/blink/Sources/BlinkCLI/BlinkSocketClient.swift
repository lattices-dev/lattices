import ArgumentParser
import BlinkCore
import Darwin
import Foundation

enum BlinkSocketClient {
    static func call(method: String, params: [String: Any]) throws -> Any {
        try BlinkPrivateIPC.validateSocket(BlinkPaths.socket())
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ValidationError("could not create Canvas socket client") }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ValidationError("Could not secure Canvas socket descriptor") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = BlinkPaths.socket().path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ValidationError("Canvas socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.baseAddress?.initializeMemory(as: UInt8.self, repeating: 0, count: bytes.count)
            path.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ValidationError("Canvas is not running with the same CANVAS_HOME or BLINK_HOME (missing blink.sock)")
        }
        guard BlinkPrivateIPC.sameUserPeer(fd) else { throw ValidationError("Canvas socket is not owned by this user") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ValidationError("Could not secure Canvas connection") }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        var outgoing = try JSONSerialization.data(withJSONObject: request); outgoing.append(0x0a)
        while !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ValidationError("Canvas could not receive the request") }
            outgoing.removeFirst(count)
        }
        var incoming = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while incoming.firstIndex(of: 0x0a) == nil {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ValidationError("Canvas closed the socket without a response") }
            incoming.append(contentsOf: bytes.prefix(count))
            guard incoming.count <= 4_194_304 else { throw ValidationError("Canvas response exceeded the size limit") }
        }
        guard let newline = incoming.firstIndex(of: 0x0a),
              let object = try JSONSerialization.jsonObject(with: Data(incoming.prefix(upTo: newline))) as? [String: Any]
        else { throw ValidationError("Canvas returned an invalid response") }
        if let error = object["error"] as? [String: Any] {
            throw ValidationError(error["message"] as? String ?? "Canvas RPC failed")
        }
        return object["result"] ?? NSNull()
    }
}
