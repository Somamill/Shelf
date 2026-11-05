import XCTest
@testable import ShelfCore

final class ReaderProgressStoreTests: XCTestCase {
    func testOfflinePositionSurvivesRestartAndOlderAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let store = ReaderProgressStore(url: url)
        _ = try store.save(["document":"book-a", "percentage":0.2, "timestamp":100.0])
        _ = try store.save(["document":"book-a", "percentage":0.3, "timestamp":200.0])
        try store.acknowledge(document:"book-a", timestamp:100)
        let reopened = ReaderProgressStore(url: url)
        XCTAssertEqual(reopened.pending().count,1)
        XCTAssertEqual(reopened.pending().first?["percentage"] as? Double,0.3)
        try reopened.acknowledge(document:"book-a", timestamp:200)
        XCTAssertTrue(reopened.pending().isEmpty)
    }
}
