import Foundation

/// File work that must never hold a whole video in memory: 4 MiB at a time.
public enum Files {
    public static let piece = 4 * 1024 * 1024

    /// Copies the bytes of `source` after `offset` into a new file at `destination` and returns how
    /// many were written. A background upload can only send a whole file, so resuming part-way
    /// sends this copy. Throws `CocoaError(.fileWriteOutOfSpace)` when the disk is full,
    /// leaving no partial copy behind.
    @discardableResult
    public static func writeRemainder(of source: URL, from offset: Int64, to destination: URL, piece: Int = piece) throws -> Int64 {
        try writeRange(of: source, from: offset, length: nil, to: destination, piece: piece)
    }

    /// Copies `length` bytes of `source` from `offset` (or all after it, when nil) into a new file at
    /// `destination`, as `writeRemainder` does: a part or block of an upload in parts is sent from
    /// such a copy. Throws if the file is too short.
    @discardableResult
    public static func writeRange(of source: URL, from offset: Int64, length: Int64?, to destination: URL, piece: Int = piece) throws -> Int64 {
        let size = try fileSize(source)
        if let length = length, length < 0 || offset + length > size {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "range \(offset)+\(length) outside a \(size)-byte file"])
        }
        guard offset >= 0, offset <= size else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "offset \(offset) outside 0...\(size)"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil,
                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(offset))
            var written: Int64 = 0
            while length.map({ written < $0 }) ?? true {
                let want = length.map { Int(min(Int64(piece), $0 - written)) } ?? piece
                let data = try autoreleasepool { try input.read(upToCount: want) ?? Data() }
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                written += Int64(data.count)
            }
            try output.synchronize()
            if let length = length, written != length {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "copied \(written) of \(length) bytes"])
            }
            return written
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Appends the whole of `piece` to `part` (a resumed download's new bytes), 4 MiB at a time.
    public static func append(_ pieceFile: URL, to part: URL) throws {
        let output = try FileHandle(forWritingTo: part)
        defer { try? output.close() }
        try output.seekToEnd()
        let input = try FileHandle(forReadingFrom: pieceFile)
        defer { try? input.close() }
        while true {
            let data = try autoreleasepool { try input.read(upToCount: piece) ?? Data() }
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    /// Moves `part` to `destination` (replacing anything there), but only if it is `size` bytes.
    public static func finish(part: URL, at destination: URL, size: Int64) throws {
        let have = try fileSize(part)
        guard size < 0 || have == size else {
            throw NSError(domain: "BackgroundTransfer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "part file is \(have) bytes, expected \(size)"])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
    }

    public static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes[.type] as? FileAttributeType) == .typeDirectory {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Removes every file in `directory` whose path isn't in `keep`, and returns what it removed.
    /// Remainder copies left by a process that ended mid-copy are found this way on the next launch.
    @discardableResult
    public static func removeOrphans(in directory: URL, keeping keep: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let kept = Set(keep.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var removed: [URL] = []
        for name in names {
            let url = directory.appendingPathComponent(name).standardizedFileURL
            if kept.contains(url.path) { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// `<path>.part`: where a download's bytes go until all have landed.
    public static func partURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".part")
    }

    /// Keeps `directory` and everything under it out of iCloud and Finder backups: the plugin's
    /// records hold the headers and URLs (with their tokens) of every transfer, its resume data the
    /// original requests, and none of that belongs on another device.
    public static func excludeFromBackup(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Whether `url` is excluded from backups (for the tests).
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }
}

/// A parsed `Content-Range` header.
public struct ContentRange: Equatable {
    public let start: Int64   // -1 for `bytes */total`
    public let end: Int64
    public let total: Int64   // -1 for `/*`

    public init(start: Int64, end: Int64, total: Int64) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// Where a request's `Range: bytes=N-` asks to start: N, or 0 with no (or another kind of) Range.
    public static func requestedStart(_ rangeHeader: String?) -> Int64 {
        guard let h = rangeHeader?.trimmingCharacters(in: .whitespaces), h.hasPrefix("bytes="), h.hasSuffix("-") else { return 0 }
        return Int64(h.dropFirst("bytes=".count).dropLast()) ?? 0
    }

    /// `bytes 100-199/1000`, `bytes */1000` or `bytes 0-9/*`; nil otherwise.
    public static func parse(_ header: String?) -> ContentRange? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes ") else { return nil }
        let rest = header.dropFirst("bytes ".count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let total: Int64
        if parts[1] == "*" { total = -1 } else if let t = Int64(parts[1]) { total = t } else { return nil }
        if parts[0] == "*" { return ContentRange(start: -1, end: -1, total: total) }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let s = Int64(bounds[0]), let e = Int64(bounds[1]), s <= e else { return nil }
        return ContentRange(start: s, end: e, total: total)
    }
}
