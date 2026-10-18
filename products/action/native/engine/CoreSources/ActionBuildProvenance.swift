import Foundation

/// Build identity belongs to the signed bundle, never the invoking checkout.
public struct ActionBuildProvenance: Codable, Sendable {
    public struct Build: Codable, Sendable {
        public let version: String
        public let commit: String
        public let sourceDigest: String
        public let sourceScope: String
        public let builtAt: String
        public let dirty: Bool
        public let configuration: String
        public var bundleBuild: String? = nil
        public var orchestrationSourceDigest: String? = nil
    }
    public struct Features: Codable, Sendable {
        public let privateLayer: Bool
        public var isolationContext: Bool? = nil
        public var persistentAgentDisplay: Bool? = nil
        public var namedWorkspaces: Bool? = nil
        public var previewDestination: Bool? = nil
    }
    public struct Routing: Codable, Sendable {
        public let nativeHost: String
        public let privateLayerWorkflow: String
        public let rawWebSocket: String
    }
    public let schemaVersion: Int
    public let build: Build?
    public let features: Features
    public let routing: Routing
    public var isolationGate: ActionLayerSafetyGate.State? = nil

    public static func load(resourceURL: URL?) -> ActionBuildProvenance {
        if let resourceURL,
           let data = try? Data(contentsOf: resourceURL.appendingPathComponent("build-provenance.json")),
           let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value
        }
        // Unbundled development binaries must not invent build identity.
        return Self(schemaVersion: 1, build: nil, features: Features(privateLayer: true), routing: routingContract)
    }

    public static var current: ActionBuildProvenance {
        var value = load(resourceURL: Bundle.main.resourceURL)
        value.isolationGate = ActionLayerSafetyGate.read()
        return value
    }

    public static var routingContract: Routing {
        Routing(nativeHost: "agent-display owns each named persistent monitor; agent-layer attaches a workspace task without display reconfiguration and explicitly targets its preview display",
                privateLayerWorkflow: "Use Action MCP action.layer.open/snapshot/click/type/js/close; browser control is MCP orchestration over CDP, not raw WebSocket",
                rawWebSocket: "status.methods lists only raw agent RPCs; it is not the complete CLI/MCP capability catalog")
    }

    public var json: String {
        guard let data = try? JSONEncoder().encode(self), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
