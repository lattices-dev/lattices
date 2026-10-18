import XCTest
@testable import Lattices

final class DesktopPollWorkerTests: XCTestCase {
    func testSlowInventoryDoesNotBlockMainOrQueueMoreScans() {
        let worker = BackgroundPollWorker(label: "lattices.test-inventory")
        let started = expectation(description: "scan started off main")
        let mainResponded = expectation(description: "main handles input while AX is waiting")
        let finished = expectation(description: "scan finished")
        let release = DispatchSemaphore(value: 0)
        XCTAssertTrue(worker.request {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            finished.fulfill()
        })
        wait(for: [started], timeout: 1)
        for _ in 0..<100 {
            XCTAssertFalse(worker.request { XCTFail("An obsolete poll was queued") })
        }
        DispatchQueue.main.async { mainResponded.fulfill() }
        wait(for: [mainResponded], timeout: 1)
        release.signal()
        wait(for: [finished], timeout: 1)
    }
}
