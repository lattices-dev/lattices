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
}
