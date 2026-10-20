import CryptoKit
import DeckKit
import Foundation

/// Why pairing ended without a Mac joining the roster.
enum AddHostFailure: Equatable {
    /// The Mac declined. An answer, not an error — it gets no signal colour.
    case denied
    /// The question never got answered: the Mac was unreachable, asleep, or
    /// stopped responding. This one *is* a failure — the system owes the
    /// explanation, so it carries the error treatment.
    case unreachable(String)
}

/// One sheet, five phases, one screen each.
enum AddHostPhase: Equatable {
    case picking
    case confirming(BridgeEndpoint)
    case waiting(BridgeEndpoint)
    case added(BridgeEndpoint, withheld: [String])
    case failed(BridgeEndpoint, AddHostFailure)
}

@MainActor
final class AddHostController: ObservableObject {
    @Published private(set) var phase: AddHostPhase = .picking
    /// Seconds spent waiting. A clock rather than a spinner: see `AddHostSheet`.
    @Published private(set) var waitedSeconds: Int = 0

    /// Typed by hand when Bonjour can't see the Mac.
    @Published var manualHost = ""
    @Published var manualPort = "9399"

    private let client = DeckBridgeClient()
    private var pairingTask: Task<Void, Never>?

    /// How long before the wait is worth explaining rather than just showing.
    static let patienceThreshold = 25

    /// This iPad's own code, the same string the Mac's approval alert leads
    /// with. The user compares the two; that comparison is the only part of the
    /// exchange an impostor on the network cannot fake, because every other
    /// field in that alert — the device's name, its id, its platform — is
    /// chosen by whoever sent the request.
    let deviceCode = DeckBridgeSecurityStore.shared.deviceFingerprint

    var isWaitingLongerThanExpected: Bool {
        waitedSeconds >= Self.patienceThreshold
    }

    // MARK: - Navigation

    func choose(_ endpoint: BridgeEndpoint) {
        phase = .confirming(endpoint)
    }

    /// Returns to the list, abandoning anything in flight.
    ///
    /// Cancelling stops the iPad waiting; it cannot retract the alert already
    /// on the Mac. If the user approves after cancelling, the Mac holds a trust
    /// record this device doesn't — which heals on the next attempt, because
    /// the Mac answers `alreadyTrusted` and we store it then.
    func backToPicking() {
        cancelPairing()
        phase = .picking
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        waitedSeconds = 0
    }

    /// The manually-typed endpoint, or nil when the fields aren't usable yet.
    var manualEndpoint: BridgeEndpoint? {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(manualPort), port > 0 else { return nil }
        return BridgeEndpoint(name: host, host: host, port: port, source: "Manual")
    }

    // MARK: - The handshake

    /// Pair with a Mac, then hand the trusted endpoint back to the caller.
    ///
    /// The order is the design: trust is stored *before* any session exists, so
    /// the new Mac satisfies the fleet's existing trust check on its own terms.
    /// Nothing has to be kept alive across the discovery churn that happens
    /// while a human is deciding.
    func pair(
        with endpoint: BridgeEndpoint,
        onPaired: @escaping (BridgeEndpoint) -> Void
    ) {
        pairingTask?.cancel()
        waitedSeconds = 0
        phase = .waiting(endpoint)

        pairingTask = Task { [weak self] in
            guard let self else { return }

            let clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.waitedSeconds += 1
                }
            }
            defer { clock.cancel() }

            // Reach the Mac first, so an unreachable host is reported as
            // unreachable rather than as a pairing that mysteriously never
            // returns — and so a hand-typed address picks up the Mac's real
            // identity before anything is written down about it.
            let health: BridgeHealthResponse
            do {
                health = try await self.client.health(endpoint: endpoint)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(endpoint, .unreachable(error.localizedDescription))
                return
            }
            guard !Task.isCancelled else { return }

            let canonical = endpoint.adoptingIdentity(from: health)

            do {
                let response = try await self.client.pair(endpoint: canonical)
                guard !Task.isCancelled else { return }

                switch response.disposition {
                case .approved, .alreadyTrusted:
                    DeckBridgeSecurityStore.shared.storePairing(
                        response,
                        lastKnownHost: canonical.host,
                        lastKnownPort: canonical.port
                    )
                    onPaired(canonical)
                    self.phase = .added(canonical, withheld: Self.withheld(from: response))
                case .denied:
                    self.phase = .failed(canonical, .denied)
                }
            } catch DeckBridgeClientError.badStatus(403, _) {
                guard !Task.isCancelled else { return }
                self.phase = .failed(canonical, .denied)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(canonical, .unreachable(error.localizedDescription))
            }
        }
    }

    /// Capabilities we asked for and did not get. Said once, on the way in,
    /// rather than surfacing as `insufficientCapability` mid-gesture days later.
    private static func withheld(from response: DeckPairingResponse) -> [String] {
        let granted = Set(response.grantedCapabilities)
        return DeckBridgeCapability.defaultCompanionCapabilities.filter { !granted.contains($0) }
    }
}

// MARK: - Candidates

extension AddHostController {
    /// Hosts Bonjour can currently see that this device has never paired with.
    ///
    /// Trusted hosts are deliberately absent: they are already in the roster,
    /// and a list of "things to add" that includes what you already have is a
    /// list that invites a second, pointless pairing.
    ///
    /// Passive discovery only — Home uses this for its count, and Home should
    /// never be sweeping the network on its own.
    static func candidates(from store: DeckStore) -> [BridgeEndpoint] {
        store.discoveredBridges.filter { !DeckBridgeSecurityStore.shared.isTrusted(endpoint: $0) }
    }

    /// What the picker offers: everything Bonjour found, plus anything a sweep
    /// turned up, minus what is already paired.
    ///
    /// Bonjour entries win on collision. A scan result knows an address and a
    /// fingerprint; a Bonjour record knows the service name the Mac chose for
    /// itself, which is what the user recognises in a list.
    static func candidates(from store: DeckStore, including scanned: [BridgeEndpoint]) -> [BridgeEndpoint] {
        var result = candidates(from: store)
        var seen = Set(result.map(\.id))

        for endpoint in scanned {
            guard !DeckBridgeSecurityStore.shared.isTrusted(endpoint: endpoint) else { continue }
            // A Mac found both ways is one Mac. Match on fingerprint where
            // there is one, since the same host answers on two names often
            // enough that address comparison alone would double it up.
            let duplicate = result.contains { existing in
                if let a = existing.bridgeFingerprint, let b = endpoint.bridgeFingerprint, !a.isEmpty {
                    return a.caseInsensitiveCompare(b) == .orderedSame
                }
                return false
            }
            guard !duplicate, seen.insert(endpoint.id).inserted else { continue }
            result.append(endpoint)
        }

        return result
    }

    /// A human label for a capability the Mac withheld.
    static func capabilityLabel(_ capability: String) -> String {
        switch capability {
        case DeckBridgeCapability.deckRead:     return "reading this host's state"
        case DeckBridgeCapability.deckPerform:  return "running commands"
        case DeckBridgeCapability.inputTrackpad: return "trackpad control"
        case DeckBridgeCapability.screenPreview: return "viewing this Mac's screen"
        default:                                 return capability
        }
    }
}
