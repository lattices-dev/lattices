import Foundation

enum SpeechRpc {
    /// `preferences` defaults to `SpeechVoicePreferences.shared`, the store the
    /// Settings picker and `speech.enqueue` read.
    static func register(on api: SpeechApi, queue: SpeechQueue = .shared, preferences: SpeechVoicePreferences? = nil) {
        api.model(ApiModel(name: "SpeechJob", fields: [
            Field(name: "id", type: "string", required: true, description: "Job identifier"),
            Field(name: "state", type: "string", required: true, description: "queued, generating, playing, paused, completed, cancelled, or failed"),
            Field(name: "text", type: "string", required: true, description: "Spoken text"),
            Field(name: "provider", type: "string", required: true, description: "TTS provider id"),
            Field(name: "model", type: "string", required: false, description: "Provider model override"),
            Field(name: "voice", type: "string", required: false, description: "Voice id"),
            Field(name: "source", type: "object", required: false, description: "Source metadata: kind, label, taskId, sessionId"),
            Field(name: "error", type: "string", required: false, description: "Failure message when state is failed"),
            Field(name: "progress", type: "double", required: false, description: "Playback progress 0-1"),
            Field(name: "currentTime", type: "double", required: true, description: "Playback position in seconds"),
            Field(name: "duration", type: "double", required: true, description: "Audio duration in seconds"),
        ]))

        api.model(ApiModel(name: "SpeechStatus", fields: [
            Field(name: "current", type: "SpeechJob?", required: false, description: "Active job"),
            Field(name: "queued", type: "[SpeechJob]", required: true, description: "Jobs waiting to play"),
            Field(name: "failure", type: "SpeechJob?", required: false, description: "Failure retained until dismissed"),
            Field(name: "recent", type: "[SpeechJob]", required: true, description: "Recently finished jobs"),
            Field(name: "preferredVoices", type: "[SpeechPreferredVoice]", required: true, description: "Voice chosen per provider (Settings or speech.preferredVoice.set); used when a request names no voice. Providers with no choice are omitted"),
        ]))

        api.model(ApiModel(name: "SpeechPreferredVoice", fields: [
            Field(name: "provider", type: "string", required: true, description: "Provider id"),
            Field(name: "voice", type: "string", required: false, description: "Voice id; null when the choice was cleared"),
            Field(name: "label", type: "string", required: false, description: "Display name (speech.preferredVoice.set only)"),
            Field(name: "available", type: "bool", required: false, description: "Whether credentials or on-device voice are present (speech.preferredVoice.set only)"),
        ]))

        api.model(ApiModel(name: "SpeechVoice", fields: [
            Field(name: "id", type: "string", required: true, description: "Voice identifier"),
            Field(name: "label", type: "string", required: true, description: "Display name"),
            Field(name: "provider", type: "string", required: true, description: "Provider id"),
            Field(name: "available", type: "bool", required: true, description: "Whether credentials or on-device voice are present"),
            Field(name: "default", type: "bool", required: true, description: "Whether this is the provider default"),
        ]))

        api.register(Endpoint(
            method: "speech.enqueue",
            description: "Enqueue text for native speech playback. Returns the job id and actual state; never completed on enqueue.",
            access: .mutate,
            params: [
                Param(name: "text", type: "string", required: true, description: "Text to speak"),
                Param(name: "provider", type: "string", required: false, description: "system, openai, elevenlabs, or phonon (default system). phonon runs on this Mac; the first request downloads the model"),
                Param(name: "model", type: "string", required: false, description: "Provider model override"),
                Param(name: "voice", type: "string", required: false, description: "Voice identifier"),
                Param(name: "rate", type: "double", required: false, description: "Speaking rate 0.25-4.0 (default 1.0)"),
                Param(name: "instructions", type: "string", required: false, description: "Delivery instructions for providers that support them"),
                Param(name: "voiceSettings", type: "object", required: false, description: "Optional stability/similarity/style/useSpeakerBoost"),
                Param(name: "cachePolicy", type: "string", required: false, description: "reuse (default) or fresh"),
                Param(name: "source", type: "object", required: false, description: "kind, label, taskId, sessionId — no URLs"),
            ],
            returns: .object(model: "SpeechJob"),
            handler: { params in
                try runOnMain {
                    try enqueue(params, queue: queue)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.status",
            description: "Return the current speech job, queued jobs, and recent terminal jobs",
            access: .read,
            params: [],
            returns: .object(model: "SpeechStatus"),
            handler: { _ in
                try runOnMain { statusJSON(queue.status(), preferences: preferences ?? .shared) }
            }
        ))

        api.register(Endpoint(
            method: "speech.pause",
            description: "Pause the active playing job",
            access: .mutate,
            params: [
                Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied"),
            ],
            returns: .object(model: "SpeechStatus"),
            handler: { params in
                try runOnMain {
                    statusJSON(try queue.pause(jobId: params?["id"]?.stringValue), preferences: preferences ?? .shared)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.resume",
            description: "Resume the active paused job",
            access: .mutate,
            params: [
                Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied"),
            ],
            returns: .object(model: "SpeechStatus"),
            handler: { params in
                try runOnMain {
                    statusJSON(try queue.resume(jobId: params?["id"]?.stringValue), preferences: preferences ?? .shared)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.seek",
            description: "Seek the active playing or paused job",
            access: .mutate,
            params: [
                Param(name: "seconds", type: "double", required: true, description: "Playback position in seconds"),
                Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied"),
            ],
            returns: .object(model: "SpeechStatus"),
            handler: { params in
                try runOnMain {
                    guard let seconds = params?["seconds"]?.numericDouble else {
                        throw RouterError.missingParam("seconds")
                    }
                    return statusJSON(try queue.seek(seconds: seconds, jobId: params?["id"]?.stringValue), preferences: preferences ?? .shared)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.stop",
            description: "Stop the active job and cancel queued jobs",
            access: .mutate,
            params: [
                Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied"),
            ],
            returns: .object(model: "SpeechStatus"),
            handler: { params in
                try runOnMain {
                    statusJSON(try queue.stop(jobId: params?["id"]?.stringValue), preferences: preferences ?? .shared)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.next",
            description: "Skip the active job and play the next queued job",
            access: .mutate,
            params: [
                Param(name: "id", type: "string", required: false, description: "Job id; must match the active job when supplied"),
            ],
            returns: .object(model: "SpeechStatus"),
            handler: { params in
                try runOnMain {
                    statusJSON(try queue.next(jobId: params?["id"]?.stringValue), preferences: preferences ?? .shared)
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.voices",
            description: "List on-device and cloud speech voices with availability",
            access: .read,
            params: [],
            returns: .array(model: "SpeechVoice"),
            handler: { _ in
                try runOnMain {
                    .array(queue.voices().map { $0.json() })
                }
            }
        ))

        api.register(Endpoint(
            method: "speech.preferredVoice.set",
            description: "Choose the voice a provider uses when a request names none. Same setting as the Settings picker. An empty voice clears the choice",
            access: .mutate,
            params: [
                Param(name: "voice", type: "string", required: true, description: "Voice id from speech.voices; empty clears the choice"),
                Param(name: "provider", type: "string", required: false, description: "system, openai, elevenlabs, or phonon (default system)"),
            ],
            returns: .object(model: "SpeechPreferredVoice"),
            handler: { params in
                try runOnMain {
                    try setPreferredVoice(params, queue: queue, preferences: preferences ?? .shared)
                }
            }
        ))
    }

    /// Validates `voice` against the provider's catalog (`queue.voices()`) and
    /// persists it through `SpeechVoicePreferences`.
    @MainActor static func setPreferredVoice(_ params: JSON?, queue: SpeechQueue, preferences: SpeechVoicePreferences) throws -> JSON {
        guard let rawVoice = params?["voice"] else {
            throw RouterError.missingParam("voice")
        }
        guard let voiceValue = rawVoice.stringValue else {
            throw RouterError.custom("voice must be a string")
        }
        if let value = params?["provider"], value.stringValue == nil {
            throw RouterError.custom("provider must be a string")
        }
        let provider = try SpeechProviders.normalize(params?["provider"]?.stringValue)
        let voice = voiceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else {
            preferences.setPreferredVoice(nil, for: provider)
            return .object(["provider": .string(provider), "voice": .null])
        }

        let catalog = queue.voices()
        guard let match = catalog.first(where: { $0.provider == provider && $0.id == voice }) else {
            if !catalog.contains(where: { $0.provider == provider }) {
                throw SpeechQueueError.noVoices(provider: provider)
            }
            let listedUnder = SpeechProviders.all.first { other in
                other != provider && catalog.contains(where: { $0.provider == other && $0.id == voice })
            }
            throw SpeechQueueError.unknownVoice(voice, provider: provider, listedUnder: listedUnder)
        }
        preferences.setPreferredVoice(match.id, for: provider)
        return .object([
            "provider": .string(provider),
            "voice": .string(match.id),
            "label": .string(match.label),
            "available": .bool(match.available),
        ])
    }

    /// `SpeechStatus`: the queue snapshot plus the stored voice choices.
    @MainActor static func statusJSON(_ snapshot: SpeechSnapshot, preferences: SpeechVoicePreferences) -> JSON {
        guard case .object(var fields) = snapshot.json() else { return snapshot.json() }
        fields["preferredVoices"] = .array(preferences.storedVoices().map { entry in
            .object(["provider": .string(entry.provider), "voice": .string(entry.voice)])
        })
        return .object(fields)
    }

    @MainActor static func enqueue(_ params: JSON?, queue: SpeechQueue) throws -> JSON {
        guard let params else {
            throw RouterError.missingParam("text")
        }
        let request = try parseEnqueue(params)
        let job = try queue.enqueue(request)
        return .object([
            "id": .string(job.id),
            "state": .string(job.state.rawValue),
            "job": job.json(),
            "queue": queue.status().json(),
        ])
    }

    static func parseEnqueue(_ params: JSON) throws -> SpeechEnqueueRequest {
        try SpeechEnqueueValidator.rejectRemoteAudio(in: params)
        guard let rawText = params["text"]?.stringValue else {
            throw RouterError.missingParam("text")
        }
        let text = rawText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechQueueError.emptyText
        }
        for key in ["provider", "model", "voice", "instructions", "cachePolicy"] {
            if let value = params[key], value.stringValue == nil {
                throw RouterError.custom("\(key) must be a string")
            }
        }
        if let value = params["rate"] {
            guard let rate = value.numericDouble, rate.isFinite else {
                throw SpeechQueueError.invalidRate
            }
        }
        let provider = try SpeechProviders.normalize(params["provider"]?.stringValue)
        let cachePolicyRaw = params["cachePolicy"]?.stringValue ?? SpeechCachePolicy.reuse.rawValue
        guard let cachePolicy = SpeechCachePolicy(rawValue: cachePolicyRaw.lowercased()) else {
            throw SpeechQueueError.invalidCachePolicy(cachePolicyRaw)
        }

        var source: SpeechSourceMetadata?
        if let sourceJSON = params["source"] {
            guard case .object(let object) = sourceJSON else {
                throw RouterError.custom("source must be an object")
            }
            let allowed: Set<String> = ["kind", "label", "taskId", "sessionId"]
            guard object.allSatisfy({ allowed.contains($0.key) && $0.value.stringValue != nil }) else {
                throw RouterError.custom("source accepts only string kind, label, taskId, and sessionId fields")
            }
            source = SpeechSourceMetadata(
                kind: object["kind"]?.stringValue,
                label: object["label"]?.stringValue,
                taskId: object["taskId"]?.stringValue,
                sessionId: object["sessionId"]?.stringValue
            )
        }

        var voiceSettings: SpeechVoiceSettings?
        if let settingsJSON = params["voiceSettings"] {
            guard case .object(let object) = settingsJSON else {
                throw RouterError.custom("voiceSettings must be an object")
            }
            let allowed: Set<String> = ["stability", "similarityBoost", "style", "useSpeakerBoost"]
            guard object.keys.allSatisfy({ allowed.contains($0) }) else {
                throw RouterError.custom("voiceSettings contains an unknown field")
            }
            for key in ["stability", "similarityBoost", "style"] {
                if let value = object[key] {
                    guard let number = value.numericDouble, number.isFinite, (0...1).contains(number) else {
                        throw RouterError.custom("\(key) must be a number between 0 and 1")
                    }
                }
            }
            if let value = object["useSpeakerBoost"], value.boolValue == nil {
                throw RouterError.custom("useSpeakerBoost must be a boolean")
            }
            voiceSettings = SpeechVoiceSettings(
                stability: object["stability"]?.numericDouble,
                similarityBoost: object["similarityBoost"]?.numericDouble,
                style: object["style"]?.numericDouble,
                useSpeakerBoost: object["useSpeakerBoost"]?.boolValue
            )
        }

        let request = SpeechEnqueueRequest(
            text: text,
            provider: provider,
            model: params["model"]?.stringValue,
            voice: params["voice"]?.stringValue,
            rate: params["rate"]?.numericDouble ?? 1.0,
            instructions: params["instructions"]?.stringValue,
            voiceSettings: voiceSettings,
            cachePolicy: cachePolicy,
            source: source
        )
        try SpeechEnqueueValidator.validate(request, limits: .default, queuedCount: 0)
        return request
    }

    static func runOnMain<T>(_ body: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try body() }
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { try body() }
        }
    }
}
