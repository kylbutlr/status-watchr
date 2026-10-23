import XCTest
@testable import StatusWatchr

final class ServerOriginTests: XCTestCase {
    func testPublicTelemetryUsesAnIndependentDirectory() {
        XCTAssertTrue(ConnectionRecorder.directory(for: .watchr).path.contains("Status Watchr Public/connections-v1"))
    }
    func testOnlyLoopbackAllowsHTTP() {
        XCTAssertTrue(canUseWatchrServer(URL(string: "http://127.0.0.1:4288/api/events")!))
        XCTAssertTrue(canUseWatchrServer(URL(string: "http://localhost:4288/api/collector")!))
        XCTAssertTrue(canUseWatchrServer(URL(string: "https://watchr.example/api/events")!))
        XCTAssertFalse(canUseWatchrServer(URL(string: "http://watchr.example/api/events")!))
        XCTAssertFalse(canUseWatchrServer(URL(string: "https://token@watchr.example/api/events")!))
        XCTAssertFalse(canUseWatchrServer(URL(string: "file:///tmp/events")!))
    }
}
