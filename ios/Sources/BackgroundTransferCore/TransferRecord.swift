import Foundation

/// One transfer, as stored and as reported to JavaScript (`TransferRecord` in definitions.ts).
public struct TransferRecord: Codable, Equatable {
    public enum Direction: String, Codable { case upload, download }
    public enum State: String, Codable { case queued, running, interrupted, finished, failed, cancelled }

    public var id: String
    public var direction: Direction
    public var state: State
    public var url: String
    public var path: String
    /// Uploads: the protocol the session speaks (`UploadProtocol`); nil for a download.
    public var `protocol`: String?
    public var bytes: Int64 = 0
    public var total: Int64 = -1
    public var reason: String?
    public var message: String?
    public var httpStatus: Int?
    public var updatedAt: Double = 0
    public var queuedAt: Double = 0
    public var headers: [String: String] = [:]
    /// Upload: the server's offset when this task was made; the task sends the bytes after it.
    public var startOffset: Int64 = 0
    /// Upload: the temporary copy of the bytes after `startOffset`, when there is one.
    public var remainderPath: String?
    /// The URLSession task carrying it, when there is one.
    public var taskIdentifier: Int?
    /// Upload: the HTTP status of a refusal still being checked against the session. Kept so a
    /// launch that finds no answer yet checks again instead of guessing.
    public var refusedStatus: Int?
    /// `s3-multipart`: the presigned part URLs, part 1 first.
    public var partUrls: [String]?
    /// `s3-multipart`: bytes per part; nil for the default.
    public var partSize: Int64?
    /// `s3-multipart`: the presigned ListParts URL.
    public var listPartsUrl: String?
    /// `azure-blocks`: bytes per block; nil for the default.
    public var blockSize: Int64?
    /// Upload in parts: the parts or blocks the server holds, by number ("1", "2", …): the S3 `ETag`
    /// or the Azure block id.
    public var parts: [String: String]?
    /// Upload in parts: the commit (S3 completion, Azure block list) has been handed over. A lost
    /// answer isn't taken as success.
    public var committing: Bool?
    /// Upload in parts: 0 while the commit's task runs (its body file is `remainderPath`).
    public var currentPart: Int?
    /// Upload in parts (iOS): the tasks carrying parts or blocks, by task identifier, each with its
    /// part number and the temporary copy it sends. One while the app is on screen; every remaining
    /// part once the app has left it.
    public var partTasks: [String: PartTask]?

    public init(id: String, direction: Direction, url: String, path: String) {
        self.id = id
        self.direction = direction
        self.state = .queued
        self.url = url
        self.path = path
    }

    public var key: String { TransferRecord.key(direction, id) }

    public static func key(_ direction: Direction, _ id: String) -> String { "\(direction.rawValue):\(id)" }

    /// Still to run or running: not to be forgotten or started twice.
    public var isActive: Bool { state == .queued || state == .running }

    /// The shape JavaScript sees.
    public var js: [String: Any] {
        var o: [String: Any] = [
            "id": id, "direction": direction.rawValue, "state": state.rawValue, "url": url, "path": path,
            "bytes": bytes, "total": total, "updatedAt": updatedAt,
        ]
        if let p = `protocol` { o["protocol"] = p }
        if let reason = reason { o["reason"] = reason }
        if let message = message { o["message"] = message }
        if let httpStatus = httpStatus { o["httpStatus"] = httpStatus }
        return o
    }
}

/// A background task carrying one part or block, and the temporary copy of its range.
public struct PartTask: Codable, Equatable {
    public var part: Int
    public var copy: String

    public init(part: Int, copy: String) {
        self.part = part
        self.copy = copy
    }
}

/// The `TransferFailureReason` values.
public enum Reason {
    public static let fileMissing = "file-missing"
    public static let diskFull = "disk-full"
    public static let sessionRefused = "session-refused"
    public static let sessionExpired = "session-expired"
    /// The session was already closed when the upload started: whether the object was accepted
    /// only its metadata can say (the Firebase Storage emulator closes a session whose finalize its security rules refused).
    public static let sessionClosed = "session-closed"
    public static let sizeMismatch = "size-mismatch"
    public static let network = "network"
    public static let stoppedBySystem = "stopped-by-system"
    public static let cancelled = "cancelled"
    public static let serverError = "server-error"
    public static let unknown = "unknown"

    /// The reason for an HTTP status that isn't a success, and whether trying again later can help.
    public static func forStatus(_ status: Int) -> (reason: String, resumable: Bool) {
        switch status {
        case 404, 410: return (sessionExpired, false)
        case 408, 429, 500...599: return (serverError, true)
        default: return (sessionRefused, false)
        }
    }

    /// The reason for a URLSession error. `cancelledByUs` is whether the app asked for the cancel.
    public static func forError(_ error: NSError, cancelledByUs: Bool) -> (reason: String, resumable: Bool) {
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorCancelled {
                if cancelledByUs { return (cancelled, false) }
                // Swiped away by the user, or ended by the system: resumable from where it stopped.
                return (stoppedBySystem, true)
            }
            if error.code == NSURLErrorCannotWriteToFile { return (diskFull, false) }
            if error.code == NSURLErrorFileDoesNotExist || error.code == NSURLErrorCannotOpenFile { return (fileMissing, false) }
            return (network, true)
        }
        if isDiskFull(error) { return (diskFull, false) }
        if error.domain == NSPOSIXErrorDomain { return (network, true) }
        return (unknown, false)
    }

    public static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
        return false
    }
}
