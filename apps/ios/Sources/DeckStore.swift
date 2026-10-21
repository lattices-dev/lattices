import Combine
import DeckKit
import Foundation

/// How aggressively the store should pull snapshots from the Mac. Two
/// presets, mapped to interval values inside `DeckStore`:
/// - `.fast`    → ~1s (active engagement: Deck open, voice in flight)
/// - `.ambient` → ~5s (passive observation: Home idle)
enum DeckPollPriority {
    case fast
    case ambient
}

@MainActor
final class DeckStore: ObservableObject {
    let sessionID = UUID()

    @Published private(set) var discoveredBridges: [BridgeEndpoint] = []
    @Published private(set) var activeEndpoint: BridgeEndpoint?
    @Published private(set) var health: BridgeHealthResponse?
    @Published private(set) var manifest: DeckManifest?
    @Published private(set) var snapshot: DeckRuntimeSnapshot?
    @Published private(set) var lastActionResult: DeckActionResult?
    @Published private(set) var lastActionLabel: String?
    @Published private(set) var isPerformingAction = false
    @Published var selectedPageID = "voice"
    @Published var selectedCockpitPageID = "main"
    @Published var manualHost = ""
    @Published var manualPort = "9399"
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let client = DeckBridgeClient()
    private let discovery = BridgeDiscovery()
    private var pollingTask: Task<Void, Never>?
    private var trackpadEventInFlightGeneration: Int?
    private var queuedTrackpadEvents: [QueuedTrackpadEvent] = []
    private let maxQueuedTrackpadEvents = 8

    fileprivate struct QueuedTrackpadEvent {
        var event: DeckTrackpadEvent
        var dx: Double
        var dy: Double
        var connectionGeneration: Int

        var canCoalesce: Bool {
            switch event {
            case .move, .scroll, .drag:
                return true
            case .click, .rightClick, .mouseDown, .mouseUp:
                return false
            }
        }

        mutating func coalesce(_ other: QueuedTrackpadEvent) {
            dx += other.dx
            dy += other.dy
        }
    }

    /// UI hint for how aggressively to poll. Hosts flip this to `.fast` when
    /// the user is actively engaged (Deck open, voice panel open, recording)
    /// and back to `.ambient` when they're just looking at Home idle.
    /// The store will *also* go fast on its own if the snapshot reports voice
    /// activity or pending questions, so callers don't have to be exhaustive.
    private var uiPriority: DeckPollPriority = .ambient

    /// Set by a deliberate disconnect or by discovering that a Mac revoked us.
    /// Cleared the moment the user connects to something on purpose.
    private var autoConnectSuppressed = false

    /// Bumped by every `connect`. `loadConnection` walks six mutations with
    /// awaits between them, so without this two overlapping connects interleave
    /// and the *later-finishing* one wins rather than the later-requested one —
    /// which can leave one Mac's health signing another Mac's requests.
    private var connectionGeneration = 0

    /// Consecutive failed polls, for backoff. A host that is not answering
    /// should be asked less often, not more.
    private var consecutivePollFailures = 0

    var connectionLabel: String {
        // Prefer human-readable names (Bonjour service name / health-reported name)
        // over raw hosts/UUIDs which look like "F8B453FB-…" in the UI.
        if let endpointName = activeEndpoint?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpointName.isEmpty,
           !looksLikeUUID(endpointName) {
            return endpointName
        }
        if let healthName = health?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !healthName.isEmpty,
           !looksLikeUUID(healthName) {
            return healthName
        }
        if let endpointHost = activeEndpoint?.host.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpointHost.isEmpty {
            return endpointHost
                .replacingOccurrences(of: ".local", with: "")
                .replacingOccurrences(of: ".lan", with: "")
        }
        return "Mac"
    }

    private func looksLikeUUID(_ s: String) -> Bool {
        // Crude check: 32+ hex/dash chars, no spaces. Matches "F8B453FB-F2AD-4194-…"
        let hex = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        return s.count >= 16 && s.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    init(endpoint: BridgeEndpoint? = nil, discoversBridges: Bool = true) {
        if discoversBridges {
            discovery.onUpdate = { [weak self] bridges in
                Task { @MainActor [weak self] in
                    self?.handleDiscoveryUpdate(bridges)
                }
            }
            discovery.start()
        }

        if let endpoint {
            connect(to: endpoint)
        }
    }

    deinit {
        pollingTask?.cancel()
        discovery.stop()
    }

    func refreshDiscovery() {
        discovery.refresh()
    }

    func connect(to endpoint: BridgeEndpoint) {
        pollingTask?.cancel()
        pollingTask = nil
        // An explicit connection is the user changing their mind about a
        // previous explicit disconnect.
        autoConnectSuppressed = false
        connectionGeneration += 1
        resetTrackpadPipeline()
        consecutivePollFailures = 0
        let generation = connectionGeneration
        activeEndpoint = endpoint
        health = nil
        manifest = nil
        snapshot = nil
        manualHost = endpoint.host
        manualPort = String(endpoint.port)
        errorMessage = nil
        lastActionResult = nil
        lastActionLabel = nil
        isPerformingAction = false

        Task {
            await loadConnection(endpoint: endpoint, forceManifest: true, generation: generation)
        }
    }

    func connectManually() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "Enter a Mac host name or Bonjour address."
            return
        }

        guard let port = Int(manualPort), port > 0 else {
            errorMessage = "Enter a valid bridge port."
            return
        }

        connect(to: BridgeEndpoint(name: host, host: host, port: port, source: "Manual"))
    }

    /// Close the session.
    ///
    /// `suppressAutoReconnect` matters more than it looks: discovery reconnects
    /// to any trusted host the moment there is no active one, so without it a
    /// deliberate disconnect was undone by the next Bonjour update — the button
    /// appeared to do nothing at all.
    func disconnect(suppressAutoReconnect: Bool = true) {
        pollingTask?.cancel()
        pollingTask = nil
        connectionGeneration += 1
        resetTrackpadPipeline()
        activeEndpoint = nil
        health = nil
        manifest = nil
        snapshot = nil
        lastActionResult = nil
        lastActionLabel = nil
        isPerformingAction = false
        autoConnectSuppressed = suppressAutoReconnect
    }

    /// Stop trusting a Mac and let go of it.
    ///
    /// Trust is two separate records — one on each device — and the Mac can
    /// revoke its own at any time without telling anybody. This is the iPad's
    /// half, so that a host whose trust is gone leaves the roster and returns to
    /// being something you add, rather than sitting there failing forever.
    func forget(publicKey: String) {
        DeckBridgeSecurityStore.shared.forgetBridge(publicKey: publicKey)
        if health?.bridgePublicKey == publicKey {
            disconnect(suppressAutoReconnect: true)
        }
        objectWillChange.send()
    }

    func refreshSnapshot() {
        guard let endpoint = activeEndpoint else { return }
        Task {
            await refreshSnapshot(endpoint: endpoint)
        }
    }

    /// Tell the store the user is actively engaged (or no longer engaged)
    /// so it can speed up / slow down snapshot polling. Idempotent — call as
    /// often as needed from `.onAppear` / `.onChange` hooks. The store will
    /// independently go fast for in-snapshot signals (voice, attention) so
    /// callers don't need to be perfect.
    func setUIPriority(_ priority: DeckPollPriority) {
        uiPriority = priority
    }

    /// Pull one current desktop frame from the paired Mac. Callers await each
    /// frame before requesting another so capture work cannot pile up when the
    /// iPad is backgrounded or the local network slows down.
    func desktopPreview(
        displayIndex: Int? = nil,
        maxPixelWidth: Int = 1_440,
        scope: DeckDesktopPreviewScope = .display
    ) async throws -> DeckDesktopPreviewFrame {
        guard let endpoint = preferredEndpoint(), let health else {
            throw DeckBridgeClientError.badStatus(503, "The Mac is not connected.")
        }
        return try await client.desktopPreview(
            endpoint: endpoint,
            health: health,
            request: DeckDesktopPreviewRequest(
                displayIndex: displayIndex,
                maxPixelWidth: maxPixelWidth,
                scope: scope
            )
        )
    }

    func perform(
        actionID: String,
        pageID: String? = nil,
        payload: [String: DeckValue] = [:],
        label: String? = nil
    ) {
        let actionLabel = label ?? actionID
        guard let endpoint = preferredEndpoint(), let health else { return }

        Task {
            do {
                lastActionLabel = actionLabel
                isPerformingAction = true
                let request = DeckActionRequest(pageID: pageID, actionID: actionID, payload: payload)
                let result = try await performWithFallback(request: request, preferred: endpoint, health: health)
                consecutivePollFailures = 0
                lastActionResult = result
                if let runtimeSnapshot = result.runtimeSnapshot {
                    snapshot = runtimeSnapshot
                }
                let isVoiceCommand = actionID.hasPrefix("voice.")
                if !isVoiceCommand {
                    try? await Task.sleep(for: .milliseconds(350))
                }
                await refreshSnapshot(endpoint: endpoint)
                if isVoiceCommand {
                    await refreshSnapshot(endpoint: endpoint)
                }
                errorMessage = nil
            } catch {
                lastActionResult = nil
                errorMessage = error.localizedDescription
                // Deliberately not treated as revocation here. The Mac answers
                // 403 for *both* "I don't trust you" and "you weren't granted
                // that capability", so forgetting on this path would destroy a
                // perfectly good pairing because one action wasn't permitted.
                // A snapshot read is granted to every pairing, so let that be
                // the arbiter.
                await probeTrustIfRefused(error, endpoint: endpoint)
            }
            isPerformingAction = false
        }
    }

    /// Ask the one question every pairing is allowed to ask, so a 403 can be
    /// attributed. If the snapshot read is refused too, trust really is gone and
    /// `refreshSnapshot` will drop it.
    private func probeTrustIfRefused(_ error: Error, endpoint: BridgeEndpoint) async {
        guard case DeckBridgeClientError.badStatus(403, _) = error else { return }
        await refreshSnapshot(endpoint: endpoint)
    }

    // MARK: - Voice (relay)
    //
    // The iPad never captures audio. These thin wrappers fire `voice.command.*`
    // on the active Mac via the same /deck/perform bridge other actions use.
    // Live phase + transcript + errors stream back through `snapshot.voice` on
    // the existing polling cadence — no separate event channel needed.

    var voiceState: DeckVoiceState? { snapshot?.voice }

    func startVoice() {
        setUIPriority(.fast)
        perform(actionID: "voice.command.start", pageID: "home", label: "voice")
    }

    /// Wake the Mac voice runtime while the user is picking a host so capture
    /// does not pay cold-start costs on the first mic tap.
    func prewarmVoice() {
        guard let endpoint = preferredEndpoint(), let health else { return }
        Task {
            let request = DeckActionRequest(pageID: "home", actionID: "voice.runtime.warm", payload: [:])
            try? await performWithFallback(request: request, preferred: endpoint, health: health)
        }
    }

    func stopVoice() {
        perform(actionID: "voice.command.stop", pageID: "home", label: "voice")
    }

    func cancelVoice() {
        perform(actionID: "voice.cancel", pageID: "home", label: "voice")
    }

    func toggleVoice() {
        perform(actionID: "voice.command.toggle", pageID: "home", label: "voice")
    }

    func sendTrackpad(
        event: DeckTrackpadEvent,
        dx: Double = 0,
        dy: Double = 0
    ) {
        guard let endpoint = preferredEndpoint(), let health else { return }
        let generation = connectionGeneration
        let queued = QueuedTrackpadEvent(
            event: event,
            dx: dx,
            dy: dy,
            connectionGeneration: generation
        )

        guard trackpadEventInFlightGeneration == nil else {
            enqueueTrackpadEvent(queued)
            return
        }

        trackpadEventInFlightGeneration = generation
        sendTrackpadEvent(queued, endpoint: endpoint, health: health, generation: generation)
    }
}

private extension DeckStore {
    func enqueueTrackpadEvent(_ event: QueuedTrackpadEvent) {
        if event.canCoalesce,
           let last = queuedTrackpadEvents.last,
           last.event == event.event,
           last.connectionGeneration == event.connectionGeneration,
           last.canCoalesce {
            queuedTrackpadEvents[queuedTrackpadEvents.count - 1].coalesce(event)
        } else {
            queuedTrackpadEvents.append(event)
        }

        while queuedTrackpadEvents.count > maxQueuedTrackpadEvents {
            if let index = queuedTrackpadEvents.firstIndex(where: \.canCoalesce) {
                queuedTrackpadEvents.remove(at: index)
            } else {
                queuedTrackpadEvents.removeFirst()
            }
        }
    }

    func sendTrackpadEvent(
        _ queued: QueuedTrackpadEvent,
        endpoint: BridgeEndpoint,
        health: BridgeHealthResponse,
        generation: Int
    ) {
        Task {
            do {
                let result = try await client.trackpad(
                    endpoint: endpoint,
                    health: health,
                    request: DeckTrackpadEventRequest(event: queued.event, dx: queued.dx, dy: queued.dy)
                )
                guard generation == connectionGeneration else { return }
                if !result.ok {
                    errorMessage = "Trackpad input was rejected. Check that the Mac bridge is enabled and has Accessibility permission."
                } else if var currentSnapshot = snapshot,
                          var trackpad = currentSnapshot.trackpad {
                    trackpad.pointerX = result.pointerX
                    trackpad.pointerY = result.pointerY
                    currentSnapshot.trackpad = trackpad
                    snapshot = currentSnapshot
                }
            } catch {
                guard generation == connectionGeneration else { return }
                errorMessage = error.localizedDescription
                await probeTrustIfRefused(error, endpoint: endpoint)
            }
            finishTrackpadEvent(generation: generation)
        }
    }

    func finishTrackpadEvent(generation: Int) {
        guard generation == connectionGeneration,
              trackpadEventInFlightGeneration == generation else { return }

        queuedTrackpadEvents.removeAll { $0.connectionGeneration != generation }
        guard let next = queuedTrackpadEvents.first else {
            trackpadEventInFlightGeneration = nil
            return
        }

        queuedTrackpadEvents.removeFirst()
        guard let endpoint = preferredEndpoint(), let health else {
            trackpadEventInFlightGeneration = nil
            queuedTrackpadEvents.removeAll()
            return
        }

        sendTrackpadEvent(next, endpoint: endpoint, health: health, generation: generation)
    }

    func resetTrackpadPipeline() {
        queuedTrackpadEvents.removeAll()
        trackpadEventInFlightGeneration = nil
    }

    func handleDiscoveryUpdate(_ bridges: [BridgeEndpoint]) {
        discoveredBridges = bridges

        // Finding a Mac on the network is an observation; pairing with one is a
        // decision that raises a modal alert on somebody's desk. Reconnecting to
        // a Mac this device already paired with is silent and welcome, so that
        // still happens on its own — but a stranger now waits in the roster as a
        // candidate until the user actually asks for it.
        //
        // `first(where:)` rather than `first`: with several Macs on the network
        // the paired one wins regardless of where it sorts.
        if activeEndpoint == nil, !autoConnectSuppressed,
           let known = bridges.first(where: { DeckBridgeSecurityStore.shared.isTrusted(endpoint: $0) }) {
            connect(to: known)
            return
        }

        guard let activeEndpoint, activeEndpoint.source == "Bonjour" else { return }
        if let replacement = bridges.first(where: { bridge in
            bridge.name == activeEndpoint.name && bridge.port == activeEndpoint.port && bridge.host != activeEndpoint.host
        }) {
            self.activeEndpoint = replacement
            manualHost = replacement.host
        }
    }

    /// Bring a session up.
    ///
    /// `generation` is checked after every suspension: if a newer connect has
    /// started meanwhile, this one abandons rather than writing its half of a
    /// session over someone else's. Without that the sequence below can splice
    /// one Mac's `health` onto another's `manifest`, and every protected request
    /// signs against `health` — so the mismatch authenticates to the wrong Mac
    /// instead of failing loudly.
    func loadConnection(endpoint: BridgeEndpoint, forceManifest: Bool, generation: Int) async {
        isLoading = true
        defer { if generation == connectionGeneration { isLoading = false } }

        do {
            let healthResponse = try await client.health(endpoint: endpoint)
            guard generation == connectionGeneration else { return }
            health = healthResponse
            let resolvedEndpoint = canonicalEndpoint(from: endpoint, health: healthResponse)
            activeEndpoint = resolvedEndpoint
            manualHost = resolvedEndpoint.host
            manualPort = String(resolvedEndpoint.port)
            if forceManifest || manifest == nil {
                let loaded = try await client.manifest(endpoint: resolvedEndpoint)
                guard generation == connectionGeneration else { return }
                manifest = loaded
                if let firstPage = manifest?.pages.first(where: { $0.id == selectedPageID }) ?? manifest?.pages.first {
                    selectedPageID = firstPage.id
                }
            }
            try await ensurePairing(endpoint: resolvedEndpoint, health: healthResponse)
            guard generation == connectionGeneration else { return }
            // Macs move. Recording where this one answered — keyed by the public
            // key `/health` just proved, never by name or address — is what
            // keeps it reconnectable once it stops advertising on Bonjour.
            DeckBridgeSecurityStore.shared.rememberAddress(
                forPublicKey: healthResponse.bridgePublicKey,
                host: resolvedEndpoint.host,
                port: resolvedEndpoint.port
            )
            let loadedSnapshot = try await client.snapshot(endpoint: resolvedEndpoint, health: healthResponse)
            guard generation == connectionGeneration else { return }
            snapshot = loadedSnapshot
            if let firstCockpitPage = snapshot?.cockpit?.pages.first(where: { $0.id == selectedCockpitPageID }) ?? snapshot?.cockpit?.pages.first {
                selectedCockpitPageID = firstCockpitPage.id
            }
            errorMessage = nil
            consecutivePollFailures = 0
            startPolling(endpoint: resolvedEndpoint)
        } catch {
            guard generation == connectionGeneration else { return }
            guard !handleRevokedTrust(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshSnapshot(endpoint: BridgeEndpoint) async {
        do {
            let target = preferredEndpoint(fallback: endpoint) ?? endpoint
            guard let health else { return }
            snapshot = try await client.snapshot(endpoint: target, health: health)
            if let firstCockpitPage = snapshot?.cockpit?.pages.first(where: { $0.id == selectedCockpitPageID }) ?? snapshot?.cockpit?.pages.first {
                selectedCockpitPageID = firstCockpitPage.id
            }
            errorMessage = nil
            consecutivePollFailures = 0
        } catch {
            consecutivePollFailures += 1
            guard !handleRevokedTrust(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Notice that the two devices no longer agree on this pairing, and let go.
    ///
    /// Trust lives in two records — one per device — and the Mac can drop its
    /// own at any time. When it does, every protected request comes back 403
    /// while this side still holds a record saying all is well. That record is
    /// exactly what makes `ensurePairing` skip re-pairing, so the session can
    /// never recover on its own: it reconnects, gets refused, reconnects, and
    /// reports a different flavour of the same failure forever.
    ///
    /// The same deadlock happens when the iPad's private key changes while its
    /// UserDefaults trust record survives (for example, after restoring app
    /// data without its Keychain item). The Mac still knows the old public key,
    /// so it correctly rejects every signature with a 401.
    ///
    /// Dropping our half breaks either loop. The host leaves the roster and
    /// turns back into something you can add, which is the one action that can
    /// safely replace a mismatched key with explicit approval on the Mac.
    private func handleRevokedTrust(_ error: Error) -> Bool {
        guard case DeckBridgeClientError.badStatus(let status, let detail) = error else {
            return false
        }

        let macRevokedTrust = status == 403
        let signingKeyChanged = status == 401
            && detail.localizedCaseInsensitiveContains("signature could not be verified")

        guard (macRevokedTrust || signingKeyChanged),
              let publicKey = health?.bridgePublicKey,
              DeckBridgeSecurityStore.shared.trust(forPublicKey: publicKey) != nil else {
            return false
        }

        let name = connectionLabel
        DeckBridgeSecurityStore.shared.forgetBridge(publicKey: publicKey)
        disconnect(suppressAutoReconnect: true)
        if signingKeyChanged {
            errorMessage = "\(name)'s saved pairing no longer matches this iPad. Go back and add it again to reconnect."
        } else {
            errorMessage = "\(name) no longer trusts this iPad. Add it again to reconnect."
        }
        return true
    }

    func startPolling(endpoint: BridgeEndpoint) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.currentPollInterval ?? 5.0
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.refreshSnapshot(endpoint: endpoint)
            }
        }
    }

    /// Decide the next poll interval based on UI hint + last snapshot.
    /// Voice activity, pending attention, or an explicit `.fast` UI hint
    /// pull us into 1s mode; otherwise we sip at 5s. Intervals are
    /// re-evaluated each tick so the loop adapts as state changes.
    private var currentPollInterval: TimeInterval {
        // A host that is not answering gets asked less often, not more. Without
        // this the failure state was the most expensive state in the app: a
        // snapshot that went stale while holding a question pinned the loop at
        // 1Hz against a Mac that had stopped replying, each attempt paying a
        // full connect timeout.
        if consecutivePollFailures > 0 {
            let step = min(consecutivePollFailures, 5)
            return min(60.0, 2.0 * pow(2.0, Double(step - 1)))
        }

        if uiPriority == .fast { return 1.0 }
        if let voice = snapshot?.voice {
            if voice.phase != .idle { return 1.0 }
            if voice.error != nil   { return 1.0 }
        }
        if !(snapshot?.questions.isEmpty ?? true) { return 1.0 }
        return 5.0
    }

    func preferredEndpoint(fallback: BridgeEndpoint? = nil) -> BridgeEndpoint? {
        if let activeEndpoint {
            return activeEndpoint
        }
        return fallback
    }

    func canonicalEndpoint(from endpoint: BridgeEndpoint, health: BridgeHealthResponse) -> BridgeEndpoint {
        let healthName = health.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeEndpoint(
            name: healthName.isEmpty ? endpoint.name : healthName,
            host: endpointHost.isEmpty ? endpoint.host : endpointHost,
            port: Int(health.port),
            source: endpoint.source,
            bridgeFingerprint: endpoint.bridgeFingerprint ?? health.bridgeFingerprint,
            securityMode: endpoint.securityMode ?? health.mode,
            capabilities: endpoint.capabilities.isEmpty ? (health.capabilities ?? []) : endpoint.capabilities
        )
    }

    func reportedEndpoint(from endpoint: BridgeEndpoint, health: BridgeHealthResponse) -> BridgeEndpoint? {
        let host = health.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host != endpoint.host else { return nil }
        let healthName = health.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeEndpoint(
            name: healthName.isEmpty ? endpoint.name : healthName,
            host: host,
            port: Int(health.port),
            source: "Health",
            bridgeFingerprint: endpoint.bridgeFingerprint ?? health.bridgeFingerprint,
            securityMode: endpoint.securityMode ?? health.mode,
            capabilities: endpoint.capabilities.isEmpty ? (health.capabilities ?? []) : endpoint.capabilities
        )
    }

    func candidateEndpoints(for preferred: BridgeEndpoint) -> [BridgeEndpoint] {
        var candidates: [BridgeEndpoint] = [preferred]

        if let health {
            let canonical = canonicalEndpoint(from: preferred, health: health)
            if !candidates.contains(canonical) {
                candidates.append(canonical)
            }
            if let reported = reportedEndpoint(from: preferred, health: health),
               !candidates.contains(reported) {
                candidates.append(reported)
            }
        }

        for bridge in discoveredBridges where bridge.name == preferred.name && bridge.port == preferred.port {
            if !candidates.contains(bridge) {
                candidates.append(bridge)
            }
        }

        return candidates
    }

    func performWithFallback(
        request: DeckActionRequest,
        preferred: BridgeEndpoint,
        health: BridgeHealthResponse
    ) async throws -> DeckActionResult {
        var lastError: Error?

        for candidate in candidateEndpoints(for: preferred) {
            do {
                let result = try await client.perform(endpoint: candidate, health: health, request: request)
                if activeEndpoint != candidate {
                    activeEndpoint = candidate
                    manualHost = candidate.host
                    manualPort = String(candidate.port)
                }
                return result
            } catch {
                lastError = error
            }
        }

        throw lastError ?? DeckBridgeClientError.invalidResponse
    }

    func ensurePairing(endpoint: BridgeEndpoint, health: BridgeHealthResponse) async throws {
        guard manifest?.security.requestSigningRequired == true else { return }
        let security = DeckBridgeSecurityStore.shared
        guard security.isTrusted(health: health) == false else { return }

        let pairing = try await client.pair(endpoint: endpoint)
        switch pairing.disposition {
        case .approved, .alreadyTrusted:
            security.storePairing(pairing)
        case .denied:
            throw DeckBridgeClientError.badStatus(403, pairing.detail ?? "Pairing was denied on the Mac.")
        }
    }
}

// MARK: - Fleet connections

/// Owns the additional live bridge sessions used by Fleet Deck. The primary
/// `DeckStore` remains responsible for Bonjour discovery and Home; every other
/// reachable Mac gets an isolated store so actions can never leak across hosts.
@MainActor
final class DeckFleetStore: ObservableObject {
    @Published private(set) var secondaryStores: [DeckStore] = []

    private var storesByEndpointKey: [String: DeckStore] = [:]

    /// Macs the user added deliberately. Discovery may never report them — a
    /// hand-entered address on a network where Bonjour is blocked never will —
    /// so reconciliation must not treat their absence as a reason to reap them.
    private var adoptedKeys: Set<String> = []

    /// Republish when any secondary session changes.
    ///
    /// `secondaryStores` being `@Published` only announces the *array* — adding
    /// or removing a Mac. It says nothing when a Mac inside it gets a new
    /// snapshot, so anything observing this store alone saw every host but the
    /// primary frozen at whatever it happened to hold when it arrived.
    private var storeSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]

    private func observe(_ store: DeckStore) {
        let key = ObjectIdentifier(store)
        guard storeSubscriptions[key] == nil else { return }
        storeSubscriptions[key] = store.objectWillChange
            // `objectWillChange` fires *before* the value lands, so republishing
            // synchronously would broadcast the old state.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func stopObserving(_ store: DeckStore) {
        storeSubscriptions.removeValue(forKey: ObjectIdentifier(store))
    }

    func synchronize(with primaryStore: DeckStore) {
        let primaryKey = primaryStore.activeEndpoint.map(Self.endpointKey)
        var desiredKeys = Set<String>()
        var orderedStores: [DeckStore] = []

        for endpoint in primaryStore.discoveredBridges {
            // Secondary sessions are created only for Macs this device has
            // already paired with. This prevents Fleet Deck from spraying
            // approval prompts across every Bonjour peer on the network.
            guard DeckBridgeSecurityStore.shared.isTrusted(endpoint: endpoint) else { continue }

            let key = Self.endpointKey(endpoint)
            guard key != primaryKey else { continue }
            guard desiredKeys.insert(key).inserted else { continue }

            let store: DeckStore
            if let existing = storesByEndpointKey[key] {
                store = existing
                if existing.activeEndpoint != endpoint && existing.health == nil {
                    existing.connect(to: endpoint)
                }
            } else {
                store = DeckStore(endpoint: endpoint, discoversBridges: false)
                storesByEndpointKey[key] = store
                observe(store)
            }
            orderedStores.append(store)
        }

        let staleKeys = storesByEndpointKey.keys.filter {
            !desiredKeys.contains($0) && !adoptedKeys.contains($0)
        }
        for key in staleKeys {
            if let reaped = storesByEndpointKey.removeValue(forKey: key) {
                stopObserving(reaped)
                reaped.disconnect()
            }
        }

        // A Mac the user added by hand keeps its place in the fleet even when
        // this pass didn't see it on the network.
        for key in adoptedKeys where !desiredKeys.contains(key) {
            guard let store = storesByEndpointKey[key] else { continue }
            orderedStores.append(store)
        }

        secondaryStores = orderedStores
    }

    /// Bring a just-paired Mac into the fleet now, instead of waiting for the
    /// next discovery tick to notice it.
    ///
    /// Safe against the trust guard in `synchronize` because callers pair
    /// *before* they adopt: by the time this runs the Mac is trusted like any
    /// other, so nothing has to be held open or specially exempted while a
    /// human is deciding.
    func adopt(_ endpoint: BridgeEndpoint) {
        let key = Self.endpointKey(endpoint)
        adoptedKeys.insert(key)

        if let existing = storesByEndpointKey[key] {
            if !secondaryStores.contains(where: { $0 === existing }) {
                secondaryStores.append(existing)
            }
            return
        }

        let store = DeckStore(endpoint: endpoint, discoversBridges: false)
        storesByEndpointKey[key] = store
        observe(store)
        secondaryStores.append(store)
    }

    /// Drop a Mac from the fleet. Adoption is user intent, so only the user
    /// undoes it — discovery never does.
    func release(_ endpoint: BridgeEndpoint) {
        let key = Self.endpointKey(endpoint)
        adoptedKeys.remove(key)
        guard let store = storesByEndpointKey.removeValue(forKey: key) else { return }
        stopObserving(store)
        store.disconnect()
        secondaryStores.removeAll { $0 === store }
    }

    /// Let go of every secondary whose pairing is gone.
    ///
    /// Forgetting a Mac removes its trust record, but reconciliation only runs
    /// when discovery changes — and forgetting doesn't change discovery. So
    /// without this a forgotten Mac kept its session alive and went on signing
    /// requests against a host the user had just told us to drop.
    func releaseUntrusted() {
        let security = DeckBridgeSecurityStore.shared
        for (key, store) in storesByEndpointKey {
            let isTrusted: Bool
            if let publicKey = store.health?.bridgePublicKey {
                isTrusted = security.trust(forPublicKey: publicKey) != nil
            } else if let endpoint = store.activeEndpoint {
                isTrusted = security.isTrusted(endpoint: endpoint)
            } else {
                continue  // Still connecting — nothing proven either way yet.
            }
            guard !isTrusted else { continue }

            adoptedKeys.remove(key)
            storesByEndpointKey.removeValue(forKey: key)
            stopObserving(store)
            store.disconnect()
            secondaryStores.removeAll { $0 === store }
        }
    }

    func stores(including primaryStore: DeckStore) -> [DeckStore] {
        var result: [DeckStore] = []
        if primaryStore.activeEndpoint != nil {
            result.append(primaryStore)
        }
        result.append(contentsOf: secondaryStores)
        return result
    }

    func setUIPriority(_ priority: DeckPollPriority, primaryStore: DeckStore) {
        for store in stores(including: primaryStore) {
            store.setUIPriority(priority)
        }
    }

    private static func endpointKey(_ endpoint: BridgeEndpoint) -> String {
        if let fingerprint = endpoint.bridgeFingerprint, !fingerprint.isEmpty {
            return "fingerprint:\(fingerprint.lowercased())"
        }
        let name = endpoint.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !name.isEmpty {
            return "service:\(name):\(endpoint.port)"
        }
        return "host:\(endpoint.host.lowercased()):\(endpoint.port)"
    }
}

#if DEBUG
extension DeckStore {
    /// Deterministic live-looking store for Fleet Deck previews and simulator
    /// screenshot passes. It never starts discovery or sends network traffic.
    static func fleetPreview(name: String, index: Int) -> DeckStore {
        let store = DeckStore(discoversBridges: false)
        store.activeEndpoint = BridgeEndpoint(
            name: name,
            host: "preview-\(index).local",
            port: 9399,
            source: "Preview"
        )

        let accents = ["green", "blue", "violet", "amber"]
        let apps = ["Xcode", "iTerm2", "Figma", "Safari"]
        let accent = accents[index % accents.count]
        let app = apps[index % apps.count]

        func tile(_ id: String, _ title: String, _ icon: String, _ action: String, tint: String? = nil) -> DeckCockpitTile {
            DeckCockpitTile(
                id: "\(index)-\(id)",
                shortcutID: id,
                title: title,
                subtitle: nil,
                iconSystemName: icon,
                accentToken: tint ?? accent,
                actionID: action
            )
        }

        let command = DeckCockpitPage(
            id: "command",
            title: "Command",
            columns: 3,
            tiles: [
                tile("voice", "Voice", "waveform", "voice.command.toggle", tint: "red"),
                tile("focus", "Focus", "scope", "windows.focusFrontmost"),
                tile("paste", "Paste", "doc.on.clipboard", "clipboard.pasteFromDevice"),
                tile("left", "Tile Left", "rectangle.lefthalf.inset.filled", "window.tile.left", tint: "blue"),
                tile("right", "Tile Right", "rectangle.righthalf.inset.filled", "window.tile.right", tint: "blue"),
                tile("agent", "Run Agent", "sparkles", "agent.run", tint: "violet")
            ]
        )
        let windows = DeckCockpitPage(
            id: "windows",
            title: "Windows",
            columns: 3,
            tiles: [
                tile("maximize", "Maximize", "rectangle.inset.filled", "window.maximize", tint: "blue"),
                tile("center", "Center", "rectangle.center.inset.filled", "window.center", tint: "blue"),
                tile("next", "Next Space", "arrow.right.square", "spaces.next", tint: "teal"),
                tile("prev", "Prev Space", "arrow.left.square", "spaces.previous", tint: "teal")
            ]
        )

        store.snapshot = DeckRuntimeSnapshot(
            cockpit: DeckCockpitState(title: "Fleet", pages: [command, windows]),
            trackpad: DeckTrackpadState(
                isEnabled: true,
                isAvailable: true,
                statusTitle: "Ready",
                pointerScale: 1.6
            ),
            voice: DeckVoiceState(
                phase: .idle,
                transcript: [
                    "route this Mac to the common deck",
                    "keep tests visible while the agent runs",
                    "show the current design pass",
                    "hold this build in standby"
                ][index]
            ),
            desktop: DeckDesktopSummary(
                activeLayerName: "Deep Work",
                activeAppName: app,
                screenCount: 2,
                visibleWindowCount: 8 + index,
                sessionCount: 3,
                currentSpaceIndex: 1,
                currentSpaceName: index.isMultiple(of: 2) ? "Code" : "Review"
            ),
            layout: DeckLayoutState(
                frontmostWindow: DeckLayoutFocusWindow(
                    id: "preview-window-\(index)",
                    itemID: "preview-item-\(index)",
                    appName: app,
                    title: index.isMultiple(of: 2) ? "FleetDeckScreen.swift" : "Design review",
                    frame: DeckRect(x: 80, y: 70, w: 1100, h: 720)
                )
            ),
            telemetry: DeckSystemTelemetry(
                cpuLoadPercent: Double(24 + index * 11),
                memoryUsedPercent: Double(52 + index * 7),
                gpuLoadPercent: Double(8 + index * 5),
                windowCount: 8 + index,
                sessionCount: 3
            ),
            cockpitMode: DeckCockpitModeState(
                mode: index == 3 ? .idle : .agent,
                elapsedSeconds: Double(42 + index * 19),
                agentProgress: Double(36 + index * 14) / 100,
                agentRows: [
                    DeckAgentPlanRow(
                        id: "agent-live-\(index)",
                        state: index == 3 ? .done : .live,
                        text: ["refining fleet controls", "running iPad checks", "reviewing visual system", "build queue clear"][index]
                    ),
                    DeckAgentPlanRow(
                        id: "agent-next-\(index)",
                        state: .next,
                        text: ["verify channel routing", "inspect simulator logs", "prepare design notes", "waiting for work"][index]
                    )
                ]
            ),
            activityLog: [
                DeckActivityLogEntry(
                    id: "activity-primary-\(index)",
                    createdAt: .now.addingTimeInterval(Double(-18 - index * 12)),
                    tag: ["CODEX", "TEST", "SCOUT", "BUILD"][index],
                    tint: ["violet", "green", "blue", "amber"][index],
                    text: ["polishing common deck", "simulator suite running", "reviewing lane model", "standing by"][index]
                ),
                DeckActivityLogEntry(
                    id: "activity-secondary-\(index)",
                    createdAt: .now.addingTimeInterval(Double(-86 - index * 21)),
                    tag: ["SCOUT", "XCODE", "DESIGN", "AGENT"][index],
                    tint: ["blue", "green", "violet", "amber"][index],
                    text: ["checked interaction map", "build succeeded", "tuning control lighting", "queue empty"][index]
                ),
                DeckActivityLogEntry(
                    id: "activity-tertiary-\(index)",
                    createdAt: .now.addingTimeInterval(Double(-154 - index * 27)),
                    tag: ["BUILD", "CODEX", "REVIEW", "SYSTEM"][index],
                    tint: ["green", "violet", "blue", "green"][index],
                    text: ["fixture data refreshed", "checking shared controls", "spacing pass complete", "all services nominal"][index]
                )
            ],
            // Two of the four Macs are blocked on a human decision, so the deck
            // has something to triage — the Fleet Deck's whole reason to exist.
            questions: previewQuestions(index: index)
        )
        return store
    }

    private static func previewQuestions(index: Int) -> [DeckQuestionCard] {
        switch index {
        case 2:
            return [
                DeckQuestionCard(
                    id: "preview-question-lane",
                    prompt: "Which naming scheme should I apply across all screens?",
                    detail: "Lane model review is blocked — two naming options need your call.",
                    options: [
                        DeckQuestionOption(
                            id: "lane-a",
                            title: "route / lane / bus",
                            detail: "matches the audio-desk metaphor",
                            actionID: "agent.answer"
                        ),
                        DeckQuestionOption(
                            id: "lane-b",
                            title: "channel / track / send",
                            detail: "matches the deck labels",
                            actionID: "agent.answer"
                        )
                    ]
                )
            ]
        case 3:
            return [
                DeckQuestionCard(
                    id: "preview-question-ship",
                    prompt: "Push build 412 to TestFlight now?",
                    detail: "Build 412 is signed and staged — needs your go before it ships.",
                    options: [
                        DeckQuestionOption(
                            id: "ship-now",
                            title: "Ship it",
                            detail: "notify the fleet when live",
                            actionID: "agent.answer"
                        ),
                        DeckQuestionOption(
                            id: "ship-hold",
                            title: "Hold for nightly",
                            detail: "roll it into the 02:00 batch",
                            actionID: "agent.answer"
                        )
                    ]
                )
            ]
        default:
            return []
        }
    }
}
#endif
