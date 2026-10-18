import CoreGraphics
import XCTest
@testable import Lattices

@MainActor
final class SpaceCanvasPreviewLoaderTests: XCTestCase {
    func testCapturesSixDistinctValidWindowsInSmallBoundedBatches() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let received = expectation(description: "three progressive deliveries")
        received.expectedFulfillmentCount = 3
        loader.load(windows: [window(0), window(11), window(11)] + (12...20).map { window(UInt32($0)) }) { images in
            XCTAssertFalse(images.keys.contains(99))
            received.fulfill()
        }
        for index in 0..<3 {
            let requests = try await fixture.waitForRequests(index + 1)
            XCTAssertEqual(requests[index].maximum, 1440)
            XCTAssertEqual(requests[index].ids.count, 2)
            var images = Dictionary(uniqueKeysWithValues: requests[index].ids.map { ($0, Self.image()) })
            images[99] = Self.image()
            await fixture.finish(index, images: images)
        }
        await fulfillment(of: [received], timeout: 1)
        let requests = await fixture.requests
        XCTAssertEqual(requests.flatMap(\.ids), [11, 12, 13, 14, 15, 16])
        loader.stop()
    }

    func testPredictiveOrderMovesOutwardAndCapturesCurrentDesktopLast() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let cards = (11...15).map { card(UInt32($0)) }
        loader.prepare(cards: cards, selected: 2, current: 2)
        for index in 0..<3 {
            _ = try await fixture.waitForRequests(index + 1)
            await fixture.finish(index, images: [:])
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.flatMap(\.ids), [12, 14, 11, 15, 13])
        loader.stop()
    }

    func testSameSelectionDoesNotRecaptureAfterFailureOrTemporaryHide() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let received = expectation(description: "empty capture delivered")
        loader.load(windows: [window(11)]) { images in
            XCTAssertTrue(images.isEmpty)
            received.fulfill()
        }
        _ = try await fixture.waitForRequests(1)
        await fixture.finish(0, images: [:])
        await fulfillment(of: [received], timeout: 1)
        loader.cancel()
        var immediatelyDelivered = false
        loader.load(windows: [window(11)]) { images in
            XCTAssertTrue(images.isEmpty)
            immediatelyDelivered = true
        }
        XCTAssertTrue(immediatelyDelivered)
        await quietTurn()
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        loader.stop()
    }

    func testSelectionReplacementRejectsOldOwnerAndKeepsOnlyOneBatchInFlight() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let stale = expectation(description: "old receiver never delivered")
        stale.isInverted = true
        let current = expectation(description: "new owner delivered")
        loader.load(windows: [window(11, pid: 100)]) { _ in stale.fulfill() }
        _ = try await fixture.waitForRequests(1)
        loader.load(windows: [window(11, pid: 200)]) { images in
            XCTAssertEqual(Set(images.keys), [11])
            current.fulfill()
        }
        let beforeFinish = await fixture.requests
        XCTAssertEqual(beforeFinish.count, 1)
        await fixture.finish(0, images: [11: Self.image()])
        _ = try await fixture.waitForRequests(2)
        await fixture.finish(1, images: [11: Self.image()])
        await fulfillment(of: [current, stale], timeout: 0.05)
        loader.stop()
    }

    func testStopRejectsLateResultsAndReleasesSessionMemory() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let stale = expectation(description: "closed canvas never delivered")
        stale.isInverted = true
        loader.load(windows: [window(11)]) { _ in stale.fulfill() }
        _ = try await fixture.waitForRequests(1)
        loader.stop()
        await fixture.finish(0, images: [11: Self.image()])
        await fulfillment(of: [stale], timeout: 0.05)
        XCTAssertEqual(loader.cachedBytes, 0)
        loader.load(windows: [window(12)]) { _ in stale.fulfill() }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testBudgetStopsSpeculationAndRetainsDemandedPhotos() async throws {
        let fixture = ControlledPreviewCapture()
        let image = Self.image()
        let bytes = image.bytesPerRow * image.height
        let loader = SpaceCanvasPreviewLoader(maximumBytes: bytes * 2, estimatedWindowBytes: bytes,
                                              capture: { ids, maximum in await fixture.capture(ids, maximum) })
        loader.prepare(cards: [card(11), card(12), card(13), card(14)], selected: 0, current: 3)
        _ = try await fixture.waitForRequests(1)
        await fixture.finish(0, images: [11: image, 12: image])
        await quietTurn()
        XCTAssertEqual(loader.cachedBytes, bytes * 2)
        var requests = await fixture.requests
        XCTAssertEqual(requests.count, 1, "full cache stops predictive capture")
        let delivered = expectation(description: "new requested desktop delivered")
        loader.load(windows: [window(13)]) { images in
            XCTAssertEqual(Set(images.keys), [13])
            delivered.fulfill()
        }
        _ = try await fixture.waitForRequests(2)
        await fixture.finish(1, images: [13: image])
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertLessThanOrEqual(loader.cachedBytes, bytes * 2)
        loader.suspendSelection()
        var warm = false
        loader.load(windows: [window(13)]) { images in warm = images[13] != nil }
        XCTAssertTrue(warm, "selection image stays resident")
        await quietTurn()
        requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        loader.stop()
    }

    func testEmptySelectionDoesNotCaptureZeroWindowIDOrReceivePendingPhotos() async throws {
        let fixture = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let stale = expectation(description: "hidden selection receives no photos")
        stale.isInverted = true
        loader.load(windows: [window(11)]) { _ in stale.fulfill() }
        _ = try await fixture.waitForRequests(1)
        loader.load(windows: [window(0)]) { _ in stale.fulfill() }
        await fixture.finish(0, images: [11: Self.image()])
        await fulfillment(of: [stale], timeout: 0.05)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        loader.stop()
    }

    func testChangingMapSelectionPreparesThatDesktopEvenWhenCacheIsFull() async throws {
        let fixture = ControlledPreviewCapture()
        let image = Self.image()
        let bytes = image.bytesPerRow * image.height
        let loader = SpaceCanvasPreviewLoader(maximumBytes: bytes * 2, estimatedWindowBytes: bytes,
                                              capture: { ids, maximum in await fixture.capture(ids, maximum) })
        let cards = [card(11), card(12), card(13), card(14)]
        loader.prepare(cards: cards, selected: 0, current: 3)
        _ = try await fixture.waitForRequests(1)
        await fixture.finish(0, images: [11: image, 12: image])
        await quietTurn()
        XCTAssertEqual(loader.cachedBytes, bytes * 2)

        // Still in the schematic map: there has been no call to load().
        loader.prepare(cards: cards, selected: 2, current: 3)
        let requests = try await fixture.waitForRequests(2)
        XCTAssertEqual(requests[1].ids, [13], "only the new target bypasses the full-cache limit")
        await fixture.finish(1, images: [13: image])
        await quietTurn()
        XCTAssertLessThanOrEqual(loader.cachedBytes, bytes * 2)
        var immediate = false
        loader.load(windows: [window(13)]) { images in immediate = images[13] != nil }
        XCTAssertTrue(immediate, "approaching the new target uses its prepared image immediately")
        loader.suspendSelection()
        loader.prepare(cards: cards, selected: 2, current: 3)
        await quietTurn()
        let afterRepeat = await fixture.requests
        XCTAssertEqual(afterRepeat.count, 2, "stable selection and full cache do not churn")
        loader.stop()
    }

    func testEvictedSnapshotsCanBeRevisitedWithoutRecapturingResidentOrFailedImages() async throws {
        let fixture = ControlledPreviewCapture()
        let image = Self.image()
        let bytes = image.bytesPerRow * image.height
        let loader = SpaceCanvasPreviewLoader(maximumBytes: bytes, estimatedWindowBytes: bytes,
                                              capture: { ids, maximum in await fixture.capture(ids, maximum) })
        for (index, wid) in [UInt32(11), 12, 11, 12, 11, 12].enumerated() {
            loader.suspendSelection()
            let delivered = expectation(description: "demand \(index) delivered")
            loader.load(windows: [window(wid)]) { images in
                XCTAssertNotNil(images[wid])
                delivered.fulfill()
            }
            _ = try await fixture.waitForRequests(index + 1)
            await fixture.finish(index, images: [wid: image])
            await fulfillment(of: [delivered], timeout: 1)
            XCTAssertEqual(loader.cachedBytes, bytes)
        }
        loader.suspendSelection()
        var warm = false
        loader.load(windows: [window(12)]) { warm = $0[12] != nil }
        XCTAssertTrue(warm)
        await quietTurn()
        let beforeFailure = await fixture.requests
        XCTAssertEqual(beforeFailure.count, 6, "resident images never recapture")

        loader.suspendSelection()
        let failed = expectation(description: "failed recapture settles")
        loader.load(windows: [window(11)]) { images in
            XCTAssertTrue(images.isEmpty)
            failed.fulfill()
        }
        _ = try await fixture.waitForRequests(7)
        await fixture.finish(6, images: [:])
        await fulfillment(of: [failed], timeout: 1)
        loader.suspendSelection()
        var settled = false
        loader.load(windows: [window(11)]) { images in
            XCTAssertTrue(images.isEmpty)
            settled = true
        }
        XCTAssertTrue(settled)
        await quietTurn()
        let requests = await fixture.requests
        XCTAssertEqual(requests.flatMap(\.ids), [11, 12, 11, 12, 11, 12, 11])
        loader.stop()
    }

    func testSameWindowDeliversWarmPreviewThenNativeDetail() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        let warm = Self.image()
        let sharp = Self.image(width: 128, height: 128)
        let received = expectation(description: "warm and sharp images both delivered for the same window")
        received.expectedFulfillmentCount = 2
        var deliveries: [CGImage] = []
        loader.load(windows: [window(11)], displayPixelSize: CGSize(width: 128, height: 128)) { images in
            if let image = images[11] { deliveries.append(image) }
            received.fulfill()
        }
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: warm])
        let detailRequests = try await detail.waitForRequests(1)
        XCTAssertEqual(detailRequests[0].ids, [11])
        XCTAssertEqual(detailRequests[0].maximum, 128)
        XCTAssertTrue(deliveries.first === warm, "the warm image remains visible while detail is pending")
        await detail.finish(0, images: [11: sharp])
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertTrue(deliveries.last === sharp)
        XCTAssertEqual(loader.cachedBytes, sharp.bytesPerRow * sharp.height,
                       "quality replaces the cached image instead of retaining both tiers")
        loader.stop()
    }

    func testFailedDetailKeepsWarmImageAndDoesNotRetryOnRepeatedZoom() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        let warm = Self.image()
        var deliveries: [CGImage] = []
        let display = CGSize(width: 128, height: 128)
        loader.load(windows: [window(11)], displayPixelSize: display) { images in
            if let image = images[11] { deliveries.append(image) }
        }
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: warm])
        _ = try await detail.waitForRequests(1)
        await detail.finish(0, images: [:])
        await quietTurn()
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertTrue(deliveries.first === warm)
        XCTAssertEqual(loader.cachedBytes, warm.bytesPerRow * warm.height)

        loader.suspendSelection()
        var revisited: CGImage?
        loader.load(windows: [window(11)], displayPixelSize: display) { revisited = $0[11] }
        XCTAssertTrue(revisited === warm)
        await quietTurn()
        let previewRequests = await preview.requests
        let detailRequests = await detail.requests
        XCTAssertEqual(previewRequests.count, 1)
        XCTAssertEqual(detailRequests.count, 1, "failed detail is deduplicated for the session")
        loader.stop()
    }

    func testRepeatedZoomReusesSharpImageWithoutRecapturingEitherTier() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        let sharp = Self.image(width: 128, height: 128)
        let display = CGSize(width: 128, height: 128)
        let ready = expectation(description: "detail available")
        loader.load(windows: [window(11)], displayPixelSize: display) { images in
            if images[11] === sharp { ready.fulfill() }
        }
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: Self.image()])
        _ = try await detail.waitForRequests(1)
        await detail.finish(0, images: [11: sharp])
        await fulfillment(of: [ready], timeout: 1)
        for _ in 0..<3 {
            loader.suspendSelection()
            var revisited: CGImage?
            loader.load(windows: [window(11)], displayPixelSize: display) { revisited = $0[11] }
            XCTAssertTrue(revisited === sharp)
        }
        await quietTurn()
        let previewRequests = await preview.requests
        let detailRequests = await detail.requests
        XCTAssertEqual(previewRequests.count, 1)
        XCTAssertEqual(detailRequests.count, 1)
        loader.stop()
    }

    func testAbandonedDetailCannotReplaceWarmImageOrEvictItsNeighbor() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let warm = Self.image()
        let stale = Self.image(width: 8, height: 8)
        let warmBytes = warm.bytesPerRow * warm.height
        let loader = SpaceCanvasPreviewLoader(
            maximumBytes: stale.bytesPerRow * stale.height, estimatedWindowBytes: warmBytes,
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        loader.prepare(cards: [card(11), card(12)], selected: 0, current: 1)
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: warm, 12: warm])
        await quietTurn()
        XCTAssertEqual(loader.cachedBytes, warmBytes * 2)
        loader.load(windows: [window(11)], displayPixelSize: CGSize(width: 128, height: 128)) { _ in }
        _ = try await detail.waitForRequests(1)
        var neighbor: CGImage?
        loader.load(windows: [window(12)]) { neighbor = $0[12] }
        XCTAssertTrue(neighbor === warm)
        await detail.finish(0, images: [11: stale])
        await quietTurn()
        XCTAssertEqual(loader.cachedBytes, warmBytes * 2, "abandoned detail must not disturb either warm entry")
        var abandoned: CGImage?
        loader.load(windows: [window(11)]) { abandoned = $0[11] }
        XCTAssertTrue(abandoned === warm)
        XCTAssertTrue(neighbor === warm)
        let previewRequests = await preview.requests
        XCTAssertEqual(previewRequests.count, 1, "neither resident image needs repair or recapture")
        loader.stop()
    }

    func testReturningToAbandonedDetailCanRequestSharpImageAgain() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let loader = SpaceCanvasPreviewLoader(
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        let warm = Self.image()
        let sharp = Self.image(width: 128, height: 128)
        let display = CGSize(width: 128, height: 128)
        loader.load(windows: [window(11)], displayPixelSize: display) { _ in }
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: warm])
        _ = try await detail.waitForRequests(1)
        loader.suspendSelection()
        await detail.finish(0, images: [11: sharp])
        await quietTurn()
        XCTAssertEqual(loader.cachedBytes, warm.bytesPerRow * warm.height)

        let ready = expectation(description: "returning selection can become sharp")
        loader.load(windows: [window(11)], displayPixelSize: display) { images in
            if images[11] === sharp { ready.fulfill() }
        }
        _ = try await detail.waitForRequests(2)
        await detail.finish(1, images: [11: sharp])
        await fulfillment(of: [ready], timeout: 1)
        let previewRequests = await preview.requests
        XCTAssertEqual(previewRequests.count, 1, "returning keeps the already-captured warm fallback")
        loader.stop()
    }

    func testDetailThatWouldEvictAnotherSelectedImageKeepsWarmFallback() async throws {
        let preview = ControlledPreviewCapture()
        let detail = ControlledPreviewCapture()
        let warm = Self.image()
        let oversize = Self.image(width: 8, height: 8)
        let budget = oversize.bytesPerRow * oversize.height
        let loader = SpaceCanvasPreviewLoader(
            maximumBytes: budget, estimatedWindowBytes: warm.bytesPerRow * warm.height,
            capture: { ids, maximum in await preview.capture(ids, maximum) },
            detailCapture: { ids, maximum in await detail.capture(ids, maximum) })
        var delivered: [CGWindowID: CGImage] = [:]
        loader.load(windows: [window(11), window(12)],
                    displayPixelSize: CGSize(width: 128, height: 128)) { delivered = $0 }
        _ = try await preview.waitForRequests(1)
        await preview.finish(0, images: [11: warm, 12: warm])
        _ = try await detail.waitForRequests(1)
        await detail.finish(0, images: [11: oversize])
        _ = try await detail.waitForRequests(2)
        await detail.finish(1, images: [:])
        await quietTurn()
        XCTAssertTrue(delivered[11] === warm)
        XCTAssertTrue(delivered[12] === warm)
        XCTAssertEqual(loader.cachedBytes, warm.bytesPerRow * warm.height * 2)
        XCTAssertLessThanOrEqual(loader.cachedBytes, budget)
        loader.suspendSelection()
        loader.load(windows: [window(11), window(12)]) { delivered = $0 }
        XCTAssertTrue(delivered[11] === warm)
        XCTAssertTrue(delivered[12] === warm, "the other selected image remains resident")
        loader.stop()
    }

    private func quietTurn() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private func card(_ wid: UInt32) -> SpaceFilmstripCard {
        SpaceFilmstripCard(id: Int(wid), number: Int(wid), windows: [window(wid)])
    }

    private func window(_ wid: UInt32, pid: Int32 = 100) -> SpaceFilmstripWindow {
        var result = SpaceFilmstripWindow(rect: CGRect(x: 0, y: 0, width: 1, height: 1), app: "Test", pid: pid)
        result.wid = wid
        return result
    }

    private static func image(width: Int = 2, height: Int = 2) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

/// Ignores cancellation, as an already-submitted screenshot can: only the
/// loader's ownership checks can keep a late result off a closed canvas.
private actor ControlledPreviewCapture {
    struct Request {
        let ids: [CGWindowID]
        let maximum: CGFloat
    }
    private(set) var requests: [Request] = []
    private var responses: [Int: CheckedContinuation<SpaceCanvasPreviewLoader.Images, Never>] = [:]

    func capture(_ ids: [CGWindowID], _ maximum: CGFloat) async -> SpaceCanvasPreviewLoader.Images {
        await withCheckedContinuation { continuation in
            let index = requests.count
            requests.append(Request(ids: ids, maximum: maximum))
            responses[index] = continuation
        }
    }

    private enum FixtureError: Error { case requestTimedOut }

    func waitForRequests(_ count: Int) async throws -> [Request] {
        let deadline = Date().addingTimeInterval(2)
        while requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard requests.count >= count else {
            XCTFail("Expected \(count) capture requests; received \(requests.count)")
            throw FixtureError.requestTimedOut
        }
        return requests
    }

    func finish(_ index: Int, images: SpaceCanvasPreviewLoader.Images) {
        responses.removeValue(forKey: index)?.resume(returning: images)
    }
}
