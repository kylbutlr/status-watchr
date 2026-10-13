import XCTest
@testable import StatusWatchr

final class AttentionRequestBufferTests: XCTestCase {
    func testResolvedPermissionCandidateIsDiscardedBeforeItCanAlert() {
        var buffer = AttentionRequestBuffer()
        buffer.stage(sessionID: "thread-1", attention: PendingAttention(turn: "turn-1", marker: "request-1", tool: "Bash"))

        XCTAssertNotNil(buffer.cancel(sessionID: "thread-1", turnID: "turn-1", tool: "Bash"))
        XCTAssertNil(buffer.promote(sessionID: "thread-1", turnID: "turn-1"))
    }

    func testUnresolvedPermissionCandidateCanBePromotedOnce() {
        var buffer = AttentionRequestBuffer()
        let candidate = PendingAttention(turn: "turn-1", marker: "request-1", tool: "Bash")
        buffer.stage(sessionID: "thread-1", attention: candidate)

        XCTAssertEqual(buffer.promote(sessionID: "thread-1", turnID: "turn-1"), candidate)
        XCTAssertNil(buffer.promote(sessionID: "thread-1", turnID: "turn-1"))
    }

    func testAutomaticReviewDiscardsTheStagedPermissionCandidate() {
        var buffer = AttentionRequestBuffer()
        buffer.stage(sessionID: "thread-1", attention: PendingAttention(turn: "turn-1", marker: "request-1", tool: "Bash"))

        buffer.cancel(sessionID: "thread-1")

        XCTAssertNil(buffer.promote(sessionID: "thread-1", turnID: "turn-1"))
    }
}
