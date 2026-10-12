import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Network

enum ActionAgentRuntimePermissionState: String {
    case granted
    case denied
}

struct ActionAgentRuntimeState {
    let startedAt = Date()
}

/// Keeps a connection's receive side live while requests execute concurrently. Only response
/// delivery is serialized, so a later cancellation frame on the same WebSocket can be handled
/// while an earlier attention-taking operation is still in progress.
final class ActionAgentRequestScheduler: @unchecked Sendable {
    private let responseQueue: DispatchQueue

    init(responseQueue: DispatchQueue) {
        self.responseQueue = responseQueue
    }

    func dispatch(
        receiveNext: @escaping @Sendable () -> Void,
        process: @escaping @Sendable () async -> ActionAgentResponse,
        send: @escaping @Sendable (ActionAgentResponse) -> Void
    ) {
        // Re-arm first. Waiting for `process` here deadlocks same-connection cancellation.
        receiveNext()
        Task {
            let response = await process()
            responseQueue.async {
                send(response)
            }
        }
    }
}

/// Who is on the other end of each connection, resolved at most once.
actor ActionAgentPeerRegistry {
    private var ports: [String: UInt16] = [:]
    private var resolved: [String: String?] = [:]

    func register(ownerID: String, port: UInt16) {
        ports[ownerID] = port
    }

    func forget(ownerID: String) {
        ports.removeValue(forKey: ownerID)
        resolved.removeValue(forKey: ownerID)
    }

    func describe(ownerID: String) -> String? {
        if let cached = resolved[ownerID] {
            return cached
        }
        let label = ports[ownerID].flatMap(ActionAgentPeer.describe(localPort:))
        resolved[ownerID] = label
        return label
    }
}

final class ActionAgentRuntimeServer: @unchecked Sendable {
    private static let protocolVersion = "2"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.action.agent.listener")
    private let runtimeState = ActionAgentRuntimeState()
    private let driveStore: ActionDriveLeaseStore
    private let workspaceDragFileOperation: ActionWorkspaceDragFileOperation
    private let authentication: ActionAgentAuthentication
    private let requestScheduler: ActionAgentRequestScheduler
    private let parentProcessID: pid_t?
    private let idleExitSeconds: TimeInterval?
    private var parentWatchTimer: DispatchSourceTimer?
    private var driveSweepTimer: DispatchSourceTimer?
    private var sessionPruneTimer: DispatchSourceTimer?
    private let peers = ActionAgentPeerRegistry()
    private var idleExitTimer: DispatchSourceTimer?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var lastConnectionActivityAt = Date()

    init(port: UInt16, parentProcessID: pid_t?, idleExitSeconds: TimeInterval?) throws {
        self.parentProcessID = parentProcessID
        self.idleExitSeconds = idleExitSeconds
        let driveStore = ActionDriveLeaseStore(sessionArchive: ActionSessionArchive())
        self.driveStore = driveStore
        self.workspaceDragFileOperation = ActionWorkspaceDragFileOperation(driveStore: driveStore)
        self.authentication = try ActionAgentAuthentication.create()
        self.requestScheduler = ActionAgentRequestScheduler(
            responseQueue: DispatchQueue(label: "dev.action.agent.responses")
        )
        let tcpOptions = NWProtocolTCP.Options()
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ActionAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        guard let loopbackAddress = IPv4Address(ActionAgentDefaults.host) else {
            throw NSError(domain: "ActionAgent", code: 31, userInfo: [NSLocalizedDescriptionKey: "Invalid loopback address"])
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopbackAddress), port: endpointPort)
        listener = try NWListener(using: parameters)
    }

    @MainActor
    func run() -> Never {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = self.listener.port?.rawValue ?? 0
                print("ActionAgent listening on ws://\(ActionAgentDefaults.host):\(port)")
            case .failed(let error):
                FileHandle.standardError.write(Data("ActionAgent listener failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)
        startParentWatchIfNeeded()
        startDriveSweep()
        startSessionPrune()
        startIdleExitIfNeeded()
        NSApplication.shared.run()
        exit(0)
    }

    private func handle(connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let ownerID = UUID().uuidString
        activeConnections[identifier] = connection
        lastConnectionActivityAt = Date()
        if case .hostPort(_, let port) = connection.endpoint {
            Task { [peers] in await peers.register(ownerID: ownerID, port: port.rawValue) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                _ = error
                connection.cancel()
                self.connectionDidClose(identifier: identifier, ownerID: ownerID)
            case .cancelled:
                self.connectionDidClose(identifier: identifier, ownerID: ownerID)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveNextMessage(on: connection, ownerID: ownerID)
    }

    private func receiveNextMessage(on connection: NWConnection, ownerID: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                _ = error
                let identifier = ObjectIdentifier(connection)
                self.connectionDidClose(identifier: identifier, ownerID: ownerID)
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                self.receiveNextMessage(on: connection, ownerID: ownerID)
                return
            }

            self.requestScheduler.dispatch(
                receiveNext: { [weak self] in
                    self?.receiveNextMessage(on: connection, ownerID: ownerID)
                },
                process: { [weak self] in
                    guard let self else {
                        return ActionAgentResponse(
                            id: "cancelled",
                            ok: false,
                            error: "ActionAgent connection handler stopped"
                        )
                    }
                    return await self.processMessage(data, ownerID: ownerID)
                },
                send: { [weak self] response in
                    self?.send(response: response, on: connection)
                }
            )
        }
    }

    private func processMessage(_ data: Data, ownerID: String) async -> ActionAgentResponse {
        let decoder = JSONDecoder()

        let request: ActionAgentRequest
        do {
            request = try decoder.decode(ActionAgentRequest.self, from: data)
        } catch {
            return ActionAgentResponse(id: "invalid", ok: false, error: "Invalid request: \(error.localizedDescription)")
        }

        guard let method = ActionAgentMethod(rawValue: request.method) else {
            return ActionAgentResponse(id: request.id, ok: false, error: "Unsupported method \(request.method)")
        }

        do {
            let result = try await handle(request: request, method: method, ownerID: ownerID)
            return ActionAgentResponse(id: request.id, ok: true, result: result)
        } catch {
            return ActionAgentResponse(id: request.id, ok: false, error: error.localizedDescription)
        }
    }

    private func handle(
        request: ActionAgentRequest,
        method: ActionAgentMethod,
        ownerID: String
    ) async throws -> [String: String] {
        switch method {
        case .ping:
            return [
                "message": "pong",
                "service": "ActionAgent",
                "protocolVersion": Self.protocolVersion,
            ]
        case .status:
            return [
                "service": "ActionAgent",
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "startedAt": ISO8601DateFormatter().string(from: runtimeState.startedAt),
                "methods": ActionAgentMethod.allCases.map(\.rawValue).joined(separator: ","),
                "protocolVersion": Self.protocolVersion,
                "capabilitiesJson": ActionBuildProvenance.current.json,
                "capabilityDiscovery": "Action MCP action.capabilities or lats action capabilities; private layers are orchestration, not raw agent RPCs",
                "authentication": "capability-token",
                "authTokenFile": authentication.tokenFile.path,
            ]
        case .permissionsSnapshot:
            return [
                "accessibility": actionAgentAccessibilityStatus().rawValue,
                "screenRecording": actionAgentScreenRecordingStatus().rawValue,
                "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
                "bundlePath": Bundle.main.bundlePath,
            ]
        case .permissionsRequest:
            return [
                "accessibility": actionAgentAccessibilityStatus(prompt: true).rawValue,
                "screenRecording": await actionRequestScreenRecordingAccess()
                    ? ActionAgentRuntimePermissionState.granted.rawValue
                    : ActionAgentRuntimePermissionState.denied.rawValue,
                "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
                "bundlePath": Bundle.main.bundlePath,
            ]
        case .accessibilityRequest:
            return [
                "accessibility": actionAgentAccessibilityStatus(prompt: true).rawValue,
                "screenRecording": actionAgentScreenRecordingStatus().rawValue,
                "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
                "bundlePath": Bundle.main.bundlePath,
            ]
        case .openAccessibilitySettings:
            actionAgentOpenSettingsPane(anchor: "Privacy_Accessibility")
            return ["status": "opened"]
        case .openScreenRecordingSettings:
            actionAgentOpenSettingsPane(anchor: "Privacy_ScreenCapture")
            return ["status": "opened"]
        case .launchApp:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 18, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            try await MainActor.run {
                try ActionNativeAutomation.launchApplication(bundleId: bundleId)
            }
            return ["bundleId": bundleId, "status": "launched"]
        case .activateApp:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }

            try ActionNativeAutomation.activateApplication(bundleId: bundleId)
            return ["bundleId": bundleId, "status": "activated"]
        case .typeText:
            guard let text = request.params["text"], !text.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 19, userInfo: [NSLocalizedDescriptionKey: "Missing text"])
            }
            try ActionNativeAutomation.typeText(text)
            return ["status": "typed", "detail": text]
        case .drag:
            guard
                let fromX = request.params["fromX"].flatMap(Double.init),
                let fromY = request.params["fromY"].flatMap(Double.init),
                let toX = request.params["toX"].flatMap(Double.init),
                let toY = request.params["toY"].flatMap(Double.init)
            else {
                throw NSError(domain: "ActionAgent", code: 21, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid drag parameters"])
            }
            let durationMs = Int(request.params["durationMs"].flatMap(Double.init) ?? 300)
            if let filePath = request.params["filePath"], !filePath.isEmpty {
                try ActionNativeAutomation.dragFile(path: filePath, from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY), durationMs: durationMs)
            } else {
                try ActionNativeAutomation.drag(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY), durationMs: durationMs)
            }
            return ["status": "dragged", "detail": "\(Int(fromX)),\(Int(fromY))->\(Int(toX)),\(Int(toY))"]
        case .pressAccessibilityElement:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 22, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            guard let label = request.params["label"], !label.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 23, userInfo: [NSLocalizedDescriptionKey: "Missing label"])
            }
            let match = try ActionNativeAutomation.pressAccessibilityElement(
                bundleId: bundleId,
                label: label,
                role: request.params["role"]
            )
            return [
                "status": "pressed",
                "bundleId": bundleId,
                "label": label,
                "role": match.role,
            ]
        case .setAccessibilityValue:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 24, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            guard let label = request.params["label"], !label.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 25, userInfo: [NSLocalizedDescriptionKey: "Missing label"])
            }
            guard let value = request.params["value"] else {
                throw NSError(domain: "ActionAgent", code: 26, userInfo: [NSLocalizedDescriptionKey: "Missing value"])
            }
            let match = try ActionNativeAutomation.setAccessibilityValue(
                bundleId: bundleId,
                label: label,
                role: request.params["role"],
                value: value
            )
            return [
                "status": "value-set",
                "bundleId": bundleId,
                "label": label,
                "role": match.role,
            ]
        case .setWindowFrame:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            guard
                let x = request.params["x"].flatMap(Double.init),
                let y = request.params["y"].flatMap(Double.init),
                let width = request.params["width"].flatMap(Double.init),
                let height = request.params["height"].flatMap(Double.init)
            else {
                throw NSError(domain: "ActionAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid window frame parameters"])
            }

            try ActionNativeAutomation.setWindowFrame(bundleId: bundleId, rect: CGRect(x: x, y: y, width: width, height: height))
            return ["bundleId": bundleId, "status": "window-framed"]
        case .getWindowFrame:
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            let rect = try ActionNativeAutomation.getWindowFrame(bundleId: bundleId)
            return [
                "bundleId": bundleId,
                "x": String(describing: rect.origin.x),
                "y": String(describing: rect.origin.y),
                "width": String(describing: rect.size.width),
                "height": String(describing: rect.size.height),
                "status": "window-frame",
            ]
        case .calculatorButtons:
            let buttons = try ActionNativeAutomation.calculatorButtons()
            let data = try JSONEncoder().encode(buttons)
            let text = String(decoding: data, as: UTF8.self)
            return ["status": "calculator-buttons", "buttons": text]
        case .clickCalculatorButton:
            guard let label = request.params["label"], !label.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing label"])
            }
            try ActionNativeAutomation.clickCalculatorButton(label: label)
            return ["status": "clicked", "detail": label]
        case .calculatorDisplayValue:
            let value = try ActionNativeAutomation.calculatorDisplayValue()
            return ["status": "calculator-display", "value": value]
        case .driveBegin:
            if request.params["mode"] == "attention" {
                try authenticatePrivileged(request)
            }
            let result = try await driveStore.begin(
                ownerID: ownerID,
                agent: request.params["agent"] ?? "",
                task: request.params["task"] ?? "",
                mode: request.params["mode"],
                sessionID: request.params["sessionId"],
                implicit: request.params["implicit"] == "true",
                showSupervisionLabel: request.params["showSupervisionLabel"] != "false",
                pointerControl: request.params["pointerControl"] == "true",
                attentionApproval: request.params["attentionApproval"],
                capability: request.params["capability"],
                resource: request.params["resource"],
                workflowRunID: request.params["workflowRunId"],
                workspaceID: request.params["workspaceId"],
                client: request.params["client"],
                clientProcess: await peers.describe(ownerID: ownerID)
            )
            var response = [
                "status": result.status,
                "lease": try actionAgentJSONString(result.lease),
            ]
            if let reason = result.reason {
                response["reason"] = reason
            }
            return response
        case .driveTouch:
            let lease = try await driveStore.touch(
                ownerID: ownerID,
                leaseID: request.params["leaseId"],
                axTier: request.params["axTier"],
                actionKind: request.params["actionKind"]
            )
            guard let lease else {
                return ["status": "idle"]
            }
            return [
                "status": "driving",
                "lease": try actionAgentJSONString(lease),
            ]
        case .driveRelease:
            guard let leaseID = request.params["leaseId"], !leaseID.isEmpty else {
                throw ActionDriveLeaseError.invalidInput("drive.release requires leaseId")
            }
            let lease = try await driveStore.release(
                ownerID: ownerID,
                leaseID: leaseID,
                outcome: request.params["outcome"],
                summary: request.params["summary"]
            )
            return [
                "status": lease.status,
                "lease": try actionAgentJSONString(lease),
            ]
        case .driveStatus:
            let snapshot = try await driveStore.status()
            return ["snapshot": try actionAgentJSONString(snapshot)]
        case .sessionsPrune:
            let result = await driveStore.pruneSessions()
            return ["result": try actionAgentJSONString(result)]
        case .sessionsClear:
            let result = await driveStore.clearSessions()
            return ["result": try actionAgentJSONString(result)]
        case .workspaceDragFile:
            try authenticatePrivileged(request)
            let semanticRequest = try ActionWorkspaceDragFileRequest(params: request.params)
            let result = try await workspaceDragFileOperation.execute(
                request: semanticRequest,
                ownerID: ownerID
            )
            return [
                "status": "dragged",
                "operationId": result.operationID,
                "sourceX": String(describing: result.source.x),
                "sourceY": String(describing: result.source.y),
                "destinationX": String(describing: result.destination.x),
                "destinationY": String(describing: result.destination.y),
            ]
        case .workspaceCancelOperation:
            try authenticatePrivileged(request)
            guard let leaseID = request.params["leaseId"], !leaseID.isEmpty,
                  let operationID = request.params["operationId"], !operationID.isEmpty else {
                throw ActionDriveLeaseError.invalidInput(
                    "workspace.cancelOperation requires leaseId and operationId"
                )
            }
            let lease = try await driveStore.cancelWorkspaceOperation(
                ownerID: ownerID,
                leaseID: leaseID,
                operationID: operationID
            )
            return [
                "status": "cancelling",
                "leaseId": lease.leaseId,
                "operationId": operationID,
            ]
        case .recordAppWindow:
            guard #available(macOS 15.0, *) else {
                throw NSError(domain: "ActionAgent", code: 7, userInfo: [NSLocalizedDescriptionKey: "Window recording requires macOS 15.0 or newer."])
            }
            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId"])
            }
            guard let outputPath = request.params["output"], !outputPath.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
            }

            return try await ActionRecordingProbeLauncher.launchAppWindow(
                bundleId: bundleId,
                outputPath: outputPath,
                stopSignalPath: request.params["stopFile"],
                finishedSignalPath: request.params["finishedFile"],
                debugLogPath: request.params["debugLog"]
            )
        case .recordRegion:
            guard #available(macOS 15.0, *) else {
                throw NSError(domain: "ActionAgent", code: 10, userInfo: [NSLocalizedDescriptionKey: "Region recording requires macOS 15.0 or newer."])
            }
            guard let outputPath = request.params["output"], !outputPath.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
            }
            guard
                let x = request.params["x"].flatMap(Double.init),
                let y = request.params["y"].flatMap(Double.init),
                let width = request.params["width"].flatMap(Double.init),
                let height = request.params["height"].flatMap(Double.init)
            else {
                throw NSError(domain: "ActionAgent", code: 12, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid region parameters"])
            }

            return try await ActionRecordingProbeLauncher.launchRegion(
                rect: CGRect(x: x, y: y, width: width, height: height),
                outputPath: outputPath,
                stopSignalPath: request.params["stopFile"],
                finishedSignalPath: request.params["finishedFile"],
                debugLogPath: request.params["debugLog"],
                fps: request.params["fps"].flatMap(Double.init) ?? 15,
                scale: request.params["scale"].flatMap(Double.init) ?? 1,
                includeSupervisionOverlay: request.params["includeSupervisionOverlay"] != "false"
            )
        case .screenshotAppWindow:
            guard let outputPath = request.params["output"], !outputPath.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 14, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
            }

            // A pid names one process exactly; bundleId targeting stays for callers that
            // have no pid, but it cannot distinguish two instances of the same bundle.
            if let pidParam = request.params["pid"], let pid = Int32(pidParam) {
                try await actionCaptureAppWindowScreenshot(pid: pid, outputPath: outputPath)
                return ["pid": pidParam, "outputPath": outputPath, "status": "screenshot"]
            }

            guard let bundleId = request.params["bundleId"], !bundleId.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 13, userInfo: [NSLocalizedDescriptionKey: "Missing bundleId or pid"])
            }

            try await actionCaptureAppWindowScreenshot(bundleId: bundleId, outputPath: outputPath)
            return ["bundleId": bundleId, "outputPath": outputPath, "status": "screenshot"]
        case .screenshotRegion:
            guard let outputPath = request.params["output"], !outputPath.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 15, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
            }
            guard
                let x = request.params["x"].flatMap(Double.init),
                let y = request.params["y"].flatMap(Double.init),
                let width = request.params["width"].flatMap(Double.init),
                let height = request.params["height"].flatMap(Double.init)
            else {
                throw NSError(domain: "ActionAgent", code: 16, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid region parameters"])
            }

            try await actionCaptureRegionScreenshot(rect: CGRect(x: x, y: y, width: width, height: height), outputPath: outputPath)
            return ["outputPath": outputPath, "status": "screenshot"]
        case .screenshotScreen:
            guard let outputPath = request.params["output"], !outputPath.isEmpty else {
                throw NSError(domain: "ActionAgent", code: 17, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
            }

            try actionCaptureScreenScreenshot(outputPath: outputPath)
            return ["outputPath": outputPath, "detail": "main-display", "status": "screenshot"]
        }
    }

    private func authenticatePrivileged(_ request: ActionAgentRequest) throws {
        try authentication.authorize(params: request.params, protocolVersion: Self.protocolVersion)
    }

    private func send(response: ActionAgentResponse, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let data = try encoder.encode(response)
            let context = NWConnection.ContentContext(identifier: "ActionAgentResponse", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                _ = error
            })
        } catch {
            FileHandle.standardError.write(Data("ActionAgent encode failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func connectionDidClose(identifier: ObjectIdentifier, ownerID: String) {
        guard activeConnections.removeValue(forKey: identifier) != nil else {
            return
        }
        lastConnectionActivityAt = Date()
        Task { [peers] in await peers.forget(ownerID: ownerID) }
        Task {
            await driveStore.disconnectOwner(
                by: ownerID,
                summary: "Driving client disconnected"
            )
        }
    }

    private func startParentWatchIfNeeded() {
        guard let parentProcessID else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler {
            if kill(parentProcessID, 0) != 0 {
                exit(0)
            }
        }
        timer.resume()
        parentWatchTimer = timer
    }

    private func startDriveSweep() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [driveStore] in
            Task {
                try? await driveStore.sweep()
            }
        }
        timer.resume()
        driveSweepTimer = timer
    }

    /// Holds the run ledger to its age and size caps: once at launch, then hourly.
    private func startSessionPrune() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(60 * 60))
        timer.setEventHandler { [driveStore] in
            Task {
                _ = await driveStore.pruneSessions()
            }
        }
        timer.resume()
        sessionPruneTimer = timer
    }

    private func startIdleExitIfNeeded() {
        guard let idleExitSeconds, idleExitSeconds > 0 else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler {
            guard self.activeConnections.isEmpty,
                  Date().timeIntervalSince(self.lastConnectionActivityAt) >= idleExitSeconds else {
                return
            }
            exit(0)
        }
        timer.resume()
        idleExitTimer = timer
    }
}

enum ActionAgentAuthenticationError: LocalizedError {
    case protocolVersionRequired(String)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .protocolVersionRequired(let version):
            return "Privileged Action methods require protocolVersion \(version)"
        case .invalidToken:
            return "Privileged Action methods require the current user-only capability token"
        }
    }
}

struct ActionAgentAuthentication: Sendable {
    let token: String
    let tokenFile: URL

    static func create(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Action/runtime/agent", isDirectory: true)
    ) throws -> ActionAgentAuthentication {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let tokenFile = rootURL.appendingPathComponent("capability-token")
        try Data((token + "\n").utf8).write(to: tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return ActionAgentAuthentication(token: token, tokenFile: tokenFile)
    }

    func matches(_ candidate: String) -> Bool {
        let lhs = Array(token.utf8)
        let rhs = Array(candidate.utf8)
        var difference = lhs.count ^ rhs.count
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }

    func authorize(params: [String: String], protocolVersion: String) throws {
        guard params["protocolVersion"] == protocolVersion else {
            throw ActionAgentAuthenticationError.protocolVersionRequired(protocolVersion)
        }
        guard let candidate = params["authToken"], matches(candidate) else {
            throw ActionAgentAuthenticationError.invalidToken
        }
    }
}

private func actionAgentJSONString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func actionAgentAccessibilityStatus(prompt: Bool = false) -> ActionAgentRuntimePermissionState {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
}

private func actionAgentScreenRecordingStatus() -> ActionAgentRuntimePermissionState {
    CGPreflightScreenCaptureAccess() ? .granted : .denied
}

private func actionAgentOpenSettingsPane(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }

    NSWorkspace.shared.open(url)
}

public enum ActionAgentRuntime {
    @MainActor
    public static func run(arguments: [String]) -> Never {
        let port = parsePort(arguments: arguments) ?? ActionAgentDefaults.port
        let parentProcessID = parseParentProcessID(arguments: arguments)
        let idleExitSeconds = parseIdleExitSeconds(arguments: arguments)

        do {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)

            let server = try ActionAgentRuntimeServer(
                port: port,
                parentProcessID: parentProcessID,
                idleExitSeconds: idleExitSeconds
            )
            return server.run()
        } catch {
            FileHandle.standardError.write(Data("ActionAgent failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func parsePort(arguments: [String]) -> UInt16? {
        guard let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return UInt16(arguments[index + 1])
    }

    private static func parseParentProcessID(arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: "--parent-pid"), arguments.indices.contains(index + 1) else {
            return nil
        }
        guard let raw = Int32(arguments[index + 1]) else {
            return nil
        }
        return pid_t(raw)
    }

    private static func parseIdleExitSeconds(arguments: [String]) -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--idle-exit-seconds"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return TimeInterval(arguments[index + 1])
    }
}
