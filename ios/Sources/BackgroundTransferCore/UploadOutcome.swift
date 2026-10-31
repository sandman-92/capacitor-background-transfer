import Foundation

/// What an ended background upload task means. The task's request carried the session's offset
/// from when it was made; if the system resent it by itself after a network cut, the server may
/// already hold part of it, so anything but a clean finalize of exactly the file's size is checked
/// against the session before it is believed.
public enum UploadOutcome: Equatable {
    case finished
    case interrupted(reason: String, message: String)
    case failed(reason: String, message: String)
    /// Ask the session (`X-Goog-Upload-Command: query`) and decide with `afterQuery`.
    case query

    /// After the task got an HTTP response.
    /// - Parameters:
    ///   - uploadStatus: `X-Goog-Upload-Status`, if sent.
    ///   - received: `X-Goog-Upload-Size-Received`, if sent.
    ///   - body: the response body (the finalized object's metadata on success), if any.
    public static func afterResponse(status: Int, uploadStatus: String?, received: Int64?, body: Data?, total: Int64) -> UploadOutcome {
        switch status {
        case 200:
            if let s = uploadStatus?.lowercased(), s != "final" {
                return .failed(reason: Reason.sizeMismatch, message: "finalize left the session \(s)")
            }
            if let received = received, received != total {
                return .failed(reason: Reason.sizeMismatch, message: "the server holds \(received) of \(total) bytes")
            }
            if let size = objectSize(body), size != total {
                return .failed(reason: Reason.sizeMismatch, message: "the object is \(size) bytes, the file \(total)")
            }
            return .finished
        case 404, 410:
            return .failed(reason: Reason.sessionExpired, message: "upload HTTP \(status)")
        default:
            return .query
        }
    }

    /// After asking the session what it holds, following a response that wasn't a clean finalize
    /// (`originalStatus`). `queryStatus` is nil when the query itself got no response.
    public static func afterQuery(originalStatus: Int, queryStatus: Int?, received: Int64?, uploadStatus: String?, total: Int64) -> UploadOutcome {
        guard let queryStatus = queryStatus else {
            return .interrupted(reason: Reason.network, message: "upload HTTP \(originalStatus); the session couldn't be asked")
        }
        switch queryStatus {
        case 200:
            let isFinal = uploadStatus?.lowercased() == "final"
            guard let received = received else {
                return .failed(reason: Reason.unknown, message: "upload HTTP \(originalStatus); query answered without a size")
            }
            if isFinal {
                // The server answered the finalize with a refusal: a closed session doesn't mean the
                // object was accepted (security rules may have refused it), so this is never finished.
                let reason = received == total ? Reason.forStatus(originalStatus).reason : Reason.sizeMismatch
                return .failed(reason: reason, message: "upload HTTP \(originalStatus); the session is closed at \(received) of \(total) bytes")
            }
            if received <= total {
                // Still open: the rest can be sent from the server's offset.
                return .interrupted(reason: Reason.network, message: "upload HTTP \(originalStatus); the session holds \(received) of \(total) bytes")
            }
            return .failed(reason: Reason.sizeMismatch, message: "the session holds \(received) of a \(total)-byte file")
        case 404, 410:
            return .failed(reason: Reason.sessionExpired, message: "upload HTTP \(originalStatus); query HTTP \(queryStatus)")
        default:
            let (reason, resumable) = Reason.forStatus(queryStatus)
            let message = "upload HTTP \(originalStatus); query HTTP \(queryStatus)"
            return resumable ? .interrupted(reason: reason, message: message) : .failed(reason: reason, message: message)
        }
    }

    /// How long a session check (`query`) may take. A relaunched app gets about 30 seconds of
    /// background time, and the system's completion handler is held until the check answers, so
    /// the check has to give up well inside that or the app is suspended with the handler unsent.
    public static let checkTimeout: TimeInterval = 20

    /// Before a run sends anything: what the session's answer to `query` rules out. Nil means send
    /// the bytes after `received`. A closed session is never taken as an accepted object.
    public static func beforeSending(received: Int64, uploadStatus: String?, total: Int64) -> UploadOutcome? {
        if uploadStatus?.lowercased() == "final" {
            return .failed(reason: Reason.sessionClosed, message: "the session was already closed at \(received) of \(total) bytes")
        }
        if received > total {
            return .failed(reason: Reason.sizeMismatch, message: "server holds \(received) of a \(total)-byte file")
        }
        return nil
    }

    /// `size` from a finalized object's metadata (Storage sends it as a string).
    public static func objectSize(_ body: Data?) -> Int64? {
        guard let body = body, !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let s = json["size"] as? String { return Int64(s) }
        if let n = json["size"] as? NSNumber { return n.int64Value }
        return nil
    }
}
