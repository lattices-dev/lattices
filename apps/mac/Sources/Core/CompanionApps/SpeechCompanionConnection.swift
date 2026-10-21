import Foundation
#if SPEECH_FORWARDING_TESTS
@testable import SpeechAppRuntime
#endif

/// Persistent per-caller connection. Socket closure releases that caller's
/// playback reservation, while enqueued jobs remain owned by Speech.
actor SpeechCompanionConnection {
    static let capabilityURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Speech/RPC/capability")
    static let tokenHeader = "x-lattices-speech-token"
    private let endpoint: URL?
    private let socketPath: String
    private var unixSocket: SpeechUnixWebSocket?
    private var unixGeneration: UUID?
    private var unixConnecting: Task<Void, Error>?
    private let tokenFile: URL
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var pending: Set<String> = []
    private let response: (DaemonResponse) -> Void
    private let event: (DaemonEvent) -> Void

    init(endpoint: URL? = nil, socketPath: String = LatticesLocalEndpoints.speechCompanionSocketPath, tokenFile: URL? = nil, response: @escaping (DaemonResponse) -> Void, event: @escaping (DaemonEvent) -> Void) {
        self.endpoint = endpoint; self.socketPath = socketPath
        self.tokenFile = tokenFile ?? (endpoint == nil ? LatticesLocalEndpoints.speechCompanionTokenURL : Self.capabilityURL)
        self.response = response; self.event = event
    }
    nonisolated static func authorizes(handshake: String, tokenFile: URL = capabilityURL) -> Bool {
        guard let expected = try? Data(contentsOf: tokenFile), !expected.isEmpty else { return false }
        var tokens: [String] = []
        for line in handshake.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let header = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            if header == "origin" { return false }
            if header == tokenHeader { tokens.append(pair[1].trimmingCharacters(in: .whitespaces)) }
        }
        guard tokens.count == 1 else { return false }
        let supplied = Data(tokens[0].utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func forward(_ request: DaemonRequest) async {
        guard !pending.contains(request.id) else {
            response(DaemonResponse(id: request.id, result: nil, error: "Duplicate in-flight request id")); return
        }
        pending.insert(request.id)
        if endpoint == nil {
            var generation = unixGeneration
            do {
                if unixSocket == nil {
                    let next = UUID(); generation = next; unixGeneration = next
                    let connection = SpeechUnixWebSocket(path: socketPath, tokenFile: tokenFile,
                        receive: { [weak self] data in Task { await self?.receiveUnix(data, generation: next) } },
                        failed: { [weak self] in Task { await self?.failedUnix(generation: next) } })
                    unixSocket = connection
                    unixConnecting = Task { try await connection.connect() }
                }
                try await unixConnecting?.value
                guard let connection = unixSocket, generation == unixGeneration else { return }
                unixConnecting = nil
                let data = try JSONEncoder().encode(request)
                try await connection.send(data)
            } catch { if let generation { failedUnix(generation: generation) } }
            return
        }
        var sendingConnection: URLSessionWebSocketTask?
        do {
            if socket == nil {
                let token = try String(contentsOf: tokenFile, encoding: .utf8)
                var urlRequest = URLRequest(url: endpoint!)
                urlRequest.setValue(token, forHTTPHeaderField: Self.tokenHeader)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 15
                let session = URLSession(configuration: configuration)
                let connection = session.webSocketTask(with: urlRequest)
                self.session = session; socket = connection
                connection.resume()
                receiver = Task { [weak self, connection] in
                    do {
                        while !Task.isCancelled {
                            let message = try await connection.receive()
                            await self?.receive(message, from: connection)
                        }
                    } catch { await self?.failed(for: connection) }
                }
            }
            let data = try JSONEncoder().encode(request)
            sendingConnection = socket
            try await sendingConnection?.send(.string(String(decoding: data, as: UTF8.self)))
        } catch { failed(for: sendingConnection) }
    }
    private func receiveUnix(_ data: Data, generation: UUID) {
        guard unixGeneration == generation else { return }
        decode(data)
    }
    private func failedUnix(generation: UUID) {
        guard unixGeneration == generation else { return }
        failed()
    }
    private func decode(_ data: Data) {
        if let result = try? JSONDecoder().decode(DaemonResponse.self, from: data) {
            guard pending.remove(result.id) != nil else { return }
            response(result)
        } else if let update = try? JSONDecoder().decode(DaemonEvent.self, from: data) { event(update) }
    }
    private func receive(_ message: URLSessionWebSocketTask.Message, from connection: URLSessionWebSocketTask) {
        guard socket === connection else { return }
        let data: Data
        switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: return }
        decode(data)
    }
    private func failed(for connection: URLSessionWebSocketTask? = nil) {
        if let connection, socket !== connection { return }
        let ids = pending; pending.removeAll()
        close()
        for id in ids { response(DaemonResponse(id: id, result: nil, error: Self.unreachableError)) }
    }
    /// Kept in sync with VoiceHelperRouting.unreachableError; the daemon turns it
    /// into `helper_not_installed` when the Voice app is missing.
    static let unreachableError = "helper_unreachable: Voice is installed but not responding. Open Voice from Lattices › Apps and retry."
    /// Ends this caller's playback lease by closing its helper socket. In-flight
    /// requests fail instead of hanging; queued speech stays with the helper.
    func release() -> Bool {
        let hadSocket = socket != nil || unixSocket != nil
        let ids = pending
        close()
        for id in ids { response(DaemonResponse(id: id, result: nil, error: "voice.release closed the Voice connection before this request finished")) }
        return hadSocket
    }
    #if SPEECH_FORWARDING_TESTS
    func testConnection() -> URLSessionWebSocketTask? { socket }
    func testLateFailure(from connection: URLSessionWebSocketTask) { failed(for: connection) }
    #endif
    func close() {
        unixGeneration = nil
        unixConnecting?.cancel(); unixConnecting = nil
        unixSocket?.close(); unixSocket = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        pending.removeAll()
    }
}
