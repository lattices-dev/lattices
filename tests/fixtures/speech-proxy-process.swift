import Foundation

enum LatticesLocalEndpoints {
    static let speechCompanionSocketPath = "/unused/speech.sock"
    static let speechCompanionTokenURL = URL(fileURLWithPath: "/unused/speech.token")
    static let speechCompanionURL = URL(string: "ws://127.0.0.1:9397")!
}
@main
struct SpeechProxyProcess {
    static func main() async {
        guard CommandLine.arguments.count == 3, let endpoint = URL(string: CommandLine.arguments[1]) else { exit(2) }
        let client = SpeechCompanionConnection(endpoint: endpoint,
            tokenFile: URL(fileURLWithPath: CommandLine.arguments[2]), response: { result in
                guard result.id == "lifecycle-job" else { return }
                if let data = try? JSONEncoder().encode(result) { print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
                // Process exit closes the exact production client transport.
                exit(result.error == nil ? 0 : 1)
            }, event: { _ in })
        await client.forward(DaemonRequest(id: "lifecycle-job", method: "speech.enqueue",
            params: .object(["text": .string("Lifecycle acceptance probe"), "provider": .string("system")])))
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        await client.close()
        exit(3)
    }
}
