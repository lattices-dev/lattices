import XCTest
@testable import ActionCore

final class ActionAgentQueueWatchdogTests: XCTestCase {
    private func verdict(now: TimeInterval, lastBeat: TimeInterval, lastCheck: TimeInterval) -> ActionAgentQueueWatchdog.Verdict {
        ActionAgentQueueWatchdog.verdict(now: now, lastBeat: lastBeat, lastCheck: lastCheck, stallSeconds: 30, checkInterval: 5)
    }

    func testRecentBeatIsHealthy() {
        XCTAssertEqual(verdict(now: 100, lastBeat: 99, lastCheck: 95), .healthy)
    }

    func testStaleBeatWithAPunctualWatchdogIsAStall() {
        XCTAssertEqual(verdict(now: 100, lastBeat: 60, lastCheck: 95), .stalled(40))
    }

    func testWholeProcessPauseIsNotAStall() {
        // The watchdog itself ran an hour late: the task was suspended, not the queue.
        XCTAssertEqual(verdict(now: 3700, lastBeat: 95, lastCheck: 95), .processPaused)
    }

    func testStallCallbackFiresWhenNothingBeats() {
        let watchdog = ActionAgentQueueWatchdog(stallSeconds: 0.2, checkInterval: 0.1)
        let stalled = expectation(description: "stall reported")
        stalled.assertForOverFulfill = false
        watchdog.start { _ in
            watchdog.stop()
            stalled.fulfill()
        }
        wait(for: [stalled], timeout: 2)
    }
}
