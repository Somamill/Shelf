import XCTest
@testable import ShelfCore
final class LogTimestampTests:XCTestCase {
    func testRecoveryIsNewerThanFailureInTheLocalTimezone() throws {
        let zone=try XCTUnwrap(TimeZone(identifier:"Asia/Tokyo"))
        let failed=try XCTUnwrap(LogTimestamp.parse("[2026-11-05 10:52:21] ERROR Docker unavailable",timeZone:zone))
        let recovered=try XCTUnwrap(LogTimestamp.parse("[2026-11-05 11:10:55] BRIDGE END",timeZone:zone))
        XCTAssertGreaterThan(recovered,failed)
        XCTAssertEqual(recovered.timeIntervalSince(failed),1114,accuracy:1)
        XCTAssertNil(LogTimestamp.parse("No timestamp here",timeZone:zone))
    }
}
