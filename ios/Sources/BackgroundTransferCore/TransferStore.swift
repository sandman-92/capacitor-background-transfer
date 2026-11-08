import Foundation

/// Every transfer's record, in one small JSON file, so state survives the app's process:
/// the system finishes background transfers with the app closed and relaunches it to report.
/// Thread-safe.
public final class TransferStore {
    private let file: URL
    private let lock = NSLock()
    private var records: [String: TransferRecord] = [:]
    private var lastQueuedAt: Double = 0

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([TransferRecord].self, from: data) {
            for r in list { records[r.key] = r }
            lastQueuedAt = list.map(\.queuedAt).max() ?? 0
        }
    }

    public func get(_ direction: TransferRecord.Direction, _ id: String) -> TransferRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[TransferRecord.key(direction, id)]
    }

    public func get(key: String) -> TransferRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[key]
    }

    /// Oldest first.
    public func all() -> [TransferRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Stores `r`, stamping `updatedAt`. Returns what was stored. A record that has stopped
    /// (finished, interrupted, failed or cancelled) is kept without its headers: a restart brings its
    /// own, and a token has no business on the disk after the request it was for.
    @discardableResult
    public func put(_ r: TransferRecord, save: Bool = true) -> TransferRecord {
        lock.lock(); defer { lock.unlock() }
        var r = r
        r.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded()
        if !r.isActive { r.headers = [:] }
        records[r.key] = r
        if save { write() }
        return r
    }

    public func remove(key: String) {
        lock.lock(); defer { lock.unlock() }
        if records.removeValue(forKey: key) != nil { write() }
    }

    /// A strictly increasing time for first-in, first-out.
    public func nextQueuedAt() -> Double {
        lock.lock(); defer { lock.unlock() }
        lastQueuedAt = max((Date().timeIntervalSince1970 * 1000).rounded(), lastQueuedAt + 1)
        return lastQueuedAt
    }

    private func write() {
        let list = Array(records.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable by the system's transfer daemon while the phone is locked after its first unlock.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
