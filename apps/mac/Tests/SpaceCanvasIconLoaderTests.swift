import XCTest
@testable import Lattices

final class SpaceCanvasIconLoaderTests: XCTestCase {
    @MainActor
    func testSlowIconLookupDoesNotBlockCanvasAndCoalescesWindowIcons() async throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let entered = expectation(description: "Lookup started off main")
        entered.assertForOverFulfill = true
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let loader = SpaceCanvasIconLoader { pid in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(pid, 42)
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return image
        }
        let first = CALayer(), second = CALayer()
        first.frame = CGRect(x: 7, y: 3, width: 14, height: 14)
        loader.load(pid: 42, into: first)
        loader.load(pid: 42, into: second)
        // These calls return while IconServices is still blocked, leaving the
        // input thread free and the reserved geometry intact.
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNil(first.contents)
        XCTAssertNil(second.contents)
        gate.signal()
        for _ in 0..<100 where second.contents == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(first.contents as AnyObject? === image)
        XCTAssertTrue(second.contents as AnyObject? === image)
        XCTAssertEqual(first.frame, CGRect(x: 7, y: 3, width: 14, height: 14))
        XCTAssertTrue(first.animationKeys()?.isEmpty ?? true)
        let cached = CALayer()
        loader.load(pid: 42, into: cached)
        XCTAssertTrue(cached.contents as AnyObject? === image)
    }

    @MainActor
    func testClosingCanvasDoesNotRetainZonesOrDeliverLateIcon() async {
        let entered = expectation(description: "Lookup started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var loader: SpaceCanvasIconLoader? = SpaceCanvasIconLoader { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return nil
        }
        var zone: CALayer? = CALayer()
        weak var releasedZone = zone
        weak var releasedLoader = loader
        loader?.load(pid: 42, into: zone!)
        await fulfillment(of: [entered], timeout: 2)
        zone = nil
        loader = nil
        XCTAssertNil(releasedZone, "An icon result must not keep an obsolete zone alive")
        XCTAssertNil(releasedLoader, "An in-flight lookup must not keep the canvas session alive")
    }
}
