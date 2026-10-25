import Foundation

/// Cloud locations currently enter Shelf through the operating system's synced file provider.
/// This keeps the reader independent of vendor credentials and maps cleanly to iOS Files access.
public enum CloudFolderProvider: String, CaseIterable, Codable, Sendable {
    case iCloud = "icloud"
    case oneDrive = "onedrive"
    case googleDrive = "googleDrive"
    case other = "other"
}

public enum ReaderDevice: String, CaseIterable, Codable, Sendable {
    case koReader = "koreader"
    case xteink = "xteink"
    case iPhone = "iphone"
}

public enum ConnectedService: String, CaseIterable, Codable, Sendable {
    case hardcover
    case readwise
    case readwiseReader = "readwise-reader"
    case bookfusion
    case koreader = "kosync"
    case jellyfin
    case bookorbit
    case spotify
    case seekquel
    case microblog
    case kindle
}

public struct ShelfProfile: Codable, Equatable, Sendable {
    public var cloudProvider: CloudFolderProvider
    public var libraryBookmark: Data?
    public var importBookmark: Data?
    public var username: String
    public var devices: Set<ReaderDevice>
    public var connections: Set<ConnectedService>

    public init(
        cloudProvider: CloudFolderProvider = .iCloud,
        libraryBookmark: Data? = nil,
        importBookmark: Data? = nil,
        username: String = "",
        devices: Set<ReaderDevice> = [],
        connections: Set<ConnectedService> = []
    ) {
        self.cloudProvider = cloudProvider
        self.libraryBookmark = libraryBookmark
        self.importBookmark = importBookmark
        self.username = username
        self.devices = devices
        self.connections = connections
    }
}
