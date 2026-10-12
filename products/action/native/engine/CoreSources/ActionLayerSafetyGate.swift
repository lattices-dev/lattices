import Foundation

/// Machine-local quarantine for a confirmed desktop-isolation failure.
/// Missing means no quarantine; unreadable or malformed evidence fails closed.
public enum ActionLayerSafetyGate {
    public struct State: Codable, Sendable {
        public let blocked: Bool
        public let reason: String?
        public let path: String
    }

    private struct Policy: Decodable {
        let blocked: Bool
        let reason: String?
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Action/agent-layer/isolation-block.json")
    }

    public static func read(at url: URL? = nil) -> State {
        let url = url ?? defaultURL
        do {
            let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: url))
            return State(blocked: policy.blocked,
                         reason: policy.blocked ? (policy.reason ?? "Desktop isolation failed on this machine.") : nil,
                         path: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return State(blocked: false, reason: nil, path: url.path)
        } catch {
            return State(blocked: true,
                         reason: "Isolation quarantine could not be read or validated: \(error.localizedDescription)",
                         path: url.path)
        }
    }

    public static func refusal(for state: State) -> String? {
        guard state.blocked else { return nil }
        return "Private agent layer is blocked to protect the user desktop: \(state.reason ?? "isolation not verified") Policy: \(state.path). No virtual display was created. Repair and verify desktop isolation before clearing this quarantine. Do not bypass this gate through another transport or replace requested isolation with ordinary background browser opening."
    }
}
