import Foundation
import XCTest
@testable import ShelfCore

final class SetupModelsTests: XCTestCase {
    func testShelfProfileDefaultsAreUsable() {
        let profile = ShelfProfile()

        XCTAssertEqual(profile.cloudProvider, .iCloud)
        XCTAssertNil(profile.libraryBookmark)
        XCTAssertNil(profile.importBookmark)
        XCTAssertEqual(profile.username, "")
        XCTAssertTrue(profile.devices.isEmpty)
        XCTAssertTrue(profile.connections.isEmpty)
    }

    func testProfileSelectionsSurviveCodableRoundTrip() throws {
        let profile = ShelfProfile(
            cloudProvider: .googleDrive,
            libraryBookmark: Data([1, 2, 3]),
            importBookmark: Data([4, 5, 6]),
            username: "reader",
            devices: [.koReader, .xteink],
            connections: [.hardcover, .readwiseReader, .koreader]
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ShelfProfile.self, from: encoded)

        XCTAssertEqual(decoded, profile)
    }

    func testPersistedIdentifiersRemainStable() {
        XCTAssertEqual(CloudFolderProvider.iCloud.rawValue, "icloud")
        XCTAssertEqual(CloudFolderProvider.googleDrive.rawValue, "googleDrive")
        XCTAssertEqual(ReaderDevice.koReader.rawValue, "koreader")
        XCTAssertEqual(ReaderDevice.xteink.rawValue, "xteink")
        XCTAssertEqual(ConnectedService.readwiseReader.rawValue, "readwise-reader")
        XCTAssertEqual(ConnectedService.koreader.rawValue, "kosync")
    }
}
