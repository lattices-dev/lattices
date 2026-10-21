@testable import BlinkPeer
import Foundation
import Testing

@Suite("Canvas mobile access upgrade compatibility")
struct BlinkMobileAccessPolicyTests {
    private let approved = Data("""
        [{"id":"approved-device-fixture","name":"Test phone","approvedAt":0}]
        """.utf8)

    @Test("explicit on and off never consult stored credentials")
    func explicitChoices() {
        for enabled in [false, true] {
            for customHome in [false, true] {
                var reads = 0
                let configuration = Data("{\"behavior\":{\"mobileAccess\":\(enabled)}}".utf8)
                let result = BlinkMobileAccessPolicy.resolve(
                    configuration: configuration,
                    hasHomeOverride: customHome
                ) {
                    reads += 1
                    return approved
                }
                #expect(result == enabled)
                #expect(reads == 0)
            }
        }
    }

    @Test("absent settings retain existing approvals without modifying config bytes")
    func legacyConfiguration() {
        for json in ["{}", "{\"behavior\":{\"restoreSession\":false}}", "{\"custom\":\"retained\"}"] {
            let configuration = Data(json.utf8)
            var reads = 0
            #expect(BlinkMobileAccessPolicy.resolve(configuration: configuration, hasHomeOverride: false) {
                reads += 1
                return approved
            })
            #expect(reads == 1)
            #expect(configuration == Data(json.utf8))
        }
        #expect(BlinkMobileAccessPolicy.resolve(configuration: nil, hasHomeOverride: false) { approved })
    }

    @Test("custom homes never read production credentials for absent settings")
    func customHomes() {
        for configuration in [nil, Data("{}".utf8), Data("{\"behavior\":{}}".utf8)] {
            var reads = 0
            #expect(!BlinkMobileAccessPolicy.resolve(configuration: configuration, hasHomeOverride: true) {
                reads += 1
                return approved
            })
            #expect(reads == 0)
        }
    }

    @Test("new installs, empty or malformed trust, and lookup failures remain off")
    func unavailableTrust() {
        let invalid: [Data?] = [
            nil, Data("[]".utf8), Data("not-json".utf8), Data("{}".utf8),
            Data("[{\"id\":\"\",\"name\":\"Test\",\"approvedAt\":0}]".utf8),
            Data("[{\"id\":\"fixture\",\"name\":\"Test\"}]".utf8),
        ]
        for data in invalid {
            #expect(!BlinkMobileAccessPolicy.resolve(configuration: nil, hasHomeOverride: false) { data })
        }
        struct LookupFailure: Error {}
        #expect(!BlinkMobileAccessPolicy.resolve(configuration: Data("{}".utf8), hasHomeOverride: false) {
            throw LookupFailure()
        })
    }

    @Test("malformed explicit intent never inherits even when approvals exist")
    func malformedIntent() {
        for json in [
            "{\"behavior\":{\"mobileAccess\":null}}", "{\"behavior\":{\"mobileAccess\":\"true\"}}",
            "{\"behavior\":{\"mobileAccess\":1}}", "{\"behavior\":null}",
            "{\"behavior\":[]}", "[]", "not-json",
        ] {
            var reads = 0
            #expect(!BlinkMobileAccessPolicy.resolve(configuration: Data(json.utf8), hasHomeOverride: false) {
                reads += 1
                return approved
            })
            #expect(reads == 0)
        }
    }

    @Test("a saved effective choice stays explicit when available approvals change")
    func savedChoicesStayStable() throws {
        struct SavedConfig: Encodable {
            struct Behavior: Encodable { let mobileAccess: Bool }
            let behavior: Behavior
        }
        for originalPeers in [nil, approved] {
            let enabled = BlinkMobileAccessPolicy.resolve(configuration: Data("{}".utf8), hasHomeOverride: false) {
                originalPeers
            }
            let saved = try JSONEncoder().encode(SavedConfig(behavior: .init(mobileAccess: enabled)))
            var reads = 0
            let reloaded = BlinkMobileAccessPolicy.resolve(configuration: saved, hasHomeOverride: false) {
                reads += 1
                return originalPeers == nil ? approved : nil
            }
            #expect(reloaded == enabled)
            #expect(reads == 0)
        }
    }
}
