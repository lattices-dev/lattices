import Darwin
import Foundation

enum ActionDriveLeaseError: LocalizedError {
    case invalidInput(String)
    case unknownLease(String)
    case leaseNotOwned(String)
    case leaseNotActive(String)
    case ambiguousLease
    case attentionApprovalRequired
    case systemPointerBusy
    case capabilityUnavailable(String)
    case runScopeMismatch

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .unknownLease(let leaseID):
            return "Unknown drive lease: \(leaseID)"
        case .leaseNotOwned(let leaseID):
            return "Drive lease \(leaseID) belongs to another client"
        case .leaseNotActive(let leaseID):
            return "Drive lease \(leaseID) is not active"
        case .ambiguousLease:
            return "Multiple drive leases are active for this client; pass leaseId explicitly"
        case .attentionApprovalRequired:
            return "Foreground keyboard or pointer control requires an approved attention lease"
        case .systemPointerBusy:
            return "The global system-pointer resource is already leased"
        case .capabilityUnavailable(let capability):
            return "Drive capability is unavailable or already consumed: \(capability)"
        case .runScopeMismatch:
            return "Drive request does not match the lease workflow run and workspace"
        }
    }
}

struct ActionDriveLease: Codable, Equatable, Sendable {
    var leaseId: String
    var agent: String
    var task: String
    var mode: String
    var status: String
    var sessionId: String
    var startedAt: String
    var lastActAt: String
    var releasedAt: String?
    var outcome: String?
    var summary: String?
    var implicit: Bool?
    var showSupervisionLabel: Bool?
    var stopFile: String
    var lastAxTier: String?
    /// Explicit opt-in to attention-tier control (pointer drags, coordinate
    /// targeting) on a background lease.
    ///
    /// Some real work has no accessibility element to aim at — dragging a
    /// selection rectangle across the desktop is coordinate-only by nature.
    /// Prohibiting it entirely made those flows impossible, so the caller
    /// declares the need up front instead. The flag rides on the lease, so the
    /// supervision surface can show that this driver holds pointer control.
    var pointerControl: Bool?
    var workflowRunId: String?
    var workspaceId: String?
    var capabilities: [String]?
    var resources: [String]?
    var consumedCapabilities: [String]?
    var lastOperationId: String?
    var operationStopFile: String?
    /// What the caller says it is, e.g. "Action MCP". Self-reported, like `agent`.
    var client: String? = nil
    /// What the agent saw on the other end of the socket, e.g. `bun 41250 ← claude 41012`.
    var clientProcess: String? = nil
    /// Acts recorded against this lease.
    var actCount: Int? = nil
}

struct ActionDriveBeginResult: Sendable {
    let status: String
    let lease: ActionDriveLease
    let reason: String?
}

struct ActionDriveStatusSnapshot: Codable, Equatable, Sendable {
    let state: String
    let leases: [ActionDriveLease]
    let activeCount: Int
}

private struct ActionStoredDriveLease: Codable, Sendable {
    var ownerID: String
    var lease: ActionDriveLease
}

actor ActionDriveLeaseStore {
    /// Idle window before a lease is swept.
    ///
    /// Was 90s, which is shorter than a single realistic step: waiting on a
    /// text-to-speech call, a build, or a screen recording all blow past it, and
    /// the driver only finds out via "Unknown lease" on the next call. The
    /// maximum duration below is the real safety bound; this is just a
    /// disconnect detector.
    static let idleExpiry: TimeInterval = 300
    static let maximumDuration: TimeInterval = 30 * 60
    static let terminalRetention: TimeInterval = 8

    private let rootURL: URL
    private let idleExpiry: TimeInterval
    private let maximumDuration: TimeInterval
    private let terminalRetention: TimeInterval
    private let now: @Sendable () -> Date
    private let publishesPresence: Bool
    private let sessionArchive: ActionSessionArchive?
    private var records: [String: ActionStoredDriveLease]
    private var disconnectedOwners: [String: Date] = [:]

    init(
        rootURL: URL = ActionDriveLeaseStore.defaultRootURL,
        idleExpiry: TimeInterval = ActionDriveLeaseStore.idleExpiry,
        maximumDuration: TimeInterval = ActionDriveLeaseStore.maximumDuration,
        terminalRetention: TimeInterval = ActionDriveLeaseStore.terminalRetention,
        publishesPresence: Bool = true,
        sessionArchive: ActionSessionArchive? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.sessionArchive = sessionArchive
        self.idleExpiry = idleExpiry
        self.maximumDuration = maximumDuration
        self.terminalRetention = terminalRetention
        self.publishesPresence = publishesPresence
        self.now = now

        var loaded = Self.loadRecords(from: rootURL)
        let startupDate = now()
        for (leaseID, var record) in loaded where record.lease.status == "driving" {
            record.lease.status = "expired"
            record.lease.outcome = "expired"
            record.lease.releasedAt = actionDriveISO8601(startupDate)
            record.lease.summary = "Lease owner was disconnected when the Action agent restarted"
            loaded[leaseID] = record
            try? Self.persist(record, rootURL: rootURL)
            sessionArchive?.record(record.lease, event: Self.event("drive.lease_ended", record.lease))
            Self.signalStop(for: record.lease)
            Self.signalOperationStop(for: record.lease)
            if publishesPresence {
                ActionDrivePresencePublisher.remove(leaseID: leaseID)
            }
        }
        records = loaded
    }

    func begin(
        ownerID: String,
        agent rawAgent: String,
        task rawTask: String,
        mode rawMode: String?,
        sessionID rawSessionID: String?,
        implicit: Bool,
        showSupervisionLabel: Bool = true,
        pointerControl: Bool = false,
        attentionApproval: String? = nil,
        capability: String? = nil,
        resource: String? = nil,
        workflowRunID rawWorkflowRunID: String? = nil,
        workspaceID rawWorkspaceID: String? = nil,
        client rawClient: String? = nil,
        clientProcess: String? = nil
    ) throws -> ActionDriveBeginResult {
        let at = now()
        try sweep(at: at)
        guard disconnectedOwners[ownerID] == nil else {
            throw ActionDriveLeaseError.invalidInput("Drive client disconnected before the lease began")
        }

        let agent = rawAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else {
            throw ActionDriveLeaseError.invalidInput("drive.begin requires agent")
        }
        guard !task.isEmpty else {
            throw ActionDriveLeaseError.invalidInput("drive.begin requires task")
        }

        let mode = rawMode == "attention" ? "attention" : "background"
        let leaseID = actionDriveLeaseID(at: at)
        let sessionID = rawSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSessionID = sessionID?.isEmpty == false ? sessionID! : "drive_\(leaseID)"
        let stopFile = rootURL.appendingPathComponent("\(actionDriveSanitize(leaseID)).stop").path
        try? FileManager.default.removeItem(atPath: stopFile)
        let atString = actionDriveISO8601(at)

        let workflowRunID = rawWorkflowRunID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = rawWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var grantedCapabilities: [String]?
        var grantedResources: [String]?
        if mode == "attention" {
            guard attentionApproval == "approved",
                  capability == ActionWorkspaceDragFileRequest.capability,
                  resource == ActionWorkspaceDragFileRequest.systemPointerResource,
                  let workflowRunID,
                  actionDriveIsValidIdentifier(workflowRunID),
                  let workspaceID,
                  actionDriveIsValidIdentifier(workspaceID) else {
                throw ActionDriveLeaseError.attentionApprovalRequired
            }
            guard !records.values.contains(where: {
                $0.lease.status == "driving"
                    && ($0.lease.resources ?? []).contains(ActionWorkspaceDragFileRequest.systemPointerResource)
            }) else {
                throw ActionDriveLeaseError.systemPointerBusy
            }
            grantedCapabilities = [ActionWorkspaceDragFileRequest.capability]
            grantedResources = [ActionWorkspaceDragFileRequest.systemPointerResource]
        }

        let lease = ActionDriveLease(
            leaseId: leaseID,
            agent: agent,
            task: task,
            mode: mode,
            status: "driving",
            sessionId: resolvedSessionID,
            startedAt: atString,
            lastActAt: atString,
            releasedAt: nil,
            outcome: nil,
            summary: nil,
            implicit: implicit ? true : nil,
            showSupervisionLabel: showSupervisionLabel,
            stopFile: stopFile,
            lastAxTier: nil,
            pointerControl: pointerControl ? true : nil,
            workflowRunId: workflowRunID,
            workspaceId: workspaceID,
            capabilities: grantedCapabilities,
            resources: grantedResources,
            consumedCapabilities: nil,
            lastOperationId: nil,
            operationStopFile: nil,
            client: rawClient?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            clientProcess: clientProcess,
            actCount: 0
        )
        let record = ActionStoredDriveLease(ownerID: ownerID, lease: lease)
        records[leaseID] = record
        try persist(record)
        do {
            try publishPresence(for: lease, at: at)
        } catch {
            records.removeValue(forKey: leaseID)
            try? FileManager.default.removeItem(at: recordURL(for: leaseID))
            if publishesPresence {
                ActionDrivePresencePublisher.remove(leaseID: leaseID)
            }
            throw error
        }
        var began = Self.event("drive.lease_began", lease)
        began["agent"] = lease.agent
        began["task"] = lease.task
        began["mode"] = lease.mode
        began["implicit"] = implicit
        sessionArchive?.record(lease, event: began)
        return ActionDriveBeginResult(status: "granted", lease: lease, reason: nil)
    }

    /// Atomically verifies connection ownership and consumes the one-shot pointer capability.
    /// The actor boundary makes capability consumption and global resource ownership indivisible.
    func authorizeWorkspaceDrag(
        ownerID: String,
        leaseID: String,
        operationID: String,
        workflowRunID: String,
        workspaceID: String
    ) throws -> ActionDriveLease {
        let at = now()
        try sweep(at: at)
        guard actionDriveIsValidIdentifier(operationID) else {
            throw ActionDriveLeaseError.invalidInput("workspace.dragFile requires a valid operationId")
        }
        guard var record = try resolveActiveRecord(ownerID: ownerID, leaseID: leaseID) else {
            throw ActionDriveLeaseError.unknownLease(leaseID)
        }
        guard record.lease.mode == "attention",
              (record.lease.resources ?? []).contains(ActionWorkspaceDragFileRequest.systemPointerResource),
              (record.lease.capabilities ?? []).contains(ActionWorkspaceDragFileRequest.capability) else {
            throw ActionDriveLeaseError.attentionApprovalRequired
        }
        guard record.lease.workflowRunId == workflowRunID,
              record.lease.workspaceId == workspaceID else {
            throw ActionDriveLeaseError.runScopeMismatch
        }
        guard !(record.lease.consumedCapabilities ?? []).contains(ActionWorkspaceDragFileRequest.capability) else {
            throw ActionDriveLeaseError.capabilityUnavailable(ActionWorkspaceDragFileRequest.capability)
        }

        record.lease.consumedCapabilities = [ActionWorkspaceDragFileRequest.capability]
        record.lease.lastOperationId = operationID
        let operationStopFile = rootURL.appendingPathComponent(
            "\(actionDriveSanitize(leaseID)).\(actionDriveSanitize(operationID)).operation.stop"
        ).path
        try? FileManager.default.removeItem(atPath: operationStopFile)
        record.lease.operationStopFile = operationStopFile
        record.lease.lastAxTier = "attention"
        record.lease.lastActAt = actionDriveISO8601(at)
        records[leaseID] = record
        try persist(record)
        try publishPresence(for: record.lease, at: at)
        return record.lease
    }

    func cancelWorkspaceOperation(
        ownerID: String,
        leaseID: String,
        operationID: String
    ) throws -> ActionDriveLease {
        try sweep(at: now())
        guard let record = try resolveActiveRecord(ownerID: ownerID, leaseID: leaseID) else {
            throw ActionDriveLeaseError.unknownLease(leaseID)
        }
        guard record.lease.lastOperationId == operationID,
              let operationStopFile = record.lease.operationStopFile else {
            throw ActionDriveLeaseError.runScopeMismatch
        }
        Self.signalStop(atPath: operationStopFile)
        return record.lease
    }

    func touch(
        ownerID: String,
        leaseID: String?,
        axTier: String?,
        actionKind: String? = nil
    ) throws -> ActionDriveLease? {
        let at = now()
        try sweep(at: at)
        guard var record = try resolveActiveRecord(ownerID: ownerID, leaseID: leaseID) else {
            return nil
        }
        if axTier == "attention"
            && record.lease.mode != "attention"
            && record.lease.pointerControl != true {
            throw ActionDriveLeaseError.attentionApprovalRequired
        }

        record.lease.lastActAt = actionDriveISO8601(at)
        if let axTier, !axTier.isEmpty {
            record.lease.lastAxTier = axTier
            record.lease.actCount = (record.lease.actCount ?? 0) + 1
        }
        records[record.lease.leaseId] = record
        try persist(record)
        if let axTier, !axTier.isEmpty {
            var act = Self.event("drive.act_tier", record.lease)
            act["axTier"] = axTier
            act["actionKind"] = actionKind
            sessionArchive?.record(record.lease, event: act)
        }
        do {
            try publishPresence(for: record.lease, at: at)
        } catch {
            record.lease.status = "cancelled"
            record.lease.outcome = "cancelled"
            record.lease.releasedAt = actionDriveISO8601(at)
            record.lease.summary = "Supervision presence became unavailable"
            records[record.lease.leaseId] = record
            try? persist(record)
            Self.signalStop(for: record.lease)
            Self.signalOperationStop(for: record.lease)
            if publishesPresence {
                ActionDrivePresencePublisher.remove(leaseID: record.lease.leaseId)
            }
            throw error
        }
        return record.lease
    }

    func release(
        ownerID: String,
        leaseID: String,
        outcome rawOutcome: String?,
        summary: String?
    ) throws -> ActionDriveLease {
        let at = now()
        try sweep(at: at)
        guard var record = records[leaseID] else {
            throw ActionDriveLeaseError.unknownLease(leaseID)
        }
        guard record.ownerID == ownerID else {
            throw ActionDriveLeaseError.leaseNotOwned(leaseID)
        }
        guard record.lease.status == "driving" else {
            return record.lease
        }

        let outcome = ["done", "failed", "cancelled"].contains(rawOutcome ?? "")
            ? rawOutcome!
            : "cancelled"
        record.lease.status = outcome
        record.lease.outcome = outcome
        record.lease.releasedAt = actionDriveISO8601(at)
        record.lease.lastActAt = actionDriveISO8601(at)
        record.lease.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? record.lease.summary
        records[leaseID] = record
        try persist(record)
        sessionArchive?.record(record.lease, event: Self.event("drive.lease_ended", record.lease))
        Self.signalStop(for: record.lease)
        Self.signalOperationStop(for: record.lease)
        try publishPresence(for: record.lease, at: at)
        return record.lease
    }

    func isDriving(ownerID: String) -> Bool {
        records.values.contains { $0.ownerID == ownerID && $0.lease.status == "driving" }
    }

    func disconnectOwner(by ownerID: String, summary: String) {
        let at = now()
        disconnectedOwners[ownerID] = at
        for (leaseID, var record) in records
            where record.ownerID == ownerID && record.lease.status == "driving" {
            record.lease.status = "cancelled"
            record.lease.outcome = "cancelled"
            record.lease.releasedAt = actionDriveISO8601(at)
            record.lease.lastActAt = actionDriveISO8601(at)
            record.lease.summary = summary
            records[leaseID] = record
            try? persist(record)
            sessionArchive?.record(record.lease, event: Self.event("drive.lease_ended", record.lease))
            Self.signalStop(for: record.lease)
            Self.signalOperationStop(for: record.lease)
            try? publishPresence(for: record.lease, at: at)
        }
    }

    /// Applies the archive's age and size caps, sparing sessions still driving.
    func pruneSessions() -> ActionSessionPruneResult? {
        sessionArchive?.prune(keeping: activeSessionIDs, now: now())
    }

    func clearSessions() -> ActionSessionPruneResult? {
        sessionArchive?.clear(keeping: activeSessionIDs)
    }

    private var activeSessionIDs: Set<String> {
        Set(records.values.filter { $0.lease.status == "driving" }.map(\.lease.sessionId))
    }

    private static func event(_ type: String, _ lease: ActionDriveLease) -> [String: Any] {
        var event: [String: Any] = [
            "type": type,
            "at": lease.releasedAt ?? lease.lastActAt,
            "leaseId": lease.leaseId,
            "sessionId": lease.sessionId,
        ]
        if type == "drive.lease_ended" {
            event["outcome"] = lease.outcome ?? lease.status
            event["summary"] = lease.summary
        }
        return event
    }

    func status() throws -> ActionDriveStatusSnapshot {
        try sweep(at: now())
        let leases = records.values
            .map(\.lease)
            .sorted { $0.lastActAt > $1.lastActAt }
        let activeCount = leases.filter { $0.status == "driving" }.count
        return ActionDriveStatusSnapshot(
            state: activeCount > 0 ? "driving" : "idle",
            leases: leases,
            activeCount: activeCount
        )
    }

    func sweep() throws {
        try sweep(at: now())
    }

    private func sweep(at: Date) throws {
        disconnectedOwners = disconnectedOwners.filter {
            at.timeIntervalSince($0.value) < maximumDuration
        }
        for (leaseID, var record) in records {
            if record.lease.status == "driving" {
                let stopRequested = FileManager.default.fileExists(atPath: record.lease.stopFile)
                let lastAct = actionDriveDate(record.lease.lastActAt) ?? at
                let started = actionDriveDate(record.lease.startedAt) ?? at
                let reason: String?
                if stopRequested {
                    reason = "stop-file"
                } else if at.timeIntervalSince(lastAct) >= idleExpiry {
                    reason = "idle"
                } else if at.timeIntervalSince(started) >= maximumDuration {
                    reason = "max-duration"
                } else {
                    reason = nil
                }

                if let reason {
                    let stopped = reason == "stop-file"
                    record.lease.status = stopped ? "cancelled" : "expired"
                    record.lease.outcome = stopped ? "cancelled" : "expired"
                    record.lease.releasedAt = actionDriveISO8601(at)
                    record.lease.summary = stopped
                        ? "Stopped by supervisor"
                        : (reason == "idle" ? "Lease expired after idle silence" : "Lease exceeded maximum duration")
                    records[leaseID] = record
                    try persist(record)
                    sessionArchive?.record(record.lease, event: Self.event("drive.lease_ended", record.lease))
                    Self.signalStop(for: record.lease)
                    Self.signalOperationStop(for: record.lease)
                    try publishPresence(for: record.lease, at: at)
                } else {
                    try publishPresence(for: record.lease, at: at)
                }
                continue
            }

            guard let releasedAt = record.lease.releasedAt.flatMap(actionDriveDate),
                  at.timeIntervalSince(releasedAt) >= terminalRetention else {
                continue
            }
            records.removeValue(forKey: leaseID)
            try? FileManager.default.removeItem(at: recordURL(for: leaseID))
            try? FileManager.default.removeItem(atPath: record.lease.stopFile)
            if let operationStopFile = record.lease.operationStopFile {
                try? FileManager.default.removeItem(atPath: operationStopFile)
            }
            if publishesPresence {
                ActionDrivePresencePublisher.remove(leaseID: leaseID)
            }
        }
    }

    private func resolveActiveRecord(
        ownerID: String,
        leaseID: String?
    ) throws -> ActionStoredDriveLease? {
        if let leaseID, !leaseID.isEmpty {
            guard let record = records[leaseID] else {
                throw ActionDriveLeaseError.unknownLease(leaseID)
            }
            guard record.ownerID == ownerID else {
                throw ActionDriveLeaseError.leaseNotOwned(leaseID)
            }
            guard record.lease.status == "driving" else {
                throw ActionDriveLeaseError.leaseNotActive(leaseID)
            }
            return record
        }

        let active = records.values.filter {
            $0.ownerID == ownerID && $0.lease.status == "driving"
        }
        if active.count > 1 {
            throw ActionDriveLeaseError.ambiguousLease
        }
        return active.first
    }

    private func persist(_ record: ActionStoredDriveLease) throws {
        try Self.persist(record, rootURL: rootURL)
    }

    private static func persist(_ record: ActionStoredDriveLease, rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        let url = rootURL.appendingPathComponent("\(actionDriveSanitize(record.lease.leaseId)).json")
        try data.write(to: url, options: .atomic)
    }

    private static func signalStop(for lease: ActionDriveLease) {
        signalStop(atPath: lease.stopFile)
    }

    private static func signalOperationStop(for lease: ActionDriveLease) {
        guard let operationStopFile = lease.operationStopFile else { return }
        signalStop(atPath: operationStopFile)
    }

    private static func signalStop(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("stop\n".utf8).write(to: url, options: .atomic)
    }

    private func publishPresence(for lease: ActionDriveLease, at: Date) throws {
        guard publishesPresence else {
            return
        }
        guard lease.showSupervisionLabel != false else {
            ActionDrivePresencePublisher.remove(leaseID: lease.leaseId)
            return
        }
        try ActionDrivePresencePublisher.publish(
            lease: lease,
            at: at,
            activeTTL: 2.5,
            terminalTTL: terminalRetention
        )
    }

    private func recordURL(for leaseID: String) -> URL {
        rootURL.appendingPathComponent("\(actionDriveSanitize(leaseID)).json")
    }

    private static func loadRecords(from rootURL: URL) -> [String: ActionStoredDriveLease] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var loaded: [String: ActionStoredDriveLease] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }
            if let record = try? decoder.decode(ActionStoredDriveLease.self, from: data) {
                loaded[record.lease.leaseId] = record
                continue
            }
            // Migrate records written by the earlier process-local implementation.
            if let lease = try? decoder.decode(ActionDriveLease.self, from: data) {
                loaded[lease.leaseId] = ActionStoredDriveLease(ownerID: "stale", lease: lease)
            }
        }
        return loaded
    }

    private static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Action/runtime/drive/leases", isDirectory: true)
    }
}

private struct ActionDriveSupervisionRegistration: Codable {
    let id: String
    let title: String
    let detail: String?
    let controlFile: String?
    let stopFile: String?
    let ownsVisibleControls: Bool?
    let avoidedDisplayID: UInt32?
    let expiresAt: String?
    let updatedAt: String
}

private enum ActionDrivePresencePublisher {
    static func publish(
        lease: ActionDriveLease,
        at: Date,
        activeTTL: TimeInterval,
        terminalTTL: TimeInterval
    ) throws {
        let expirationBase = lease.status == "driving"
            ? at
            : (lease.releasedAt.flatMap(actionDriveDate) ?? at)
        let expiration = expirationBase.addingTimeInterval(
            lease.status == "driving" ? activeTTL : terminalTTL
        )
        let registration = ActionDriveSupervisionRegistration(
            id: lease.leaseId,
            title: "\(lease.agent) · \(lease.task)",
            detail: detail(for: lease),
            controlFile: nil,
            stopFile: lease.stopFile,
            ownsVisibleControls: false,
            avoidedDisplayID: nil,
            expiresAt: actionDriveISO8601(expiration),
            updatedAt: actionDriveISO8601(at)
        )

        try FileManager.default.createDirectory(at: registrationsURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: overlayStopURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registration).write(
            to: registrationURL(leaseID: lease.leaseId),
            options: .atomic
        )
        try ensureOverlayRunning()
    }

    static func remove(leaseID: String) {
        try? FileManager.default.removeItem(at: registrationURL(leaseID: leaseID))
    }

    private static var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Action/runtime/supervision", isDirectory: true)
    }

    private static var registrationsURL: URL {
        baseURL.appendingPathComponent("registrations", isDirectory: true)
    }

    private static var overlayPIDURL: URL {
        baseURL.appendingPathComponent("overlay.pid")
    }

    private static var overlayStopURL: URL {
        baseURL.appendingPathComponent("overlay.stop")
    }

    private static func registrationURL(leaseID: String) -> URL {
        registrationsURL.appendingPathComponent("\(actionDriveSanitize(leaseID)).json")
    }

    private static func detail(for lease: ActionDriveLease) -> String {
        guard lease.status == "driving" else {
            let outcome = (lease.outcome ?? lease.status).uppercased()
            if let summary = lease.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return "\(outcome) · \(summary)"
            }
            return outcome
        }

        switch lease.lastAxTier {
        case "observe":
            return "Observing the current app"
        case "semantic":
            return "Using app controls in the background"
        case "target-focus":
            return "Changing focus in the target app"
        case "app-api":
            return "Using the app automation interface"
        case "blink":
            return "Acting on the agent layer"
        case "attention":
            return "Using foreground keyboard or pointer control"
        default:
            return "Working in the background"
        }
    }

    private static func ensureOverlayRunning() throws {
        if let raw = try? String(contentsOf: overlayPIDURL, encoding: .utf8),
           let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            return
        }

        let bundleURL = try resolveActionAppURL()
        let replyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("action-drive-overlay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: replyURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n",
            bundleURL.path,
            "--args",
            "supervision-overlay",
            "--reply-file",
            replyURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        for _ in 0..<50 {
            if let data = try? Data(contentsOf: replyURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["status"] as? String == "supervision-overlay-running" {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NSError(
            domain: "ActionDrivePresencePublisher",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Supervision overlay did not acknowledge launch"]
        )
    }

    private static func resolveActionAppURL() throws -> URL {
        var candidate = Bundle.main.bundleURL
        while candidate.path != "/" {
            if candidate.lastPathComponent == "Action.app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ActionDrivePresencePublisher",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to resolve the containing Action.app bundle"]
        )
    }
}

private func actionDriveISO8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func actionDriveDate(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
        return date
    }
    return ISO8601DateFormatter().date(from: raw)
}

private func actionDriveLeaseID(at: Date) -> String {
    let stamp = actionDriveISO8601(at)
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "T", with: "_")
        .replacingOccurrences(of: "Z", with: "")
    return "drive_\(stamp)_\(UUID().uuidString.lowercased().prefix(8))"
}

private func actionDriveSanitize(_ raw: String) -> String {
    raw.replacingOccurrences(
        of: #"[^A-Za-z0-9._-]+"#,
        with: "_",
        options: .regularExpression
    )
}

private func actionDriveIsValidIdentifier(_ raw: String) -> Bool {
    guard !raw.isEmpty, raw.count <= 200 else {
        return false
    }
    return raw.range(of: #"^[A-Za-z0-9._:@-]+$"#, options: .regularExpression) != nil
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
