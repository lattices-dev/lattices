import Darwin
import DeckKit
import Foundation

final class LatticesCompanionBridgeServer: NSObject {
    static let shared = LatticesCompanionBridgeServer()

    static let bonjourType = "_lattices-companion._tcp."
    static let defaultPort: UInt16 = 5287
    static let protocolVersion = "1"
    static let maxBodyBytes = 512 * 1024

    private let queue = DispatchQueue(label: "lattices.companion.bridge", qos: .userInitiated)
    /// Pairing is the one request that waits on a human, so it gets its own
    /// queue. Answering it on `queue` — which is serial, and carries every
    /// snapshot, action, and trackpad event from every paired device — would
    /// freeze the entire bridge for as long as the approval alert is up.
    /// Serial on purpose: two devices asking at once should queue, not stack
    /// two modal alerts on top of each other.
    private let pairingQueue = DispatchQueue(label: "lattices.companion.bridge.pairing", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var service: NetService?

    private override init() {
        super.init()
    }

    func start() {
        guard acceptSource == nil else { return }

        let diag = DiagnosticLog.shared
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            diag.error("CompanionBridge: socket() failed — errno \(errno)")
            return
        }

        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.defaultPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            diag.error("CompanionBridge: bind() failed — errno \(errno)")
            close(serverFd)
            serverFd = -1
            return
        }

        guard listen(serverFd, 8) == 0 else {
            diag.error("CompanionBridge: listen() failed — errno \(errno)")
            close(serverFd)
            serverFd = -1
            return
        }

        let flags = fcntl(serverFd, F_GETFL)
        _ = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
        }
        source.resume()
        acceptSource = source

        publishBonjour()
        diag.success("CompanionBridge: listening on http://0.0.0.0:\(Self.defaultPort)")
    }

    func stop() {
        MacVisitHost.disconnect()
        acceptSource?.cancel()
        acceptSource = nil
        service?.stop()
        service = nil
    }
}

private extension LatticesCompanionBridgeServer {
    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct HealthResponse: Codable {
        let ok: Bool
        let name: String
        let serviceType: String
        let hostName: String
        let port: UInt16
        let protocolVersion: String
        let version: String
        let mode: String
        let bridgePublicKey: String
        let bridgeFingerprint: String
        let requestSigningRequired: Bool
        let payloadEncryptionRequired: Bool
        let capabilities: [String]
    }

    func publishBonjour() {
        let advertisedName = Host.current().localizedName ?? "Lattices Companion"
        let service = NetService(
            domain: "local.",
            type: Self.bonjourType,
            name: advertisedName,
            port: Int32(Self.defaultPort)
        )
        service.includesPeerToPeer = true
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "v": Data(Self.protocolVersion.utf8),
            "mode": Data("local-network-secure".utf8),
            "fp": Data(LatticesCompanionSecurityCoordinator.shared.bridgeFingerprint.utf8),
            "sec": Data("signed,encrypted".utf8),
            "cap": Data(DeckBridgeCapability.defaultCompanionCapabilities.joined(separator: ",").utf8),
        ]))
        service.publish()
        self.service = service
    }

    func acceptConnection() {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &addrLen)
                }
            }

            if clientFd < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    DiagnosticLog.shared.error("CompanionBridge: accept() failed — errno \(errno)")
                }
                return
            }

            // A companion can hang up before its reply is written. On Darwin,
            // writing to that socket would otherwise raise SIGPIPE and
            // terminate the app.
            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let clientFlags = fcntl(clientFd, F_GETFL)
            if clientFlags >= 0 {
                _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
            }

            queue.async { [weak self] in
                self?.handleClient(fd: clientFd)
            }
        }
    }

    /// Whether `route` answered the request itself, or handed the socket to
    /// another queue that will answer and close it later.
    enum RouteOutcome {
        case answered
        case handedOff
    }

    func handleClient(fd: Int32) {
        var ownsSocket = true
        defer { if ownsSocket { close(fd) } }

        guard let request = readRequest(from: fd) else {
            sendError(status: 400, message: "Invalid HTTP request", to: fd)
            return
        }

        do {
            if try route(request, to: fd) == .handedOff {
                ownsSocket = false
            }
        } catch let error as LatticesCompanionSecurityError {
            let status: Int
            switch error {
            case .untrustedDevice, .insufficientCapability:
                status = 403
            case .missingHeader, .staleRequest, .replayedRequest, .invalidSignature, .invalidEnvelope, .invalidDeviceKey:
                status = 401
            }
            sendError(status: status, message: error.localizedDescription, to: fd)
        } catch {
            sendError(status: 500, message: error.localizedDescription, to: fd)
        }
    }

    @discardableResult
    func route(_ request: HTTPRequest, to fd: Int32) throws -> RouteOutcome {
        switch (request.method, request.path) {
        case ("GET", "/visit"):
            let auth = try authorizeProtectedRequest(request, requiredCapability: DeckBridgeCapability.inputTrackpad)
            guard MacVisitHost.enabled, request.body.isEmpty else {
                sendError(status: 403, message: "Visits are disabled", to: fd)
                return .answered
            }
            let key = try LatticesCompanionSecurityCoordinator.shared.encryptionKey(for: auth.device)
            guard MacVisitHost.accept(fd: fd, headers: request.headers, auth: auth, key: key) else {
                sendError(status: 403, message: "Visit unavailable or invalid upgrade", to: fd)
                return .answered
            }
            return .handedOff

        case ("GET", "/health"):
            let security = LatticesDeckHost.shared.securityConfiguration
            let response = HealthResponse(
                ok: true,
                name: Host.current().localizedName ?? "Lattices Companion",
                serviceType: Self.bonjourType,
                hostName: localHostName(),
                port: Self.defaultPort,
                protocolVersion: Self.protocolVersion,
                version: LatticesRuntime.appVersion,
                mode: "local-network-secure",
                bridgePublicKey: LatticesCompanionSecurityCoordinator.shared.bridgePublicKeyBase64,
                bridgeFingerprint: LatticesCompanionSecurityCoordinator.shared.bridgeFingerprint,
                requestSigningRequired: security.requestSigningRequired,
                payloadEncryptionRequired: security.payloadEncryptionRequired,
                capabilities: DeckBridgeCapability.defaultCompanionCapabilities
            )
            try sendJSON(status: 200, value: response, to: fd)

        case ("GET", "/deck/manifest"):
            try sendJSON(status: 200, value: LatticesDeckHost.shared.manifestSync(), to: fd)

        case ("GET", "/deck-builder"):
            guard sendDeckBuilderAsset(path: "index.html", to: fd) else {
                sendError(status: 404, message: "Deck Builder asset is unavailable", to: fd)
                return .answered
            }

        case ("GET", let path) where path.hasPrefix("/_next/static/"):
            guard sendDeckBuilderAsset(path: String(path.dropFirst()), to: fd) else {
                sendError(status: 404, message: "Deck Builder asset is unavailable", to: fd)
                return .answered
            }

        case ("POST", "/pairing/request"):
            // Decode on the bridge queue so a malformed body still fails fast,
            // but answer on `pairingQueue`: `handlePairingRequest` blocks until
            // a human clicks, and the companion has to keep serving everyone
            // else meanwhile.
            let pairingRequest = try decoder.decode(DeckPairingRequest.self, from: request.body)
            pairingQueue.async { [weak self] in
                defer { close(fd) }
                guard let self else { return }
                let response = LatticesCompanionSecurityCoordinator.shared.handlePairingRequest(pairingRequest)
                let status = response.disposition == .denied ? 403 : 200
                do {
                    try self.sendJSON(status: status, value: response, to: fd)
                } catch {
                    // The companion may well have given up waiting and closed
                    // the socket. The trust decision still stands on this side;
                    // a retry resolves as `alreadyTrusted`.
                    DiagnosticLog.shared.warn("CompanionPairing: could not deliver response — \(error.localizedDescription)")
                }
            }
            return .handedOff

        case ("GET", "/deck/snapshot"):
            let auth = try authorizeProtectedRequest(request, requiredCapability: DeckBridgeCapability.deckRead)
            let snapshot = try LatticesDeckHost.shared.runtimeSnapshotSync()
            let response = try LatticesCompanionSecurityCoordinator.shared.encodeProtectedResponse(
                snapshot,
                auth: auth,
                status: 200,
                path: request.path
            )
            try sendJSON(status: 200, value: response, to: fd)

        case ("POST", "/deck/perform"):
            let auth = try authorizeProtectedRequest(request, requiredCapability: DeckBridgeCapability.deckPerform)
            let action = try LatticesCompanionSecurityCoordinator.shared.decodeProtectedBody(
                DeckActionRequest.self,
                body: request.body,
                auth: auth,
                method: request.method,
                path: request.path
            )
            let result = try LatticesDeckHost.shared.performSync(action)
            let response = try LatticesCompanionSecurityCoordinator.shared.encodeProtectedResponse(
                result,
                auth: auth,
                status: 200,
                path: request.path
            )
            try sendJSON(status: 200, value: response, to: fd)

        case ("POST", "/deck/trackpad"):
            let auth = try authorizeProtectedRequest(request, requiredCapability: DeckBridgeCapability.inputTrackpad)
            let eventRequest = try LatticesCompanionSecurityCoordinator.shared.decodeProtectedBody(
                DeckTrackpadEventRequest.self,
                body: request.body,
                auth: auth,
                method: request.method,
                path: request.path
            )
            let result = LatticesCompanionTrackpadController.shared.perform(eventRequest)
            let response = try LatticesCompanionSecurityCoordinator.shared.encodeProtectedResponse(
                result,
                auth: auth,
                status: 200,
                path: request.path
            )
            try sendJSON(status: 200, value: response, to: fd)

        case ("POST", "/deck/preview"):
            let auth = try authorizeProtectedRequest(request, requiredCapability: DeckBridgeCapability.screenPreview)
            let previewRequest = try LatticesCompanionSecurityCoordinator.shared.decodeProtectedBody(
                DeckDesktopPreviewRequest.self,
                body: request.body,
                auth: auth,
                method: request.method,
                path: request.path
            )

            // ScreenCaptureKit is async. Hand the socket off so the serial bridge
            // queue can keep serving trackpad, snapshot, and action requests while
            // the frame is being captured and encoded.
            Task { [weak self] in
                defer { close(fd) }
                guard let self else { return }
                do {
                    let frame = try await LatticesDesktopPreviewCapture.capture(previewRequest)
                    let response = try LatticesCompanionSecurityCoordinator.shared.encodeProtectedResponse(
                        frame,
                        auth: auth,
                        status: 200,
                        path: request.path
                    )
                    try self.sendJSON(status: 200, value: response, to: fd)
                } catch {
                    self.sendError(status: 500, message: error.localizedDescription, to: fd)
                }
            }
            return .handedOff

        default:
            sendError(status: 404, message: "Unknown route", to: fd)
        }

        return .answered
    }

    func authorizeProtectedRequest(_ request: HTTPRequest, requiredCapability: String) throws -> AuthorizedBridgeRequest {
        let security = LatticesDeckHost.shared.securityConfiguration
        guard security.requestSigningRequired else {
            throw LatticesCompanionSecurityError.untrustedDevice
        }
        let auth = try LatticesCompanionSecurityCoordinator.shared.authorize(
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: request.body
        )
        try LatticesCompanionSecurityCoordinator.shared.requireCapability(requiredCapability, for: auth)
        return auth
    }

    func readRequest(from fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let delimiterCRLF = Data([13, 10, 13, 10])
        let delimiterLF = Data([10, 10])

        var headerRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF)
        while headerRange == nil {
            guard let count = readChunk(from: fd, deadline: deadline, into: &buffer) else {
                return nil
            }
            guard count > 0 else { return nil }
            if buffer.count > 128 * 1024 {
                return nil
            }
            headerRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF)
        }

        guard let headerRange else { return nil }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0]).uppercased()
        let rawPath = String(requestParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength <= Self.maxBodyBytes else { return nil }
        var body = Data(buffer[headerRange.upperBound...])
        while body.count < contentLength {
            guard let count = readChunk(
                from: fd,
                deadline: deadline,
                chunkSize: min(4096, contentLength - body.count),
                into: &body
            ) else {
                return nil
            }
            guard count > 0 else { return nil }
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func readChunk(
        from fd: Int32,
        deadline: UInt64,
        chunkSize: Int = 4096,
        into buffer: inout Data
    ) -> Int? {
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
                return count
            }
            if count == 0 {
                return 0
            }

            if errno == EINTR {
                continue
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) &&
                DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(10_000)
                continue
            }

            DiagnosticLog.shared.error("CompanionBridge: read() failed — errno \(errno)")
            return nil
        }
    }

    func sendJSON<T: Encodable>(status: Int, value: T, to fd: Int32) throws {
        let body = try encoder.encode(value)
        sendResponse(status: status, contentType: "application/json; charset=utf-8", body: body, to: fd)
    }

    @discardableResult
    func sendDeckBuilderAsset(path: String, to fd: Int32) -> Bool {
        guard !path.contains(".."), !path.hasPrefix("/") else { return false }

        let roots = Self.deckBuilderResourceRoots()

        for root in roots {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { continue }
            sendResponse(status: 200, contentType: contentType(for: url.pathExtension), body: data, to: fd)
            return true
        }
        return false
    }

    func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    func sendError(status: Int, message: String, to fd: Int32) {
        let payload: [String: Any] = ["ok": false, "error": message]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        sendResponse(status: status, contentType: "application/json; charset=utf-8", body: body, to: fd)
    }

    func sendResponse(status: Int, contentType: String, body: Data, to fd: Int32) {
        let reason = reasonPhrase(for: status)
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        writeAll(Data(header.utf8), to: fd)
        writeAll(body, to: fd)
        _ = shutdown(fd, SHUT_WR)
    }

    func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                guard written > 0 else { return }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Internal Server Error"
        }
    }

    func localHostName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return "\(name).local"
            }
        } catch { }

        return Host.current().localizedName ?? "localhost"
    }
}

extension LatticesCompanionBridgeServer {
    /// Where the DeckBuilder assets can live; see `AppResources`.
    static func deckBuilderResourceRoots(
        applicationResourceURL: URL? = Bundle.main.resourceURL,
        loadedBundles: [Bundle] = Bundle.allBundles + Bundle.allFrameworks,
        fileManager: FileManager = .default
    ) -> [URL] {
        AppResources.roots(
            named: "DeckBuilder",
            applicationResourceURL: applicationResourceURL,
            loadedBundles: loadedBundles,
            fileManager: fileManager
        )
    }
}
