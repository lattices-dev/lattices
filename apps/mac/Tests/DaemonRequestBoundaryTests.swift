import Darwin
import Foundation
import XCTest
@testable import Lattices

final class DaemonRequestBoundaryTests: XCTestCase {
    func testDeadlineSurvivesDecodingAndHelperRouting() throws {
        let request = try JSONDecoder().decode(DaemonRequest.self, from: Data(#"{"id":"1","method":"voice.say","params":null,"deadline":123456789}"#.utf8))
        XCTAssertEqual(request.deadline, 123456789)
        XCTAssertEqual(VoiceHelperRouting.renamed(request, to: "speech.enqueue").deadline, request.deadline)
        let legacy = try JSONDecoder().decode(DaemonRequest.self, from: Data(#"{"id":"1","method":"ping"}"#.utf8))
        XCTAssertNil(legacy.deadline)
    }

    func testExpiredMutationDoesNotEnterHandler() {
        let api = LatticesApi()
        var executions = 0
        api.register(Endpoint(method: "test.mutate", description: "test", access: .mutate, params: [], returns: .ok, handler: { _ in
            executions += 1
            return .object(["ok": .bool(true)])
        }))
        let response = api.handle(DaemonRequest(id: "1", method: "test.mutate", params: nil, deadline: 1))
        XCTAssertEqual(executions, 0)
        XCTAssertTrue(response.error?.hasPrefix("deadline_exceeded:") == true)
        XCTAssertEqual(response.delivery?["status"], .string("not_delivered"))
        XCTAssertEqual(response.delivery?["retrySafe"], .bool(true))
    }

    func testMainHopChecksDeadlineAgainBeforeExecuting() async throws {
        let connection = TestConnection()
        let entered = DispatchSemaphore(value: 0)
        let complete = expectation(description: "request returned")
        let deadline = Date().addingTimeInterval(0.15).timeIntervalSince1970 * 1000
        let context = DaemonContext(connection: connection, deadline: deadline)
        await MainActor.run {
            DispatchQueue.global().async {
                do {
                    try context.run {
                        entered.signal()
                        try LatticesApi.onMain { XCTFail("Expired main-thread work executed") }
                    }
                    XCTFail("Expected queued request to expire")
                } catch {
                    XCTAssertTrue(error.localizedDescription.hasPrefix("deadline_exceeded:"))
                }
                complete.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            // Hold main until this request expires in its main-queue wait.
            Thread.sleep(forTimeInterval: 0.2)
        }
        await fulfillment(of: [complete], timeout: 2)
    }

    func testOutputDoesNotBlockPublisherAndClosingInterruptsSlowWriter() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = WebSocketClient(id: UUID(), fd: sockets[0])
        defer { client.closeSocket(); close(sockets[1]) }
        for fd in sockets {
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        let frame = Data(repeating: 42, count: 4 * 1024 * 1024)
        let started = Date()
        XCTAssertTrue(client.enqueue(opcode: 1, payload: frame))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        // The unread peer cannot take the complete frame. Closing must wake the
        // writer immediately rather than waiting for its two-second deadline.
        Thread.sleep(forTimeInterval: 0.05)
        let closing = Date()
        client.closeSocket()
        XCTAssertLessThan(Date().timeIntervalSince(closing), 0.5)
        XCTAssertFalse(client.isOpen)
    }

    func testOutputQueueRejectsUnboundedBacklog() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let client = WebSocketClient(id: UUID(), fd: sockets[0])
        defer { client.closeSocket(); close(sockets[1]) }
        let rejected = expectation(description: "oversized output rejected")
        XCTAssertFalse(client.enqueue(opcode: 1, payload: Data(count: WebSocketClient.maxPendingBytes)) { sent in
            XCTAssertFalse(sent)
            rejected.fulfill()
        })
        wait(for: [rejected], timeout: 1)
        XCTAssertFalse(client.isOpen)
    }

    func testExpiredSpeechRequestIsRejectedBeforeConnection() async {
        let rejected = expectation(description: "expired helper request")
        let helper = SpeechCompanionConnection(socketPath: "/private/tmp/nonexistent-lattices-test-\(UUID().uuidString)", response: { response in
            XCTAssertTrue(response.error?.hasPrefix("deadline_exceeded:") == true)
            rejected.fulfill()
        }, event: { _ in XCTFail("No helper connection should be opened") })
        await helper.forward(DaemonRequest(id: "expired", method: "speech.enqueue", params: nil, deadline: 1))
        await fulfillment(of: [rejected], timeout: 1)
        await helper.close()
    }

    private final class TestConnection: DaemonConnection {
        let connectionID = UUID()
        var isOpen = true
        func sendBinary(_ data: Data) -> Bool { true }
        func sendEvent(_ event: DaemonEvent) -> Bool { true }
        func onClose(_ handler: @escaping () -> Void) {}
    }
}
