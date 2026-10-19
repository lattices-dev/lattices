import Foundation

/// Preserve an existing device approval when upgrading a config that predates
/// the mobile-access switch. This policy only reads supplied data; it never
/// creates a host identity, migrates credentials, or rewrites configuration.
public enum BlinkMobileAccessPolicy {
    public static func resolve(
        configuration: Data?,
        hasHomeOverride: Bool,
        readApprovedPeers: () throws -> Data?
    ) -> Bool {
        do {
            let intent = try JSONDecoder().decode(
                Configuration.self,
                from: configuration ?? Data("{}".utf8)
            )
            if let explicit = intent.mobileAccess { return explicit }
            // A scratch home must never consult the production trust store.
            guard !hasHomeOverride, let data = try readApprovedPeers() else { return false }
            let peers = try JSONDecoder().decode([BlinkTrustedPeer].self, from: data)
            return !peers.isEmpty && peers.allSatisfy { !$0.id.isEmpty }
        } catch {
            // Invalid intent or unavailable/malformed credentials cannot opt in.
            return false
        }
    }

    private struct Configuration: Decodable {
        let mobileAccess: Bool?
        private enum CodingKeys: String, CodingKey { case behavior }
        private enum BehaviorKeys: String, CodingKey { case mobileAccess }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: CodingKeys.self)
            guard root.contains(.behavior) else {
                mobileAccess = nil
                return
            }
            let behavior = try root.nestedContainer(keyedBy: BehaviorKeys.self, forKey: .behavior)
            // Only an absent key can inherit. null and other non-Boolean values
            // are invalid, even if the machine has approved devices.
            mobileAccess = behavior.contains(.mobileAccess)
                ? try behavior.decode(Bool.self, forKey: .mobileAccess)
                : nil
        }
    }
}
