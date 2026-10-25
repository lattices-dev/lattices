import AppKit
import CryptoKit
import DeckKit
import Foundation

enum LatticesCompanionSecurityError: LocalizedError {
    case missingHeader(String)
    case untrustedDevice
    case staleRequest
    case replayedRequest
    case invalidSignature
    case invalidEnvelope
    case invalidDeviceKey
    case insufficientCapability(String)

    var errorDescription: String? {
        switch self {
        case .missingHeader(let name):
            return "Missing bridge security header: \(name)."
        case .untrustedDevice:
            return "This device is not trusted by the Mac bridge yet."
        case .staleRequest:
            return "This bridge request expired before it reached the Mac."
        case .replayedRequest:
            return "This bridge request was already used."
        case .invalidSignature:
            return "The bridge request signature could not be verified."
        case .invalidEnvelope:
            return "The bridge payload could not be decrypted."
        case .invalidDeviceKey:
            return "The device pairing key is invalid."
        case .insufficientCapability(let capability):
            return "This trusted device is missing the required bridge capability: \(capability)."
        }
    }
}

struct LatticesCompanionTrustedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var publicKey: String
    var fingerprint: String
    var platform: String
    var appVersion: String?
    var capabilities: [String]?
    var pairedAt: Date
    var lastSeenAt: Date

    var summary: DeckTrustedDeviceSummary {
        DeckTrustedDeviceSummary(
            id: id,
            name: name,
            fingerprint: fingerprint,
            capabilities: effectiveCapabilities,
            pairedAt: pairedAt,
            lastSeenAt: lastSeenAt
        )
    }

    var effectiveCapabilities: [String] {
        capabilities ?? DeckBridgeCapability.legacyCompanionCapabilities
    }
}

struct AuthorizedBridgeRequest {
    let device: LatticesCompanionTrustedDeviceRecord
    let requestNonce: String
    let requestTimestamp: String
}

final class LatticesCompanionSecurityCoordinator {
    static let shared = LatticesCompanionSecurityCoordinator()

    private enum DefaultsKey {
        static let trustedDevices = "companion.security.trustedDevices"
    }

    private enum Header {
        static let deviceID = "x-lattices-device-id"
        static let timestamp = "x-lattices-timestamp"
        static let nonce = "x-lattices-nonce"
        static let signature = "x-lattices-signature"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let bridgePrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let timeSkewAllowance: TimeInterval = 120
    private let replayWindow: TimeInterval = 600

    private var trustedDevices: [String: LatticesCompanionTrustedDeviceRecord]
    private var seenNonces: [String: Date] = [:]

    private init() {
        self.bridgePrivateKey = Self.loadBridgeKey()
        self.trustedDevices = Self.loadTrustedDevices()
    }

    var bridgePublicKeyBase64: String {
        Data(bridgePrivateKey.publicKey.rawRepresentation).base64EncodedString()
    }

    var bridgeFingerprint: String {
        Self.fingerprint(forPublicKeyBase64: bridgePublicKeyBase64)
    }

    func trustedDeviceSummaries() -> [DeckTrustedDeviceSummary] {
        trustedDevices.values
            .map(\.summary)
            .sorted { lhs, rhs in
                if lhs.lastSeenAt == rhs.lastSeenAt {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }

    func clearTrustedDevices() {
        trustedDevices.removeAll()
        persistTrustedDevices()
    }

    func revokeTrustedDevice(id: String) {
        trustedDevices.removeValue(forKey: id)
        persistTrustedDevices()
    }

    func handlePairingRequest(_ request: DeckPairingRequest) -> DeckPairingResponse {
        let diag = DiagnosticLog.shared
        diag.info("CompanionPairing: request device=\(request.deviceName) id=\(request.deviceID)")
        let grantedCapabilities = Self.grantedCapabilities(for: request.requestedCapabilities)

        guard
            request.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            decodePublicKey(base64: request.devicePublicKey) != nil
        else {
            diag.warn("CompanionPairing: invalid key material for device id=\(request.deviceID)")
            return DeckPairingResponse(
                disposition: .denied,
                bridgeName: Host.current().localizedName ?? "Lattices Companion",
                bridgePublicKey: bridgePublicKeyBase64,
                bridgeFingerprint: bridgeFingerprint,
                requestSigningRequired: true,
                payloadEncryptionRequired: true,
                grantedCapabilities: [],
                detail: LatticesCompanionSecurityError.invalidDeviceKey.localizedDescription
            )
        }

        if var existing = trustedDevices[request.deviceID], existing.publicKey == request.devicePublicKey {
            existing.lastSeenAt = Date()
            let existingCapabilities = existing.effectiveCapabilities
            let additions = Self.additionalCapabilities(
                existing: existingCapabilities,
                requested: grantedCapabilities
            )
            let upgradeApproved = additions.isEmpty
                || promptForCapabilityUpgrade(request, additions: additions)
            existing.capabilities = Self.capabilitiesAfterPairingRequest(
                existing: existingCapabilities,
                requested: grantedCapabilities,
                upgradeApproved: upgradeApproved
            )
            trustedDevices[request.deviceID] = existing
            persistTrustedDevices()
            diag.success("CompanionPairing: device already trusted id=\(request.deviceID)")
            return DeckPairingResponse(
                disposition: .alreadyTrusted,
                bridgeName: Host.current().localizedName ?? "Lattices Companion",
                bridgePublicKey: bridgePublicKeyBase64,
                bridgeFingerprint: bridgeFingerprint,
                requestSigningRequired: true,
                payloadEncryptionRequired: true,
                grantedCapabilities: existing.effectiveCapabilities,
                detail: "This device is already trusted on the Mac."
            )
        }

        let approved = promptForPairingApproval(request)
        guard approved else {
            diag.warn("CompanionPairing: denied device id=\(request.deviceID)")
            return DeckPairingResponse(
                disposition: .denied,
                bridgeName: Host.current().localizedName ?? "Lattices Companion",
                bridgePublicKey: bridgePublicKeyBase64,
                bridgeFingerprint: bridgeFingerprint,
                requestSigningRequired: true,
                payloadEncryptionRequired: true,
                grantedCapabilities: [],
                detail: "Pairing was denied on the Mac."
            )
        }

        let now = Date()
        trustedDevices[request.deviceID] = LatticesCompanionTrustedDeviceRecord(
            id: request.deviceID,
            name: request.deviceName,
            publicKey: request.devicePublicKey,
            fingerprint: Self.fingerprint(forPublicKeyBase64: request.devicePublicKey),
            platform: request.platform,
            appVersion: request.appVersion,
            capabilities: grantedCapabilities,
            pairedAt: now,
            lastSeenAt: now
        )
        persistTrustedDevices()
        diag.success("CompanionPairing: approved device id=\(request.deviceID)")

        return DeckPairingResponse(
            disposition: .approved,
            bridgeName: Host.current().localizedName ?? "Lattices Companion",
            bridgePublicKey: bridgePublicKeyBase64,
            bridgeFingerprint: bridgeFingerprint,
            requestSigningRequired: true,
            payloadEncryptionRequired: true,
            grantedCapabilities: grantedCapabilities,
            detail: "Trusted and ready for encrypted bridge requests."
        )
    }

    func authorize(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) throws -> AuthorizedBridgeRequest {
        let deviceID = try requiredHeader(Header.deviceID, from: headers)
        let timestamp = try requiredHeader(Header.timestamp, from: headers)
        let requestNonce = try requiredHeader(Header.nonce, from: headers)
        let signature = try requiredHeader(Header.signature, from: headers)

        guard let device = trustedDevices[deviceID] else {
            throw LatticesCompanionSecurityError.untrustedDevice
        }

        let requestDate = try parseRequestDate(timestamp)
        let now = Date()
        guard abs(requestDate.timeIntervalSince(now)) <= timeSkewAllowance else {
            throw LatticesCompanionSecurityError.staleRequest
        }

        pruneSeenNonces(now: now)
        let replayKey = "\(deviceID):\(requestNonce)"
        guard seenNonces[replayKey] == nil else {
            throw LatticesCompanionSecurityError.replayedRequest
        }

        let expectedSignature = try requestSignature(
            method: method,
            path: path,
            device: device,
            timestamp: timestamp,
            requestNonce: requestNonce,
            body: body
        )
        guard Self.constantTimeEquals(signature, expectedSignature) else {
            throw LatticesCompanionSecurityError.invalidSignature
        }

        seenNonces[replayKey] = now
        touchDevice(deviceID: deviceID, at: now)
        return AuthorizedBridgeRequest(
            device: trustedDevices[deviceID] ?? device,
            requestNonce: requestNonce,
            requestTimestamp: timestamp
        )
    }

    func requireCapability(_ capability: String, for auth: AuthorizedBridgeRequest) throws {
        guard auth.device.effectiveCapabilities.contains(capability) else {
            throw LatticesCompanionSecurityError.insufficientCapability(capability)
        }
    }

    func decodeProtectedBody<T: Decodable>(
        _ type: T.Type,
        body: Data,
        auth: AuthorizedBridgeRequest,
        method: String,
        path: String
    ) throws -> T {
        let envelope = try decoder.decode(DeckEncryptedEnvelope.self, from: body)
        let plaintext = try openEnvelope(
            envelope,
            device: auth.device,
            aad: requestAAD(
                method: method,
                path: path,
                deviceID: auth.device.id,
                timestamp: auth.requestTimestamp,
                requestNonce: auth.requestNonce
            )
        )
        return try decoder.decode(type, from: plaintext)
    }

    func encodeProtectedResponse<T: Encodable>(
        _ value: T,
        auth: AuthorizedBridgeRequest,
        status: Int,
        path: String
    ) throws -> DeckEncryptedEnvelope {
        let plaintext = try encoder.encode(value)
        return try sealEnvelope(
            plaintext,
            device: auth.device,
            aad: responseAAD(
                status: status,
                path: path,
                deviceID: auth.device.id,
                requestNonce: auth.requestNonce
            )
        )
    }
}

extension LatticesCompanionSecurityCoordinator {
    static func loadTrustedDevices() -> [String: LatticesCompanionTrustedDeviceRecord] {
        guard
            let data = UserDefaults.standard.data(forKey: DefaultsKey.trustedDevices),
            let devices = try? JSONDecoder().decode([LatticesCompanionTrustedDeviceRecord].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    }

    /// The bridge serves with the machine's device identity, so a paired iPad
    /// and a visiting Mac pin the same key. When the identity cannot be read
    /// the bridge runs on a key for this session only, and peers must re-pair.
    static func loadBridgeKey() -> Curve25519.KeyAgreement.PrivateKey {
        switch DeviceIdentity.current {
        case .success(let identity):
            return identity.privateKey
        case .failure(let error):
            DiagnosticLog.shared.warn("Companion · \(error.localizedDescription); the bridge uses a key for this session only")
            return Curve25519.KeyAgreement.PrivateKey()
        }
    }

    static func fingerprint(forPublicKeyBase64 value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let compact = String(hex.prefix(12)).uppercased()
        return compact.chunked(into: 4).joined(separator: "-")
    }

    static func grantedCapabilities(for requested: [String]) -> [String] {
        let supported = Set(DeckBridgeCapability.defaultCompanionCapabilities)
        let requested = requested.isEmpty ? supported : Set(requested)
        return requested
            .intersection(supported)
            .sorted()
    }

    static func additionalCapabilities(existing: [String], requested: [String]) -> [String] {
        Array(Set(requested).subtracting(existing)).sorted()
    }

    static func capabilitiesAfterPairingRequest(
        existing: [String],
        requested: [String],
        upgradeApproved: Bool
    ) -> [String] {
        guard upgradeApproved else { return Array(Set(existing)).sorted() }
        return Array(Set(existing).union(requested)).sorted()
    }

    func persistTrustedDevices() {
        let sorted = trustedDevices.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        guard let data = try? encoder.encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.trustedDevices)
    }

    func requiredHeader(_ name: String, from headers: [String: String]) throws -> String {
        guard let value = headers[name], value.isEmpty == false else {
            throw LatticesCompanionSecurityError.missingHeader(name)
        }
        return value
    }

    func parseRequestDate(_ timestamp: String) throws -> Date {
        guard let value = ISO8601DateFormatter.latticesBridge.date(from: timestamp) else {
            throw LatticesCompanionSecurityError.staleRequest
        }
        return value
    }

    func requestSignature(
        method: String,
        path: String,
        device: LatticesCompanionTrustedDeviceRecord,
        timestamp: String,
        requestNonce: String,
        body: Data
    ) throws -> String {
        let key = try signingKey(for: device)
        let canonical = requestCanonicalData(
            method: method,
            path: path,
            deviceID: device.id,
            timestamp: timestamp,
            requestNonce: requestNonce,
            body: body
        )
        let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key)
        return Data(mac).base64EncodedString()
    }

    func requestCanonicalData(
        method: String,
        path: String,
        deviceID: String,
        timestamp: String,
        requestNonce: String,
        body: Data
    ) -> Data {
        let digest = SHA256.hash(data: body)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let canonical = [
            method.uppercased(),
            path,
            deviceID,
            timestamp,
            requestNonce,
            hex
        ].joined(separator: "\n")
        return Data(canonical.utf8)
    }

    func requestAAD(
        method: String,
        path: String,
        deviceID: String,
        timestamp: String,
        requestNonce: String
    ) -> Data {
        let value = [
            "request",
            method.uppercased(),
            path,
            deviceID,
            timestamp,
            requestNonce
        ].joined(separator: "\n")
        return Data(value.utf8)
    }

    func responseAAD(
        status: Int,
        path: String,
        deviceID: String,
        requestNonce: String
    ) -> Data {
        let value = [
            "response",
            String(status),
            path,
            deviceID,
            requestNonce
        ].joined(separator: "\n")
        return Data(value.utf8)
    }

    func signingKey(for device: LatticesCompanionTrustedDeviceRecord) throws -> SymmetricKey {
        let publicKey = try trustedPublicKey(for: device)
        let sharedSecret = try bridgePrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("lattices-bridge-v1".utf8),
            sharedInfo: Data("signing".utf8),
            outputByteCount: 32
        )
    }

    func encryptionKey(for device: LatticesCompanionTrustedDeviceRecord) throws -> SymmetricKey {
        let publicKey = try trustedPublicKey(for: device)
        let sharedSecret = try bridgePrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("lattices-bridge-v1".utf8),
            sharedInfo: Data("encryption".utf8),
            outputByteCount: 32
        )
    }

    func trustedPublicKey(for device: LatticesCompanionTrustedDeviceRecord) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let key = decodePublicKey(base64: device.publicKey) else {
            throw LatticesCompanionSecurityError.invalidDeviceKey
        }
        return key
    }

    func decodePublicKey(base64: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    func openEnvelope(
        _ envelope: DeckEncryptedEnvelope,
        device: LatticesCompanionTrustedDeviceRecord,
        aad: Data
    ) throws -> Data {
        guard let data = Data(base64Encoded: envelope.sealedBox),
              let sealed = try? ChaChaPoly.SealedBox(combined: data) else {
            throw LatticesCompanionSecurityError.invalidEnvelope
        }
        let key = try encryptionKey(for: device)
        guard let plaintext = try? ChaChaPoly.open(sealed, using: key, authenticating: aad) else {
            throw LatticesCompanionSecurityError.invalidEnvelope
        }
        return plaintext
    }

    func sealEnvelope(
        _ plaintext: Data,
        device: LatticesCompanionTrustedDeviceRecord,
        aad: Data
    ) throws -> DeckEncryptedEnvelope {
        let key = try encryptionKey(for: device)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        return DeckEncryptedEnvelope(sealedBox: Data(sealed.combined).base64EncodedString())
    }

    func pruneSeenNonces(now: Date) {
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < replayWindow }
    }

    func touchDevice(deviceID: String, at date: Date) {
        guard var device = trustedDevices[deviceID] else { return }
        guard date.timeIntervalSince(device.lastSeenAt) >= 30 else { return }
        device.lastSeenAt = date
        trustedDevices[deviceID] = device
        persistTrustedDevices()
    }

    func promptForPairingApproval(_ request: DeckPairingRequest) -> Bool {
        if Thread.isMainThread {
            return runPairingAlert(request)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var approved = false

        DispatchQueue.main.async {
            approved = self.runPairingAlert(request)
            semaphore.signal()
        }

        semaphore.wait()
        return approved
    }

    func promptForCapabilityUpgrade(_ request: DeckPairingRequest, additions: [String]) -> Bool {
        if Thread.isMainThread {
            return runCapabilityUpgradeAlert(request, additions: additions)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var approved = false
        DispatchQueue.main.async {
            approved = self.runCapabilityUpgradeAlert(request, additions: additions)
            semaphore.signal()
        }
        semaphore.wait()
        return approved
    }

    func runCapabilityUpgradeAlert(_ request: DeckPairingRequest, additions: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let code = Self.fingerprint(forPublicKeyBase64: request.devicePublicKey)
        let labels = additions.map(Self.userFacingCapabilityName)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow more access for this device?"
        alert.informativeText = """
        “\(request.deviceName)” is already paired as \(code) and is asking for:

            \(labels.joined(separator: "\n    "))

        Existing access remains available if you keep the current permissions.
        """
        alert.addButton(withTitle: "Allow Access")
        alert.addButton(withTitle: "Keep Current Access")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func runPairingAlert(_ request: DeckPairingRequest) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        // Everything a device tells us about itself — its name, its id, its
        // platform — is chosen by whoever sent the request, so a machine on
        // the same network can raise a prompt that looks exactly like the one
        // the user is expecting. The fingerprint is the only field here that
        // is derived from a key the sender must actually hold, so it leads,
        // and the forgeable fields are labelled as claims rather than facts.
        let code = Self.fingerprint(forPublicKeyBase64: request.devicePublicKey)
        // Disclose the same normalized set that pairing will actually grant.
        // Older clients may send an empty list, which intentionally maps to
        // the current supported companion capability set.
        let requestedAccess = Self.grantedCapabilities(for: request.requestedCapabilities)
            .map(Self.userFacingCapabilityName)
            .map { "    • \($0)" }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow a device to control this Mac?"
        alert.informativeText = """
        Check that this code matches the one on the device asking:

            \(code)

        The device calls itself “\(request.deviceName)” (\(request.platform)). \
        That name is chosen by the device and is not verified — only the code is.

        If allowed, this device can:
        \(requestedAccess)

        If the codes do not match, deny: something else on your network is asking.
        """
        alert.addButton(withTitle: "Allow Pairing")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func userFacingCapabilityName(_ capability: String) -> String {
        switch capability {
        case DeckBridgeCapability.screenPreview:
            return "View this Mac's screen"
        case DeckBridgeCapability.inputTrackpad:
            return "Move, click, and scroll the pointer"
        case DeckBridgeCapability.deckPerform:
            return "Run companion deck actions"
        case DeckBridgeCapability.deckRead:
            return "Read the companion deck and Mac status"
        default:
            return capability
        }
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsData = Array(lhs.utf8)
        let rhsData = Array(rhs.utf8)
        guard lhsData.count == rhsData.count else { return false }
        var diff: UInt8 = 0
        for index in lhsData.indices {
            diff |= lhsData[index] ^ rhsData[index]
        }
        return diff == 0
    }
}

private extension ISO8601DateFormatter {
    static let latticesBridge: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, isEmpty == false else { return [self] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<next]))
            index = next
        }
        return chunks
    }
}
