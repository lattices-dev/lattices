import Foundation
import ActionCore

enum ActionAgentCLIError: LocalizedError {
    case missingMethod

    var errorDescription: String? {
        switch self {
        case .missingMethod:
            return "Missing method. Try: ping, status, app.launch, app.activate, input.drag, input.typeText, accessibility.pressElement, accessibility.setValue, calculator.buttons, calculator.clickButton, calculator.displayValue"
        }
    }
}

@main
struct ActionAgentCLIMain {
    static func main() async {
        do {
            let options = parse(arguments: CommandLine.arguments)
            let request = ActionAgentRequest(method: options.method, params: options.params)
            let response = try await send(request: request, port: options.port)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))

            if !response.ok {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("ActionAgentCLI failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func parse(arguments: [String]) -> (port: UInt16, method: String, params: [String: String]) {
        var port = ActionAgentDefaults.port
        var method: String?
        var params: [String: String] = [:]

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--port", let value = iterator.next(), let parsed = UInt16(value) {
                port = parsed
                continue
            }

            if argument == "--bundle-id", let value = iterator.next() {
                params["bundleId"] = value
                continue
            }

            if argument == "--text", let value = iterator.next() {
                params["text"] = value
                continue
            }

            if argument == "--label", let value = iterator.next() {
                params["label"] = value
                continue
            }

            if argument == "--role", let value = iterator.next() {
                params["role"] = value
                continue
            }

            if argument == "--value", let value = iterator.next() {
                params["value"] = value
                continue
            }

            if argument == "--output", let value = iterator.next() {
                params["output"] = value
                continue
            }

            if ["--stop-file", "--finished-file", "--debug-log", "--frame-timing-file"].contains(argument), let value = iterator.next() {
                let key = switch argument {
                case "--stop-file": "stopFile"
                case "--finished-file": "finishedFile"
                case "--frame-timing-file": "frameTimingFile"
                default: "debugLog"
                }
                params[key] = value
                continue
            }

            if ["--x", "--y", "--width", "--height"].contains(argument), let value = iterator.next() {
                params[String(argument.dropFirst(2))] = value
                continue
            }

            if ["--from-x", "--from-y", "--to-x", "--to-y", "--duration-ms"].contains(argument), let value = iterator.next() {
                let key = switch argument {
                case "--from-x": "fromX"
                case "--from-y": "fromY"
                case "--to-x": "toX"
                case "--to-y": "toY"
                default: "durationMs"
                }
                params[key] = value
                continue
            }

            if argument == "--file-path", let value = iterator.next() {
                params["filePath"] = value
                continue
            }

            if ["--fps", "--scale"].contains(argument), let value = iterator.next() {
                params[String(argument.dropFirst(2))] = value
                continue
            }

            if method == nil {
                method = argument
            }
        }

        return (port, method ?? "", params)
    }

    private static func send(request: ActionAgentRequest, port: UInt16) async throws -> ActionAgentResponse {
        guard !request.method.isEmpty else {
            throw ActionAgentCLIError.missingMethod
        }
        let client = ActionAgentClient(port: port)
        return try await client.send(request: request)
    }
}
