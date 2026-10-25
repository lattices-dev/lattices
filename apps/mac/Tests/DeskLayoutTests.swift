import XCTest
@testable import Lattices

final class DeskLayoutTests: XCTestCase {
    private let dell = "dell s3422dwg|3kn2kk3"
    private let samsung = "u32j59x|hcry300398"
    private let alienware = "aw3425dwm|jwlc444"

    private func mini() -> DeskLayout.Host {
        DeskLayout.Host(name: "mini", displays: [
            .init(key: dell, model: "DELL S3422DWG", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), widthMm: 800, heightMm: 335),
            .init(key: samsung, model: "U32J59x", frame: CGRect(x: -3840, y: -396, width: 3840, height: 2160), widthMm: 698, heightMm: 393),
            .init(key: nil, model: "Action Agent Layer", frame: CGRect(x: 4000, y: 0, width: 1920, height: 1080)),
        ])
    }

    private func artsMini(samsungLeft: Bool = false) -> DeskLayout.Host {
        DeskLayout.Host(name: "arts-mini", displays: [
            .init(key: alienware, model: "AW3425DWM", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), widthMm: 800, heightMm: 335),
            .init(key: samsung, model: "U32J59x",
                  frame: CGRect(x: samsungLeft ? -3840 : 3440, y: 235, width: 3840, height: 2160)),
        ])
    }

    private func archie() -> DeskLayout.Host {
        DeskLayout.Host(name: "archie", displays: [
            .init(key: alienware, model: "AW3425DWM", frame: CGRect(x: 0, y: 0, width: 3440, height: 1440)),
        ])
    }

    func testStitchesTheLiveDeskLeftToRight() throws {
        let desk = DeskLayout.stitch(hosts: [mini(), artsMini(), archie()])
        XCTAssertEqual(desk.monitors.map(\.key), [dell, samsung, alienware])
        let aw = try XCTUnwrap(desk.monitor(alienware)), u32 = try XCTUnwrap(desk.monitor(samsung))
        let s34 = try XCTUnwrap(desk.monitor(dell))
        XCTAssertEqual(aw.rect.maxX, u32.rect.minX, accuracy: 0.01)
        XCTAssertEqual(u32.rect.maxX, s34.rect.minX, accuracy: 0.01)
        XCTAssertEqual(desk.monitors.sorted { $0.origin.x < $1.origin.x }.map(\.key), [alienware, samsung, dell])
        XCTAssertEqual(desk.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(desk.bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(aw.hosts, ["arts-mini", "archie"])
        XCTAssertEqual(u32.hosts, ["mini", "arts-mini"])
        XCTAssertEqual(u32.size, CGSize(width: 698, height: 393))
        XCTAssertTrue(desk.monitors.allSatisfy { $0.source == .derived })
        XCTAssertEqual(desk.mismatches, [:])
    }

    func testOffsetsTheCrossAxisInMillimetres() throws {
        let desk = DeskLayout.stitch(hosts: [mini()])
        let u32 = try XCTUnwrap(desk.monitor(samsung)), s34 = try XCTUnwrap(desk.monitor(dell))
        // The Samsung's top sits 396 points above the Dell's: 396 × 335/1440 mm.
        XCTAssertEqual(s34.origin.y - u32.origin.y, 396 * 335 / 1440, accuracy: 0.01)
    }

    func testDerivesASizeWithoutEDID() throws {
        let desk = DeskLayout.stitch(hosts: [archie()])
        let aw = try XCTUnwrap(desk.monitor(alienware))
        XCTAssertEqual(aw.size.width, 3440 * DeskLayout.mmPerPoint, accuracy: 0.01)
        XCTAssertEqual(aw.size.height, 1440 * DeskLayout.mmPerPoint, accuracy: 0.01)
        let wide = DeskLayout.stitch(hosts: [DeskLayout.Host(name: "h", displays: [
            .init(key: "k", frame: CGRect(x: 0, y: 0, width: 2000, height: 1000), widthMm: 600),
        ])])
        XCTAssertEqual(wide.monitors[0].size, CGSize(width: 600, height: 300))
    }

    func testReportsAHostArrangedDifferentlyFromTheDesk() throws {
        // arts-mini claims the Samsung is left of the Alienware; the user has
        // placed the monitors as they stand on the desk.
        let truth = DeskLayout.stitch(hosts: [mini(), artsMini(), archie()])
        let origins = Dictionary(uniqueKeysWithValues: truth.monitors.map {
            ($0.key, CGPoint(x: $0.origin.x - truth.shift.x, y: $0.origin.y - truth.shift.y))
        })
        let desk = DeskLayout.stitch(hosts: [mini(), artsMini(samsungLeft: true), archie()], origins: origins)
        XCTAssertEqual(desk.mismatches, ["arts-mini": [DeskLayout.Pair(a: alienware, b: samsung)]])
        XCTAssertNil(desk.mismatches["mini"])
        XCTAssertNil(desk.mismatches["archie"])
    }

    func testUserOriginWins() throws {
        let desk = DeskLayout.stitch(hosts: [mini(), artsMini(), archie()], origins: [alienware: CGPoint(x: 5000, y: 40)])
        let aw = try XCTUnwrap(desk.monitor(alienware))
        XCTAssertEqual(aw.origin, CGPoint(x: 5000 + desk.shift.x, y: 40 + desk.shift.y))
        XCTAssertEqual(aw.source, .user)
        XCTAssertEqual(desk.monitor(samsung)?.source, .derived)
        // Now right of the Dell on the desk, unlike arts-mini.
        XCTAssertEqual(desk.mismatches["arts-mini"], [DeskLayout.Pair(a: alienware, b: samsung)])
    }

    func testPlacesADisconnectedGroupToTheRight() throws {
        let lone = DeskLayout.Host(name: "air", displays: [
            .init(key: "lg|1", model: "LG", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), widthMm: 600, heightMm: 340),
        ])
        let desk = DeskLayout.stitch(hosts: [mini(), lone])
        let s34 = try XCTUnwrap(desk.monitor(dell)), lg = try XCTUnwrap(desk.monitor("lg|1"))
        XCTAssertEqual(lg.origin.x, s34.rect.maxX + DeskLayout.gap, accuracy: 0.01)
        XCTAssertEqual(lg.origin.y, desk.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(desk.bounds.origin, .zero)
    }

    func testPlacesARowOfThreeSideBySide() throws {
        let row = DeskLayout.Host(name: "h", displays: (0..<3).map {
            .init(key: "m\($0)", frame: CGRect(x: CGFloat($0) * 1000, y: 0, width: 1000, height: 500))
        })
        let desk = DeskLayout.stitch(hosts: [row])
        let xs = desk.monitors.map(\.origin.x)
        XCTAssertEqual(xs[0], 0, accuracy: 0.01)
        XCTAssertEqual(xs[1], 230, accuracy: 0.01)
        XCTAssertEqual(xs[2], 460, accuracy: 0.01)
    }

    func testCarriesAGapBetweenDisplays() throws {
        let gapped = DeskLayout.Host(name: "h", displays: [
            .init(key: "a", frame: CGRect(x: 0, y: 0, width: 1000, height: 500)),
            .init(key: "b", frame: CGRect(x: 1500, y: 0, width: 1000, height: 500)),
        ])
        let desk = DeskLayout.stitch(hosts: [gapped])
        XCTAssertEqual(try XCTUnwrap(desk.monitor("b")).origin.x, 345, accuracy: 0.01)
    }

    func testDraggedMonitorKeepsItsPlaceWhenAHostJoinsOnTheLeft() throws {
        // Dragged with only mini known, then arts-mini and archie add the Alienware on the left.
        let alone = DeskLayout.stitch(hosts: [mini()])
        let s34 = try XCTUnwrap(alone.monitor(dell))
        let stored = CGPoint(x: s34.origin.x + 5 - alone.shift.x, y: s34.origin.y - alone.shift.y)
        let desk = DeskLayout.stitch(hosts: [mini(), artsMini(), archie()], origins: [dell: stored])
        let moved = try XCTUnwrap(desk.monitor(dell)), u32 = try XCTUnwrap(desk.monitor(samsung))
        XCTAssertEqual(moved.origin.x, u32.rect.maxX + 5, accuracy: 0.01)
        XCTAssertNil(desk.mismatches["mini"])
        XCTAssertEqual(desk.bounds.origin, .zero)
    }

    func testSideTakesTheDominantAxisWhenFramesOverlap() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(DeskLayout.side(a, CGRect(x: 100, y: 50, width: 100, height: 100)), .right)
        XCTAssertEqual(DeskLayout.side(a, CGRect(x: -100, y: 0, width: 100, height: 100)), .left)
        XCTAssertEqual(DeskLayout.side(a, CGRect(x: 10, y: 100, width: 100, height: 100)), .below)
        XCTAssertEqual(DeskLayout.side(a, CGRect(x: 20, y: -80, width: 100, height: 100)), .above)
        XCTAssertEqual(DeskLayout.side(a, CGRect(x: 60, y: 10, width: 100, height: 100)), .right)
    }

    func testStorePersistsOriginsUntilReset() {
        let defaults = UserDefaults(suiteName: "DeskLayoutTests.\(UUID().uuidString)")!
        let store = DeskStore(defaults: defaults)
        XCTAssertTrue(store.origins.isEmpty)
        store.set(alienware, origin: CGPoint(x: 12, y: 34))
        XCTAssertEqual(DeskStore(defaults: defaults).origins, [alienware: CGPoint(x: 12, y: 34)])
        let json = try? JSONSerialization.jsonObject(with: defaults.data(forKey: "desk.layout") ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 2)
        store.reset()
        XCTAssertTrue(DeskStore(defaults: defaults).origins.isEmpty)
    }

    func testAPinnedMapHoldsWhenAHostDropsOff() throws {
        // One move saves every monitor as drawn; archie then going away moves nothing.
        let full = DeskLayout.stitch(hosts: [mini(), artsMini(), archie()])
        let pinned = Dictionary(uniqueKeysWithValues: full.monitors.map {
            ($0.key, CGPoint(x: $0.origin.x - full.shift.x, y: $0.origin.y - full.shift.y))
        })
        let defaults = UserDefaults(suiteName: "DeskLayoutTests.\(UUID().uuidString)")!
        DeskStore(defaults: defaults).set(pinned)
        let later = DeskLayout.stitch(hosts: [mini(), artsMini()], origins: DeskStore(defaults: defaults).origins)
        for m in full.monitors {
            let now = try XCTUnwrap(later.monitor(m.key))
            XCTAssertEqual(now.origin.x, m.origin.x, accuracy: 0.01)
            XCTAssertEqual(now.origin.y, m.origin.y, accuracy: 0.01)
        }
    }
}
