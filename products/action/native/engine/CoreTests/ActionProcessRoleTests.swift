@testable import ActionCore
import Darwin
import XCTest

final class ActionProcessRoleTests: XCTestCase {
    func testLauncherQuitPreservesIndependentOwners() {
        let exe = "/Applications/Action.app/Contents/MacOS/Action"
        XCTAssertTrue(ActionProcessRole.isLauncher([exe]))
        XCTAssertTrue(ActionProcessRole.isLauncher([exe, "-psn_0_123"]))
        XCTAssertTrue(ActionProcessRole.isLauncher([exe, "launcher"]))
        for role in ["agent-display", "agent-layer", "record-region", "agent", "drape", "quit-app"] {
            XCTAssertFalse(ActionProcessRole.isLauncher([exe, role]))
        }
        XCTAssertFalse(ActionProcessRole.isLauncher(nil))
        XCTAssertFalse(ActionProcessRole.isLauncher([]))
    }

    func testKernelArgumentsKeepSpacesAndExcludeEnvironment() {
        let args = ["/A path/Action.app/Contents/MacOS/Action", "agent-display", "--workspace", "agent"]
        var count = Int32(args.count)
        var data = Data(bytes: &count, count: 4)
        data.append(Data((args[0] + "\0\0\0" + args.joined(separator: "\0") + "\0TOKEN=private\0").utf8))
        XCTAssertEqual(ActionProcessRole.decode(data), args)
        XCTAssertNil(ActionProcessRole.decode(data.prefix(8)))
    }

    func testReadsLiveProcessArguments() {
        let args = ActionProcessRole.arguments(pid: getpid())
        XCTAssertNotNil(args)
        XCTAssertFalse(args?.isEmpty ?? true)
        XCTAssertFalse(ActionProcessRole.isLauncher(args))
    }
}
