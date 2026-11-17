import CoreGraphics
import XCTest
@testable import Lattices

@MainActor
final class SpaceCanvasAtlasTests: XCTestCase {
    func testCompleteMembershipKeepsStripBoundedAndPreservesStackingAndCrop() throws {
        let spaces = [SpaceInfo(id: 42, index: 1, display: 0, isCurrent: true),
                      SpaceInfo(id: 43, index: 2, display: 0, isCurrent: false)]
        let inventory = (1...10).reversed().map { index in
            WindowEntry(wid: UInt32(index), app: "App \(index)", pid: -1, title: "",
                frame: WindowFrame(x: index == 10 ? -100 : 100, y: 100, w: 500, h: 500),
                spaceIds: index == 10 ? [42, 43, 42] : [42], isOnScreen: false,
                latticesSession: nil, zIndex: index)
        }
        let cards = SpaceFilmstripLayout.cards(spaces: spaces, windows: inventory,
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(cards[0].windows.map(\.wid), [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(cards[0].allWindows.map(\.wid), (1...10).reversed().map(UInt32.init))
        XCTAssertEqual(cards[1].allWindows.map(\.wid), [10])
        let clipped = try XCTUnwrap(cards[0].allWindows.first)
        XCTAssertEqual(clipped.rect, CGRect(x: 0, y: 0.1, width: 0.4, height: 0.5))
        XCTAssertEqual(clipped.contentsRect, CGRect(x: 0.2, y: 0, width: 0.8, height: 1))
    }

    func testAtlasCapturesBeyondSixAndDeduplicatesSharedWindowsAtTileResolution() async throws {
        let fixture = AtlasCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: false)
        })
        let windows = (1...8).map { window(UInt32($0)) }
        let cards = [card(1, windows: windows), card(2, windows: [windows[0]])]
        var delivered = Set<CGWindowID>()
        loader.loadAtlas(cards: cards, visible: [0, 1], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = Set($0.keys) }
        for index in 0..<4 {
            let requests = try await fixture.waitForRequests(index + 1)
            XCTAssertEqual(requests[index].ids.count, 2)
            XCTAssertEqual(requests[index].maximum, 500)
            await fixture.finish(index, images: Dictionary(uniqueKeysWithValues:
                requests[index].ids.map { ($0, Self.image()) }))
        }
        try await quietTurn()
        let requests = await fixture.requests
        XCTAssertEqual(requests.flatMap(\.ids), Array(1...8).map(UInt32.init))
        XCTAssertEqual(delivered, Set(Array(1...8).map(UInt32.init)))
        loader.stop()
    }

    func testZoomingOutRestoresResidentAtlasAndDoesNotRecaptureIt() async throws {
        let fixture = AtlasCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: false)
        }, detailCapture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: true)
        })
        let cards = [card(1, windows: [window(11)]), card(2, windows: [window(12)])]
        let atlasImage = Self.image(width: 10, height: 6)
        let detailImage = Self.image(width: 100, height: 60)
        var delivered: SpaceCanvasPreviewLoader.Images = [:]
        loader.loadAtlas(cards: cards, visible: [0, 1], selected: 0,
            atlasPixelSize: CGSize(width: 500, height: 300),
            displayPixelSize: CGSize(width: 2000, height: 1200)) { delivered = $0 }
        _ = try await fixture.waitForRequests(1)
        await fixture.finish(0, images: [11: atlasImage, 12: atlasImage])
        let requests = try await fixture.waitForRequests(2)
        XCTAssertTrue(requests[1].detail)
        XCTAssertEqual(requests[1].ids, [11])
        await fixture.finish(1, images: [11: detailImage])
        try await quietTurn()
        XCTAssertTrue(delivered[11] === detailImage)
        loader.loadAtlas(cards: cards, visible: [0, 1], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        XCTAssertTrue(delivered[11] === atlasImage)
        XCTAssertTrue(delivered[12] === atlasImage)
        try await quietTurn()
        let finalRequests = await fixture.requests
        XCTAssertEqual(finalRequests.count, 2)
        loader.stop()
        XCTAssertEqual(loader.atlasCachedBytes, 0)
    }

    func testNarrowingViewportKeepsOutgoingResidentTilesWithoutRecapturing() async throws {
        let fixture = AtlasCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: false)
        })
        let cards = [card(1, windows: [window(11)]), card(2, windows: [window(12)])]
        let outgoing = Self.image()
        var delivered: SpaceCanvasPreviewLoader.Images = [:]
        loader.loadAtlas(cards: cards, visible: [0, 1], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        _ = try await fixture.waitForRequests(1)
        await fixture.finish(0, images: [11: Self.image(), 12: outgoing])
        try await quietTurn()
        loader.loadAtlas(cards: cards, visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        XCTAssertEqual(Set(delivered.keys), [11, 12])
        XCTAssertTrue(delivered[12] === outgoing, "outgoing tile keeps its photo throughout camera travel")
        try await quietTurn()
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)

        // Genuine inventory removal still clears the resident image.
        loader.loadAtlas(cards: [cards[0]], visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        XCTAssertEqual(Set(delivered.keys), [11])
        loader.stop()
    }

    func testReusedIdentityRejectsOldCaptureAndClosingRejectsLateResult() async throws {
        let fixture = AtlasCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: false)
        })
        var delivered: SpaceCanvasPreviewLoader.Images = [:]
        loader.loadAtlas(cards: [card(1, windows: [window(11, pid: 100)])], visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        _ = try await fixture.waitForRequests(1)
        loader.loadAtlas(cards: [card(1, windows: [window(11, pid: 200)])], visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 300)) { delivered = $0 }
        await fixture.finish(0, images: [11: Self.image()])
        _ = try await fixture.waitForRequests(2)
        XCTAssertTrue(delivered.isEmpty)
        loader.stop()
        await fixture.finish(1, images: [11: Self.image()])
        try await quietTurn()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(loader.atlasCachedBytes, 0)
    }

    func testOversizedCaptureResultsStayWithinBudgetWithoutEvictionChurn() async throws {
        let fixture = AtlasCapture()
        let loader = SpaceCanvasPreviewLoader(maximumBytes: 1536, capture: { ids, maximum in
            await fixture.capture(ids, maximum: maximum, detail: false)
        })
        let cards = [card(1, windows: (1...5).map { window(UInt32($0)) })]
        loader.loadAtlas(cards: cards, visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 500)) { _ in }
        for index in 0..<3 {
            let requests = try await fixture.waitForRequests(index + 1)
            await fixture.finish(index, images: Dictionary(uniqueKeysWithValues:
                requests[index].ids.map { ($0, Self.image(width: 8, height: 8)) }))
        }
        try await quietTurn()
        XCTAssertLessThanOrEqual(loader.atlasCachedBytes, 1024)
        loader.loadAtlas(cards: cards, visible: [0], selected: nil,
            atlasPixelSize: CGSize(width: 500, height: 500)) { _ in }
        try await quietTurn()
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        loader.stop()
    }

    private func card(_ id: Int, windows: [SpaceFilmstripWindow]) -> SpaceFilmstripCard {
        SpaceFilmstripCard(id: id, number: id, windows: Array(windows.suffix(6)), canvasWindows: windows)
    }
    private func window(_ id: UInt32, pid: Int32 = 100) -> SpaceFilmstripWindow {
        SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0, width: 1, height: 1), app: "Test", pid: pid, wid: id)
    }
    private static func image(width: Int = 2, height: Int = 2) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    private func quietTurn() async throws { try await Task.sleep(nanoseconds: 20_000_000) }
}

private actor AtlasCapture {
    struct Request {
        let ids: [CGWindowID]
        let maximum: CGFloat
        let detail: Bool
    }
    private(set) var requests: [Request] = []
    private var responses: [Int: CheckedContinuation<SpaceCanvasPreviewLoader.Images, Never>] = [:]
    func capture(_ ids: [CGWindowID], maximum: CGFloat, detail: Bool) async -> SpaceCanvasPreviewLoader.Images {
        await withCheckedContinuation { continuation in
            let index = requests.count
            requests.append(Request(ids: ids, maximum: maximum, detail: detail))
            responses[index] = continuation
        }
    }
    private enum FixtureError: Error { case requestTimedOut }
    func waitForRequests(_ count: Int) async throws -> [Request] {
        let deadline = Date().addingTimeInterval(2)
        while requests.count < count, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard requests.count >= count else {
            XCTFail("Expected \(count) captures; got \(requests.count)")
            throw FixtureError.requestTimedOut
        }
        return requests
    }
    func finish(_ index: Int, images: SpaceCanvasPreviewLoader.Images) {
        responses.removeValue(forKey: index)?.resume(returning: images)
    }
}
