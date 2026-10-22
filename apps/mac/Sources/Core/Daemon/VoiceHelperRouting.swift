import Foundation

/// Routing for the `voice` domain's output verbs (LAT-012).
///
/// The daemon serves listening (`voice.listen`, `voice.stopListening`,
/// `voice.simulate`, `voice.reconnect`) itself. Speaking is served by the Voice
/// helper (bundle ID `dev.lattices.Speech`). The helper's own RPC keeps its
/// `speech.*` names, so the daemon renames each `voice.*` output verb before it
/// forwards the request. Direct `speech.*` calls are still forwarded unchanged.
enum VoiceHelperRouting {
    static let helperName = "Voice"
    static let installHint = "Lattices › Apps › Install Voice"

    static let notInstalledError =
        "helper_not_installed: The Voice helper is not installed. \(installHint)"
    static let unreachableError = SpeechCompanionConnection.unreachableError
    static let unauthorizedError =
        "helper_unauthorized: Voice is running, but this client did not send the Voice capability token."

    /// Error for a `voice.stop` made while the daemon is listening and Voice is
    /// not speaking. Kept for one release after `voice.stop` changed meaning.
    static let stopListeningHintError =
        "voice_stop_changed: voice.stop now stops speech output, and nothing is speaking. " +
        "Voice capture is still listening; call voice.stopListening (lattices voice stopListening) to stop it."

    /// Daemon verb -> helper RPC method.
    static let methodMap: [String: String] = [
        "voice.say": "speech.enqueue",
        "voice.stop": "speech.stop",
        "voice.pause": "speech.pause",
        "voice.resume": "speech.resume",
        "voice.seek": "speech.seek",
        "voice.skip": "speech.next",
        "voice.list": "speech.voices",
        "voice.select": "speech.preferredVoice.set",
        "voice.lease": "speech.playback.reserve",
    ]

    /// Handled by the daemon: closes this client's helper connection, which is
    /// how the helper ends a playback lease. There is no helper release method.
    static let releaseMethod = "voice.release"

    /// Internal request ids the daemon sends to the helper on its own behalf.
    static let internalIdPrefix = "lattices.internal."

    /// The helper method for a daemon request, or nil when the daemon serves it.
    static func helperMethod(for method: String) -> String? {
        if let mapped = methodMap[method] { return mapped }
        if method.hasPrefix("speech.") { return method }
        return nil
    }

    static func isHelperVerb(_ method: String) -> Bool {
        method == releaseMethod || helperMethod(for: method) != nil
    }

    static func renamed(_ request: DaemonRequest, to method: String) -> DaemonRequest {
        DaemonRequest(id: request.id, method: method, params: request.params)
    }

    /// Helper events keep their `speech.*` names for existing clients and are
    /// also sent under the `voice.*` name (`speech.changed` -> `voice.changed`).
    static func clientEvents(for event: DaemonEvent) -> [DaemonEvent] {
        guard event.event.hasPrefix("speech.") else { return [event] }
        let suffix = event.event.dropFirst("speech.".count)
        return [event, DaemonEvent(event: "voice.\(suffix)", data: event.data)]
    }

    /// True when a `speech.status` result shows a job generating, playing,
    /// paused, or waiting in the queue.
    static func isSpeaking(_ status: JSON?) -> Bool {
        guard let status else { return false }
        if let state = status["current"]?["state"]?.stringValue,
           ["queued", "generating", "playing", "paused"].contains(state) {
            return true
        }
        if let queued = status["queued"]?.arrayValue, !queued.isEmpty { return true }
        return false
    }

    /// Whether the Voice helper app is present on disk.
    static func isInstalled() -> Bool {
        let product = CompanionAppCatalog.product(id: .speech)
        return CompanionAppDiscovery.system.installState(for: product) != .missing
    }

    /// Error for a client without the helper capability. Voice writes the
    /// capability file on launch and removes it on quit, so a missing file
    /// means Voice is not running, not that the client lacks permission.
    static func unauthorizedReason(capabilityPresent: Bool, installed: Bool) -> String {
        if capabilityPresent { return unauthorizedError }
        return installed ? unreachableError : notInstalledError
    }

    /// Machine code at the front of a routing error ("helper_not_installed: ...").
    static func errorCode(_ message: String) -> String {
        guard let colon = message.firstIndex(of: ":") else { return message }
        let code = message[..<colon]
        return code.allSatisfy({ $0.isLowercase || $0 == "_" }) ? String(code) : message
    }

    /// Helper section of `voice.status`.
    static func helperStatus(installed: Bool, authorized: Bool, status: JSON?, error: String?) -> JSON {
        var object: [String: JSON] = [
            "name": .string(helperName),
            "installed": .bool(installed),
            "authorized": .bool(authorized),
            "reachable": .bool(status != nil),
            "speaking": .bool(isSpeaking(status)),
            "status": status ?? .null,
            "error": error.map { .string(errorCode($0)) } ?? .null,
            "message": error.map { .string($0) } ?? .null,
        ]
        if !installed { object["hint"] = .string(installHint) }
        return .object(object)
    }

    // MARK: - Schema

    /// Advertise the helper-served verbs in `api.schema`. Requests for these
    /// methods are routed by `DaemonServer` before `LatticesApi.handle` runs, so
    /// the handlers here only answer in-process callers.
    static func registerSchema(on api: LatticesApi) {
        func forwarded(_ method: String) -> (JSON?) throws -> JSON {
            { _ in
                throw RouterError.custom("\(method) is served by the Voice helper through the authenticated private daemon socket")
            }
        }
        let jobId = Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied")

        api.register(Endpoint(
            method: "voice.say",
            description: "Speak text through the Voice helper. Returns the job id and its state; the job is queued, not finished. Fails with helper_not_installed when Voice is missing.",
            access: .mutate,
            params: [
                Param(name: "text", type: "string", required: true, description: "Text to speak"),
                Param(name: "provider", type: "string", required: false, description: "system, openai, elevenlabs, kokoro, or phonon (default system)"),
                Param(name: "model", type: "string", required: false, description: "Provider model override"),
                Param(name: "voice", type: "string", required: false, description: "Voice identifier; defaults to the voice chosen with voice.select"),
                Param(name: "rate", type: "double", required: false, description: "Speaking rate 0.25-4.0 (default 1.0)"),
                Param(name: "instructions", type: "string", required: false, description: "Delivery instructions for providers that support them"),
                Param(name: "voiceSettings", type: "object", required: false, description: "Optional stability/similarityBoost/style/useSpeakerBoost"),
                Param(name: "cachePolicy", type: "string", required: false, description: "reuse (default) or fresh"),
                Param(name: "source", type: "object", required: false, description: "kind, label, taskId, sessionId"),
            ],
            returns: .custom("{ id, state, job, queue }"),
            handler: forwarded("voice.say")
        ))
        api.register(Endpoint(
            method: "voice.stop",
            description: "Stop speaking: stop the active job and cancel queued jobs. To stop listening, use voice.stopListening.",
            access: .mutate,
            params: [jobId],
            returns: .custom("Voice queue status { current, queued, failure, recent }"),
            handler: forwarded("voice.stop")
        ))
        api.register(Endpoint(
            method: "voice.pause",
            description: "Pause the job that is speaking",
            access: .mutate,
            params: [jobId],
            returns: .custom("Voice queue status { current, queued, failure, recent }"),
            handler: forwarded("voice.pause")
        ))
        api.register(Endpoint(
            method: "voice.resume",
            description: "Resume the paused job",
            access: .mutate,
            params: [jobId],
            returns: .custom("Voice queue status { current, queued, failure, recent }"),
            handler: forwarded("voice.resume")
        ))
        api.register(Endpoint(
            method: "voice.skip",
            description: "Skip the active job and play the next queued job",
            access: .mutate,
            params: [jobId],
            returns: .custom("Voice queue status { current, queued, failure, recent }"),
            handler: forwarded("voice.skip")
        ))
        api.register(Endpoint(
            method: "voice.seek",
            description: "Seek the active playing or paused job",
            access: .mutate,
            params: [
                Param(name: "seconds", type: "double", required: true, description: "Playback position in seconds"),
                jobId,
            ],
            returns: .custom("Voice queue status { current, queued, failure, recent }"),
            handler: forwarded("voice.seek")
        ))
        api.register(Endpoint(
            method: "voice.list",
            description: "List on-device and cloud voices with availability",
            access: .read,
            params: [],
            returns: .custom("[{ id, label, provider, available, default }]"),
            handler: forwarded("voice.list")
        ))
        api.register(Endpoint(
            method: "voice.select",
            description: "Choose the default voice for a provider. voice.say uses it when no voice is given.",
            access: .mutate,
            params: [
                Param(name: "voice", type: "string", required: true, description: "Voice identifier from voice.list; empty clears the choice"),
                Param(name: "provider", type: "string", required: false, description: "Provider id (default system)"),
            ],
            returns: .custom("Selected voice"),
            handler: forwarded("voice.select")
        ))
        api.register(Endpoint(
            method: "voice.lease",
            description: "Hold the speaker so other agents do not talk over you. The lease ends on voice.release or when this connection closes.",
            access: .mutate,
            params: [],
            returns: .custom("true"),
            handler: forwarded("voice.lease")
        ))
        api.register(Endpoint(
            method: "voice.release",
            description: "Give back the speaker. Closes this client's connection to the Voice helper, which ends its lease. Queued speech keeps playing.",
            access: .mutate,
            params: [],
            returns: .custom("{ ok, released }"),
            handler: forwarded("voice.release")
        ))
    }
}
