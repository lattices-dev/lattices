import Combine
import XCTest
@testable import Lattices

final class TmuxModelTests: XCTestCase {
    func testSlowQueryLeavesMainResponsiveAndPublishesOnMain() {
        let started = expectation(description: "query started")
        let responsive = expectation(description: "main responds during query")
        let published = expectation(description: "fresh sessions published on main")
        let release = DispatchSemaphore(value: 0)
        let model = TmuxModel(query: {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return [TmuxSession(id: "test", name: "test", windowCount: 1, attached: true, panes: [])]
        })
        let observation = model.$sessions.dropFirst().sink { sessions in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(sessions.map(\.name), ["test"])
            published.fulfill()
        }
        model.poll()
        wait(for: [started], timeout: 1)
        for _ in 0..<100 { model.poll() }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 1)
        release.signal()
        wait(for: [published], timeout: 1)
        XCTAssertTrue(model.isRunning("test"))
        withExtendedLifetime(observation) {}
    }
}
