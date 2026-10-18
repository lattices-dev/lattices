import XCTest
@testable import Lattices

final class RemoteHostsConfigTests: XCTestCase {
    func testHostsFileThenEnvironmentLikeTheCLI() {
        let config = Data(#"{"hosts":{"local":{},"archie":{"address":"archie"},"box":{"address":"100.64.0.9","port":9500}}}"#.utf8)
        let hosts = RemoteHostsModel.configuredHosts(config: config, env: "spare, box=10.0.0.2:9401")
        XCTAssertEqual(hosts.map(\.name), ["archie", "spare", "box"])
        XCTAssertEqual(hosts[0].address, "archie")
        XCTAssertEqual(hosts[0].port, 9399)
        XCTAssertEqual(hosts[1].address, "spare")
        XCTAssertEqual(hosts[2].address, "10.0.0.2")
        XCTAssertEqual(hosts[2].port, 9401)
    }

    func testNoConfigMeansNoHosts() {
        XCTAssertTrue(RemoteHostsModel.configuredHosts(config: nil, env: nil).isEmpty)
        XCTAssertTrue(RemoteHostsModel.configuredHosts(config: Data("not json".utf8), env: "").isEmpty)
    }

    private func paired(_ name: String, _ address: String) -> VisitTrust.Host {
        .init(name: name, address: address, side: .left, bridgePublicKey: "key",
              bridgeFingerprint: "fingerprint", capabilities: [], pairedAt: .distantPast)
    }

    func testPairedOnlyTunnelsNeverSynthesizeALocalDaemonConnection() {
        let pairings = ["127.0.0.1:5288", "127.0.1.1:5288", "localhost:5288", "[::1]:5288",
                        "localhost.:5288", "[0:0:0:0:0:0:0:1]:5288", "[::ffff:127.12.34.56]:5288"]
            .enumerated().map { paired("remote-\($0.offset)", $0.element) }
        XCTAssertTrue(RemoteHostsModel.connectionHosts(configured: [], paired: pairings).isEmpty)
    }

    func testTunnelPairingKeepsExplicitRemoteOrForwardedDaemonEndpoint() {
        let pairings = [paired("archie", "127.0.0.1:5288")]
        for address in ["archie.tailnet", "127.0.0.1"] {
            let hosts = RemoteHostsModel.connectionHosts(
                configured: [(name: "archie", address: address, port: 19400)], paired: pairings)
            XCTAssertEqual(hosts.count, 1)
            XCTAssertEqual(hosts.first?.address, address)
            XCTAssertEqual(hosts.first?.port, 19400)
        }
        let aliases = RemoteHostsModel.connectionHosts(
            configured: [(name: "linux", address: "archie.tailnet", port: 9399)], paired: pairings)
        XCTAssertEqual(aliases.map(\.name), ["linux"])
    }

    func testDirectPairingsAddRemoteDaemonsAndRespectConfiguredAliases() {
        let hosts = RemoteHostsModel.connectionHosts(
            configured: [(name: "box", address: "100.64.0.9", port: 9401)],
            paired: [paired("alias", "100.64.0.9:5287"), paired("spare", "spare.local:5287")])
        XCTAssertEqual(hosts.map(\.name), ["box", "spare"])
        XCTAssertEqual(hosts.map(\.port), [9401, 9399])
        XCTAssertEqual(hosts.last?.address, "spare.local")
    }
}
