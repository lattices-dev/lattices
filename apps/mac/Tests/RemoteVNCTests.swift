import XCTest
import Network
@testable import Lattices

final class RemoteVNCTests: XCTestCase {
    func testForwardedGatewayDoesNotBecomeTheVNCAddress() {
        let linux = RemoteVNCSettings.initial(host: "archie", address: "127.0.0.1", platform: "linux")
        XCTAssertEqual(linux.address, "archie")
        XCTAssertTrue(linux.throughSSH)
        XCTAssertTrue(linux.startLinuxServer)
        let mac = RemoteVNCSettings.initial(host: "studio", address: "studio.local", platform: "macos")
        XCTAssertEqual(mac.address, "studio.local")
        XCTAssertFalse(mac.throughSSH)
    }

    func testVNCURLsSupportIPv6AndCannotContainCredentialsOrPaths() throws {
        XCTAssertEqual(try RemoteVNCSettings.url(address: "studio.local", port: 5901).absoluteString, "vnc://studio.local:5901")
        XCTAssertEqual(try RemoteVNCSettings.url(address: "::1", port: 5900).absoluteString, "vnc://[::1]:5900")
        XCTAssertEqual(try RemoteVNCSettings.url(address: "[::1]", port: 5900).absoluteString, "vnc://[::1]:5900")
        for address in ["", "user:password@host", "vnc://host", "host/path", "host?query", "host#fragment", "host name"] {
            XCTAssertThrowsError(try RemoteVNCSettings.url(address: address, port: 5900), address)
        }
    }

    func testSSHUsesLoopbackForwardingAndExistingTrust() throws {
        let settings = RemoteVNCSettings(address: "arach@archie", port: 5901, throughSSH: true, startLinuxServer: true)
        let args = try settings.sshArguments(localPort: 43210)
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("127.0.0.1:43210:127.0.0.1:5901"))
        XCTAssertEqual(args.last, "arach@archie")
        XCTAssertTrue(try settings.startCommand(displayIndex: 2).hasSuffix("'{\"port\":5901,\"displayIndex\":2}'"))
        XCTAssertThrowsError(try settings.startCommand(displayIndex: -1))
    }

    func testEditableAddressCannotInjectSSHOptionsOrShellCommands() {
        for address in ["-oProxyCommand=id", "host;id", "$(id)", "host\ncommand", "host name", "host/path", "user:password@host"] {
            let settings = RemoteVNCSettings(address: address, throughSSH: true, startLinuxServer: true)
            XCTAssertThrowsError(try settings.sshArguments(), address)
        }
        for port in [0, -1, 65536] {
            let settings = RemoteVNCSettings(address: "archie", port: port, throughSSH: true, startLinuxServer: true)
            XCTAssertThrowsError(try settings.sshArguments())
        }
    }

    @MainActor
    func testPreferencesDoNotConfuseGatewayAndVNCTransport() throws {
        let suite = "RemoteVNCTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = RemoteVNCSettings(address: "vnc.example", port: 5902, throughSSH: false, startLinuxServer: false)
        defaults.set(try JSONEncoder().encode(["archie": saved]), forKey: "remoteView.vnc.connections")
        let connections = RemoteVNCConnections(defaults: defaults)
        XCTAssertEqual(connections.settings(host: "archie", address: "127.0.0.1", platform: "linux"), saved)
        XCTAssertEqual(connections.settings(host: "other", address: "127.0.0.1", platform: "linux").address, "other")
    }

    @MainActor
    func testFailedDirectConnectionDoesNotOpenScreenSharingOrReplaceSavedSSHSettings() async throws {
        let port = try await server(fragments: ["HTTP/1.1 200 OK\r\n"])
        let suite = "RemoteVNCTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = RemoteVNCSettings(address: "archie", throughSSH: true, startLinuxServer: true)
        defaults.set(try JSONEncoder().encode(["archie": saved]), forKey: "remoteView.vnc.connections")
        var opened = false
        let connections = RemoteVNCConnections(defaults: defaults, openURL: { _ in opened = true; return true })
        let direct = RemoteVNCSettings(address: "127.0.0.1", port: port, throughSSH: false, startLinuxServer: false)
        do {
            try await connections.connect(host: "archie", settings: direct, displayIndex: nil)
            XCTFail("An HTTP server is not a VNC server")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Through SSH")) }
        XCTAssertFalse(opened)
        XCTAssertEqual(connections.settings(host: "archie", address: "127.0.0.1", platform: "linux"), saved)
    }

    @MainActor
    func testDirectVNCOpensOnlyAfterReceivingCompleteFragmentedBanner() async throws {
        let port = try await server(fragments: ["RFB ", "003.", "008\n"])
        let suite = "RemoteVNCTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened: URL?
        let connections = RemoteVNCConnections(defaults: defaults, openURL: { opened = $0; return true })
        let direct = RemoteVNCSettings(address: "localhost", port: port, throughSSH: false, startLinuxServer: false)
        try await connections.connect(host: "fixture", settings: direct, displayIndex: nil)
        XCTAssertEqual(opened?.absoluteString, "vnc://localhost:\(port)")
        XCTAssertEqual(connections.settings(host: "fixture", address: "ignored", platform: nil), direct)
    }

    func testUnresponsiveVNCProbeTimesOutAndCanBeCancelled() async throws {
        let accepted = expectation(description: "probe connected")
        let port = try await server(fragments: [], accepted: accepted)
        let probe = Task { await RemoteVNCProbe.check(address: "127.0.0.1", port: port, timeout: 30) }
        await fulfillment(of: [accepted], timeout: 2)
        let start = Date()
        probe.cancel()
        let cancelled = await probe.value
        XCTAssertFalse(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        let timeoutPort = try await server(fragments: ["RFB "])
        let timedOut = await RemoteVNCProbe.check(address: "127.0.0.1", port: timeoutPort, timeout: 0.1)
        XCTAssertFalse(timedOut, "An incomplete RFB greeting must not pass readiness")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private func server(fragments: [String], accepted: XCTestExpectation? = nil) async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "vnc-test-server")
        let ready = expectation(description: "VNC fixture listening")
        var peers: [NWConnection] = []
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { peer in
            peers.append(peer)
            peer.start(queue: queue)
            accepted?.fulfill()
            for (index, fragment) in fragments.enumerated() {
                queue.asyncAfter(deadline: .now() + Double(index) * 0.02) {
                    peer.send(content: Data(fragment.utf8), completion: .contentProcessed { _ in })
                }
            }
        }
        listener.start(queue: queue)
        addTeardownBlock {
            listener.cancel()
            queue.sync { for peer in peers { peer.cancel() } }
        }
        await fulfillment(of: [ready], timeout: 3)
        return Int(try XCTUnwrap(listener.port).rawValue)
    }
}
