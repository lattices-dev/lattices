#if os(macOS)
import BlinkCore
@testable import BlinkPeer
import CryptoKit
import Darwin
import Foundation
import Testing

/// Manual end-to-end host for a clean simulator or disposable device install.
/// This never reads BlinkPaths, preferences, the Keychain, or an existing notes root.
/// Normal test runs skip the listener. See the opt-in value and controls below.
@Suite("Canvas synthetic LAN fixture")
struct CanvasLANFixtureTests {
    @Test(
        "manual discovery, approval, and snapshot host",
        .enabled(
            if: ProcessInfo.processInfo.environment["CANVAS_LAN_FIXTURE"] == "ENABLE_SYNTHETIC_NOTES_ONLY",
            "Set CANVAS_LAN_FIXTURE=ENABLE_SYNTHETIC_NOTES_ONLY for a ten-minute synthetic LAN host."
        )
    )
    @MainActor
    func manualHost() async throws {
        let fixture = try CanvasLANFixture()
        let server = try BlinkLANPeerServer(
            hostID: UUID().uuidString.lowercased(),
            displayName: "Canvas Validation \(fixture.root.lastPathComponent.suffix(6))",
            snapshotService: BlinkSnapshotService(
                builder: BlinkSnapshotBuilder(notesDirectory: fixture.notesDirectory)
            ),
            trustStore: BlinkPeerTrustStore(
                storage: BlinkInMemorySecretStorage(),
                storageKey: "synthetic-lan-fixture"
            ),
            approvalHandler: { identity in await fixture.requestApproval(identity) }
        )
        try await fixture.run(server: server)
    }

    @Test("approval requires the current request ID and complete credential fingerprint")
    func approvalBinding() {
        let request = CanvasLANFixtureRequest(
            id: "current-request", fingerprint: "full-fingerprint", name: "Untrusted device name",
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        #expect(request.matches(.init(action: "approve", requestID: "current-request", fingerprint: "full-fingerprint")))
        #expect(!request.matches(.init(action: "approve", requestID: "stale-request", fingerprint: "full-fingerprint")))
        #expect(!request.matches(.init(action: "approve", requestID: "current-request", fingerprint: "full")))
        #expect(!request.matches(.init(action: "approve")))
        #expect(!request.matches(.init(action: "stop", requestID: "current-request", fingerprint: "full-fingerprint")))
    }

    @Test("fixture fingerprints are stable without exposing the bearer credential")
    func credentialFingerprint() {
        let credential = String(repeating: "a", count: 64)
        let fingerprint = CanvasLANFixture.fingerprint(credential)
        #expect(fingerprint.count == 64)
        #expect(fingerprint != credential)
        #expect(fingerprint == CanvasLANFixture.fingerprint(credential))
        #expect(fingerprint != CanvasLANFixture.fingerprint(String(repeating: "b", count: 64)))
    }
}

private struct CanvasLANFixtureControl: Codable {
    var action: String
    var requestID: String? = nil
    var fingerprint: String? = nil
}

private struct CanvasLANFixtureRequest: Codable {
    var id: String
    var fingerprint: String
    var name: String
    var expiresAt: Date

    func matches(_ control: CanvasLANFixtureControl) -> Bool {
        ["approve", "deny"].contains(control.action)
            && control.requestID == id && control.fingerprint == fingerprint
    }
}

private enum CanvasLANFixtureError: Error {
    case temporaryDirectory(Int32)
    case unsafeControlFile
    case invalidControl(String)
}

@MainActor
private final class CanvasLANFixture {
    let root: URL
    let notesDirectory: URL
    private var controlURL: URL { root.appendingPathComponent("control.json") }
    private var statusURL: URL { root.appendingPathComponent("status.json") }
    private let startedAt = Date()
    private let deadline = ContinuousClock.now.advanced(by: .seconds(600))
    private var pending: CanvasLANFixtureRequest?
    private var pendingDeadline: ContinuousClock.Instant?
    private var approval: CheckedContinuation<Bool, Never>?
    private var revision = 1
    private var mode = "starting"
    private var lastEvent = "No device has been approved."
    private var stopRequested = false

    init() throws {
        // mkdtemp creates a new 0700 directory atomically, ignoring all home/env overrides.
        var template = Array("/private/tmp/canvas-lan-fixture-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw CanvasLANFixtureError.temporaryDirectory(errno) }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notesDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try writeSyntheticNotes()
    }

    nonisolated static func fingerprint(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func requestApproval(_ identity: BlinkPeerClientIdentity) async -> Bool {
        guard !stopRequested, mode == "advertising", ContinuousClock.now < deadline, pending == nil else {
            return false
        }
        pending = CanvasLANFixtureRequest(
            id: UUID().uuidString.lowercased(), fingerprint: Self.fingerprint(identity.credential),
            name: identity.name, expiresAt: Date().addingTimeInterval(60)
        )
        pendingDeadline = .now.advanced(by: .seconds(60))
        lastEvent = "Approval requested. Review pendingRequest; names are not authenticated identity."
        // The main loop publishes the request, accepts an exact response, or denies at timeout.
        return await withCheckedContinuation { approval = $0 }
    }

    func run(server: BlinkLANPeerServer) async throws {
        defer {
            server.stop()
            resolveApproval(false)
            mode = "stopped"
            try? writeStatus(server: server)
        }
        server.start()
        mode = "advertising"
        try writeStatus(server: server)
        print("CANVAS_LAN_FIXTURE_STATUS=\(statusURL.path)")
        print("CANVAS_LAN_FIXTURE_CONTROL=\(controlURL.path)")
        print("Synthetic notes only. Stops in 10 minutes; no devices are approved automatically.")
        while !stopRequested, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let pendingDeadline, ContinuousClock.now >= pendingDeadline {
                lastEvent = "Pending approval expired; access denied."
                resolveApproval(false)
            }
            do {
                if let control = try consumeControl() { try apply(control, server: server) }
            } catch {
                lastEvent = "Control rejected: \(error)"
            }
            if let failure = server.advertisingFailure {
                lastEvent = "Advertising failed: \(failure)"
                stopRequested = true
            }
            try writeStatus(server: server)
            try await Task.sleep(for: .milliseconds(250))
        }
        if !stopRequested { lastEvent = "Ten-minute deadline reached; listener stopped." }
    }

    private func apply(_ control: CanvasLANFixtureControl, server: BlinkLANPeerServer) throws {
        switch control.action {
        case "approve", "deny":
            guard let pending, let pendingDeadline, ContinuousClock.now < pendingDeadline,
                  pending.matches(control) else {
                throw CanvasLANFixtureError.invalidControl("Request ID/fingerprint is missing, stale, or mismatched.")
            }
            let approved = control.action == "approve"
            lastEvent = "Request \(pending.id) \(approved ? "approved" : "denied") by control file."
            resolveApproval(approved)
        case "update-note":
            revision += 1
            try writeSyntheticNotes()
            lastEvent = "Synthetic note advanced to revision \(revision); sync in the app to fetch it."
        case "pause":
            resolveApproval(false)
            server.stop()
            mode = "paused"
            lastEvent = "Host paused; the app can exercise its offline cache."
        case "resume":
            guard mode == "paused" else { throw CanvasLANFixtureError.invalidControl("Host is not paused.") }
            server.start()
            mode = "advertising"
            lastEvent = "Host resumed with the same temporary identity and approvals."
        case "revoke":
            guard let fingerprint = control.fingerprint,
                  let peer = server.trustedPeers.first(where: { Self.fingerprint($0.id) == fingerprint }) else {
                throw CanvasLANFixtureError.invalidControl("No approved device matches the complete fingerprint.")
            }
            _ = try server.revokeTrustedPeer(id: peer.id)
            lastEvent = "Device \(fingerprint) revoked; syncing requires a new exact-request approval."
        case "stop":
            stopRequested = true
            lastEvent = "Stopped by control file."
        default:
            throw CanvasLANFixtureError.invalidControl("Unknown action.")
        }
    }

    private func resolveApproval(_ approved: Bool) {
        let continuation = approval
        approval = nil
        pending = nil
        pendingDeadline = nil
        continuation?.resume(returning: approved)
    }

    private func consumeControl() throws -> CanvasLANFixtureControl? {
        // Never follow a control-file symlink or accept another user's/oversized input.
        let fd = open(controlURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CanvasLANFixtureError.unsafeControlFile
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: controlURL)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 8192 else {
            throw CanvasLANFixtureError.unsafeControlFile
        }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw CanvasLANFixtureError.unsafeControlFile }
        return try JSONDecoder().decode(CanvasLANFixtureControl.self, from: data)
    }

    private func writeSyntheticNotes() throws {
        var placement = NotePresentation()
        placement.workspace = "validation"
        placement.slot = 1
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let notes = [
            Note(
                id: "canvas-sync-fixture",
                content: "# Canvas Sync Fixture\n\nSynthetic revision \(revision).\n\n- [x] Read-only LAN snapshot\n- [ ] Verify this revision on iPhone or iPad\n\nNo personal notes are served by this host.\n",
                createdAt: date, updatedAt: date.addingTimeInterval(Double(revision)),
                tags: ["validation", "synthetic"], pinned: true, presentation: placement
            ),
            Note(
                id: "canvas-offline-fixture",
                content: "# Canvas Offline Fixture\n\nSearch for **orchard**. Read this note after the host is paused.\n\n> This is disposable acceptance-test data.\n",
                createdAt: date, updatedAt: date, tags: ["offline", "synthetic"]
            ),
        ]
        for note in notes {
            let url = notesDirectory.appendingPathComponent("\(note.id).md")
            try Data(Frontmatter.encode(note).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func writeStatus(server: BlinkLANPeerServer) throws {
        struct ApprovedDevice: Encodable { var name: String; var fingerprint: String }
        struct Status: Encodable {
            var mode: String
            var host: BlinkPeerHost
            var startedAt: Date
            var stopsBy: Date
            var pid: Int32
            var notesDirectory: String
            var controlFile: String
            var revision: Int
            var etag: String
            var pendingRequest: CanvasLANFixtureRequest?
            var approvedDevices: [ApprovedDevice]
            var lastEvent: String
            var actions: [String]
        }
        let status = Status(
            mode: mode, host: server.host, startedAt: startedAt,
            stopsBy: startedAt.addingTimeInterval(600), pid: getpid(),
            notesDirectory: notesDirectory.path, controlFile: controlURL.path,
            revision: revision, etag: try BlinkSnapshotBuilder(notesDirectory: notesDirectory).build().etag,
            pendingRequest: pending,
            approvedDevices: server.trustedPeers.map { ApprovedDevice(name: $0.name, fingerprint: Self.fingerprint($0.id)) },
            lastEvent: lastEvent,
            actions: ["approve (requestID + fingerprint)", "deny (requestID + fingerprint)", "update-note", "pause", "resume", "revoke (fingerprint)", "stop"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(status).write(to: statusURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
    }
}
#endif
