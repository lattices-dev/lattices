import Foundation
import Combine

struct PlyWorkspace: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let index: Int
    let projectCount: Int
}

struct PlyWorkspaces: Decodable, Sendable {
    let layers: [PlyWorkspace]
    let active: Int?
    let focusActive: Bool

    func isCurrent(_ layer: PlyWorkspace) -> Bool { focusActive && active == layer.index }
}

enum PlyWorkspaceRequest: Equatable, Sendable {
    case list
    case focus(String)

    var arguments: [String] {
        switch self {
        case .list: return ["call", "layers.list", "{}"]
        case .focus(let id):
            // Argument array + JSON encoding: labels and IDs never become shell code.
            let data = try! JSONEncoder().encode(["name": id, "mode": "focus"])
            return ["call", "layers.activate", String(decoding: data, as: UTF8.self)]
        }
    }
}

enum PlyWorkspacePhase: Equatable {
    case idle, loading, ready, switching(String), success(String), failed(String)

    var busy: Bool {
        switch self { case .loading, .switching: true; default: false }
    }
    var pose: PlyPose {
        switch self {
        case .idle: .rest
        case .loading: .thinking
        case .ready: .browsing
        case .switching: .arranging
        case .success: .happy
        case .failed: .question
        }
    }
}

@MainActor
final class PlyWorkspaceStore: ObservableObject {
    typealias Call = @Sendable (PlyWorkspaceRequest) async throws -> Data
    @Published private(set) var phase: PlyWorkspacePhase = .idle {
        didSet { onChange?(phase) }
    }
    @Published private(set) var snapshot: PlyWorkspaces?
    var onChange: ((PlyWorkspacePhase) -> Void)?
    private let call: Call
    private var generation = 0
    private var pendingRead: Task<Data, Error>?

    init(call: @escaping Call) { self.call = call }

    private func read() async throws -> Data {
        // Closing and reopening while the CLI is slow shares the same bounded
        // read, rather than creating more subprocesses.
        if let pendingRead { return try await pendingRead.value }
        let call = self.call
        let task = Task { try await call(.list) }
        pendingRead = task
        defer { pendingRead = nil }
        return try await task.value
    }

    func refresh() async {
        guard !phase.busy else { return }
        generation += 1
        let request = generation
        snapshot = nil
        phase = .loading
        do {
            let result = try JSONDecoder().decode(PlyWorkspaces.self, from: await read())
            guard request == generation else { return }
            guard Set(result.layers.map(\.id)).count == result.layers.count else {
                throw PlyWorkspaceError.invalidResponse
            }
            snapshot = result
            phase = .ready
        } catch {
            guard request == generation else { return }
            phase = .failed("Can’t read workspaces. Check that Lattices is running, then refresh.")
        }
    }

    func focus(_ layer: PlyWorkspace) async {
        guard !phase.busy, let snapshot, snapshot.layers.contains(layer) else { return }
        if snapshot.isCurrent(layer) { return }
        phase = .switching(layer.label)
        do {
            struct Receipt: Decodable { let ok: Bool; let id: String; let mode: String }
            let receipt = try JSONDecoder().decode(Receipt.self, from: await call(.focus(layer.id)))
            guard receipt.ok, receipt.id == layer.id, receipt.mode == "focus" else {
                throw PlyWorkspaceError.invalidResponse
            }
            let fresh = try JSONDecoder().decode(PlyWorkspaces.self, from: await read())
            guard let selected = fresh.layers.first(where: { $0.id == layer.id }), fresh.isCurrent(selected) else {
                throw PlyWorkspaceError.invalidResponse
            }
            self.snapshot = fresh
            phase = .success(selected.label)
        } catch {
            self.snapshot = nil
            // A timed-out mutation may have reached the daemon. Never retry it silently.
            phase = .failed("Switch not confirmed. Refresh to check the current workspace.")
        }
    }

    func dismiss() {
        // Let an explicitly requested switch finish; discard a late read after closing.
        if case .switching = phase { return }
        generation += 1
        snapshot = nil
        phase = .idle
    }
}

enum PlyWorkspaceError: Error { case unavailable, failed, invalidResponse }
