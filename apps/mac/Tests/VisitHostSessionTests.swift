import XCTest
@testable import Lattices

final class VisitHostSessionTests: XCTestCase {
    func session() -> VisitHostSession { .init(displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)]) }
    func testEnterMoveExitAndRelease() throws {
        var s = session()
        let effects = try s.handle(["t": "enter", "name": "mini", "edge": "left", "at": 0.5])
        XCTAssertEqual(effects.last, .reply("ready", nil, nil))
        XCTAssertEqual(s.position?.x, 2)
        _ = try s.handle(["t": "button", "button": "left", "down": true])
        let exit = try s.handle(["t": "move", "dx": -10.0, "dy": 0.0])
        XCTAssertEqual(exit.first, .reply("exit", "left", 399.5 / 800))
        XCTAssertTrue(exit.contains(.button("left", false, CGPoint(x: 2, y: 399.5))))
        XCTAssertNil(s.position); XCTAssertTrue(s.held.isEmpty)
    }
    func testOtherEdgesClampAndGapsStayOnRealScreens() throws {
        var s = VisitHostSession(displays: [CGRect(x: -1000, y: 0, width: 500, height: 800), CGRect(x: 0, y: 0, width: 1000, height: 800)])
        _ = try s.handle(["t": "enter", "name": "a", "edge": "left", "at": 0.0])
        _ = try s.handle(["t": "move", "dx": 800.0, "dy": 2000.0])
        XCTAssertTrue(s.displays.contains { $0.contains(s.position!) })
        XCTAssertNotNil(s.position)
    }
    func testValidationAndHeartbeat() throws {
        var s = session()
        XCTAssertEqual(try s.handle(["t": "ping"]), [.reply("pong", nil, nil)])
        XCTAssertThrowsError(try s.handle(["t": "move", "dx": 1, "dy": 1]))
        XCTAssertThrowsError(try s.handle(["t": "enter", "name": "a", "edge": "left", "at": 2.0]))
        _ = try s.handle(["t": "enter", "name": "a", "edge": "right", "at": 0.5])
        XCTAssertThrowsError(try s.handle(["t": "move", "dx": Double.nan, "dy": 0.0]))
        XCTAssertThrowsError(try s.handle(["t": "button", "button": "bad", "down": true]))
        XCTAssertThrowsError(try s.handle(["t": "key", "key": "a", "mods": ["bad"]]))
        XCTAssertEqual(try s.handle(["t": "text", "text": "hello"]), [.text("hello")])
        XCTAssertEqual(try s.handle(["t": "leave"]).last, .end)
    }
}
