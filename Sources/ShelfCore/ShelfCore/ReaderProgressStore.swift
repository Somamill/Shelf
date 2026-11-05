import Foundation

/// Durable latest reading positions. Network acknowledgements cannot erase a newer edit.
public final class ReaderProgressStore {
    private let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }

    private func read() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return records
    }
    private func write(_ records: [String: [String: Any]]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ position: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let document = position["document"] as? String else { throw CocoaError(.coderInvalidValue) }
        var record = position
        record["timestamp"] = position["timestamp"] ?? Date().timeIntervalSince1970
        record["pending"] = true
        var records = read()
        if let current = records[document], let timestamp = current["timestamp"] as? Double,
           timestamp > (record["timestamp"] as? Double ?? 0) { return current }
        records[document] = record
        try write(records)
        return record
    }
    public func acknowledge(document: String, timestamp: Double) throws {
        lock.lock(); defer { lock.unlock() }
        var records = read()
        guard var record = records[document], (record["timestamp"] as? Double) == timestamp else { return }
        record["pending"] = false
        records[document] = record
        try write(records)
    }
    public func pending() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return read().values.filter { $0["pending"] as? Bool == true }.sorted {
            ($0["timestamp"] as? Double ?? 0) < ($1["timestamp"] as? Double ?? 0)
        }
    }
}
