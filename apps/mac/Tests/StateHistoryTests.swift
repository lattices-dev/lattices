import XCTest
@testable import Lattices

final class StateHistoryTests: XCTestCase {
    private func map(frame x: Double = 0, title: String = "a", name: String? = nil, layer: Int? = 0) -> StateMap {
        StateMap(
            id: StateMap.id(for: Date(timeIntervalSince1970: 0), name: name),
            taken: Date(),
            name: name,
            displays: [.init(id: "U32", name: "U32", frame: .init(x: 0, y: 0, w: 3840, h: 2160), main: true, desktops: [1, 5], current: 1)],
            windows: [.init(wid: 7, app: "Ghostty", bundleId: nil, title: title, session: nil,
                            frame: .init(x: x, y: 0, w: 800, h: 600), desktops: [1], hidden: false)],
            layer: layer
        )
    }

    func testTitlesDoNotChangeTheArrangement() {
        XCTAssertEqual(map(title: "a").fingerprint, map(title: "b").fingerprint)
    }

    func testMovesDo() {
        XCTAssertNotEqual(map(frame: 0).fingerprint, map(frame: 40).fingerprint)
    }

    func testIdsSortByTimeAndCarryTheName() {
        let a = StateMap.id(for: Date(timeIntervalSince1970: 100))
        let b = StateMap.id(for: Date(timeIntervalSince1970: 200), name: "Before Lend!")
        XCTAssertEqual(a.count, 19)
        XCTAssertTrue(b.hasSuffix("-before-lend-"))
        XCTAssertLessThan(a, b)
    }

    func testExpiryDropsOldThenOldestUnnamedPastTheCap() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = StateMap.id(for: now.addingTimeInterval(-80 * 3600))
        let recent = (1...5).map { StateMap.id(for: now.addingTimeInterval(Double(-$0 * 60))) }
        let named = StateMap.id(for: now.addingTimeInterval(-3600), name: "keep")
        let drop = StateHistory.expired([old, named] + recent, now: now, cap: 4)
        XCTAssertTrue(drop.contains(old))
        XCTAssertFalse(drop.contains(named))
        XCTAssertEqual(Set(drop), Set([old, recent[4], recent[3]]))
    }

    func testRoundTrips() throws {
        let m = map(name: "x")
        let back = try StateHistory.decoder.decode(StateMap.self, from: StateHistory.encoder.encode(m))
        XCTAssertEqual(back.fingerprint, m.fingerprint)
        XCTAssertEqual(back.name, "x")
    }

    func testDurations() {
        XCTAssertEqual(StateHistory.duration("90"), 90)
        XCTAssertEqual(StateHistory.duration("30m"), 1800)
        XCTAssertEqual(StateHistory.duration("2h"), 7200)
        XCTAssertNil(StateHistory.duration("soon"))
    }

    func testLayerFocusOffRoundTripsWithoutRememberedSelection() throws {
        let snapshot = map(layer: nil)
        let restored = try StateHistory.decoder.decode(StateMap.self, from: StateHistory.encoder.encode(snapshot))
        XCTAssertNil(restored.layer)
        XCTAssertNotEqual(snapshot.fingerprint, map(layer: 0).fingerprint)
    }
}
