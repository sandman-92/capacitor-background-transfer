import Foundation

/// The steps of a `put` and of an upload in parts (`s3-multipart`, `azure-blocks`), as functions of
/// the record: which request comes next, and what each answer means. `TransferManager` hands each
/// request to the background session; the tests drive the same steps against real servers.
public enum PartsUpload {
    public enum Step: Equatable {
        case part(n: Int, offset: Int64, length: Int64)
        case commit
    }

    // MARK: put

    public static func putRequest(_ r: TransferRecord) -> URLRequest? {
        guard let url = URL(string: r.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// Finished on any 2xx: the server took the whole body.
    public static func afterPut(status: Int) -> UploadOutcome {
        if (200...299).contains(status) { return .finished }
        return refusal(status, "PUT")
    }

    // MARK: Parts

    public static func partSize(_ r: TransferRecord) -> Int64 {
        let size = r.protocol == UploadProtocol.azureBlocks.rawValue ? r.blockSize : r.partSize
        return (size ?? 0) > 0 ? size! : UploadOptionsCheck.defaultPartSize
    }

    public static func count(_ r: TransferRecord, size: Int64) -> Int {
        PartPlan.count(size: size, partSize: partSize(r), atLeastOne: r.protocol == UploadProtocol.s3Multipart.rawValue)
    }

    private static func isAzure(_ r: TransferRecord) -> Bool { r.protocol == UploadProtocol.azureBlocks.rawValue }

    /// Before anything is sent: a commit handed over in an earlier run is never taken as done, and
    /// the file must still fit the parts.
    public static func beforeStart(_ r: TransferRecord, size: Int64) -> UploadOutcome? {
        if r.committing == true {
            let what = isAzure(r) ? "the block list" : "the completion"
            return .failed(reason: Reason.sessionClosed,
                           message: "\(what) was sent earlier and its answer never came: check the object before starting a new upload")
        }
        let p = UploadProtocol.resolve(r.protocol) ?? .s3Multipart
        if let bad = UploadOptionsCheck.checkSize(protocol: p, partUrlCount: r.partUrls?.count ?? 0, partSize: partSize(r),
                                                  blockSize: partSize(r), fileSize: size) {
            return .failed(reason: Reason.sizeMismatch, message: bad)
        }
        return nil
    }

    /// The request asking the server what it holds: ListParts (when its URL was given) or Get Block List.
    public static func probe(_ r: TransferRecord) -> URLRequest? {
        let target: String?
        if isAzure(r) {
            target = withQuery(r.url, "comp=blocklist&blocklisttype=uncommitted")
        } else {
            target = r.listPartsUrl
        }
        guard let t = target, let url = URL(string: t) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// Applies the probe's answer to `r.parts` (`status` nil: no answer). Non-nil stops the upload.
    public static func afterProbe(_ r: inout TransferRecord, status: Int?, body: Data?, size: Int64) -> UploadOutcome? {
        let what = isAzure(r) ? "Get Block List" : "ListParts"
        guard let status = status else { return .interrupted(reason: Reason.network, message: "\(what): no answer") }
        let n = count(r, size: size)
        let plan = partSize(r)
        var parts = r.parts ?? [:]
        if isAzure(r) {
            let ids = PartsXML.blockIds(transferId: r.id, size: size, blockSize: plan, count: n)
            switch status {
            case 200:
                guard let held = PartsXML.uncommittedBlocks(body ?? Data()) else {
                    return .failed(reason: Reason.unknown, message: "\(what) answered with XML that couldn't be read")
                }
                parts = [:]
                for i in stride(from: 1, through: n, by: 1) where held[ids[i - 1]] == PartPlan.length(i, size: size, partSize: plan) {
                    parts[String(i)] = ids[i - 1]
                }
            case 404:
                // No blob and no blocks yet (or they expired): everything goes.
                parts = [:]
            case 403:
                // The SAS can't read the list (no `r`): trust the record. An expired SAS fails on the first block.
                break
            default:
                return refusal(status, what)
            }
            parts = parts.filter { k, v in Int(k).map { $0 >= 1 && $0 <= n && ids[$0 - 1] == v } ?? false }
        } else {
            guard status == 200 else { return refusal(status, what) }
            guard let listed = PartsXML.listParts(body ?? Data()) else {
                return .failed(reason: Reason.unknown, message: "\(what) answered with XML that couldn't be read")
            }
            var kept: [String: String] = [:]
            for i in stride(from: 1, through: n, by: 1) {
                if let held = listed.parts[i] {
                    if held.size == PartPlan.length(i, size: size, partSize: plan) { kept[String(i)] = held.tag }
                } else if listed.truncated && i > listed.highest, let mine = parts[String(i)] {
                    kept[String(i)] = mine
                }
            }
            parts = kept
        }
        r.parts = parts
        return nil
    }

    /// The first part not yet stored, or the commit.
    public static func next(_ r: TransferRecord, size: Int64) -> Step {
        let plan = partSize(r)
        for i in stride(from: 1, through: count(r, size: size), by: 1) where r.parts?[String(i)] == nil {
            return .part(n: i, offset: PartPlan.offset(i, partSize: plan), length: PartPlan.length(i, size: size, partSize: plan))
        }
        return .commit
    }

    /// The bytes of the parts stored.
    public static func storedBytes(_ r: TransferRecord, size: Int64) -> Int64 {
        let plan = partSize(r)
        return (r.parts ?? [:]).keys.compactMap(Int.init).reduce(0) { $0 + PartPlan.length($1, size: size, partSize: plan) }
    }

    public static func partRequest(_ r: TransferRecord, n: Int, size: Int64) -> URLRequest? {
        let target: String?
        if isAzure(r) {
            let id = PartsXML.blockId(transferId: r.id, size: size, blockSize: partSize(r), n: n)
            target = withQuery(r.url, "comp=block&blockid=" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id))
        } else {
            target = (r.partUrls ?? []).indices.contains(n - 1) ? r.partUrls![n - 1] : nil
        }
        guard let t = target, let url = URL(string: t) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// After part `n`'s answer. Nil: it is stored, and recorded in `r.parts`.
    public static func afterPart(_ r: inout TransferRecord, n: Int, status: Int, etag: String?, size: Int64) -> UploadOutcome? {
        let what = "\(isAzure(r) ? "block" : "part") \(n) of \(count(r, size: size))"
        var parts = r.parts ?? [:]
        if isAzure(r) {
            guard status == 201 else { return refusal(status, what) }
            parts[String(n)] = PartsXML.blockId(transferId: r.id, size: size, blockSize: partSize(r), n: n)
        } else {
            guard status == 200 else { return refusal(status, what) }
            guard let etag = etag, !etag.isEmpty else { return .failed(reason: Reason.unknown, message: "\(what) answered without an ETag") }
            parts[String(n)] = etag
        }
        r.parts = parts
        return nil
    }

    /// The commit: S3's `CompleteMultipartUpload` or Azure's `Put Block List`, and its body.
    public static func commitRequest(_ r: TransferRecord, size: Int64) -> (URLRequest, Data)? {
        let n = count(r, size: size)
        let target = isAzure(r) ? withQuery(r.url, "comp=blocklist") : r.url
        guard let url = URL(string: target) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = isAzure(r) ? "PUT" : "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        let body = isAzure(r)
            ? PartsXML.blockListBody(PartsXML.blockIds(transferId: r.id, size: size, blockSize: partSize(r), count: n))
            : PartsXML.completeBody(etags: r.parts ?? [:], count: n)
        return (request, body)
    }

    /// After the commit's answer. Finished only when the server confirms the object; any answer
    /// clears `committing` (it wasn't lost), so a refused commit can be tried again.
    public static func afterCommit(_ r: inout TransferRecord, status: Int, body: Data?) -> UploadOutcome {
        if isAzure(r) {
            if status == 201 { return .finished }
            r.committing = false
            return refusal(status, "commit (Put Block List)")
        }
        if status == 200 && PartsXML.isCompleteResult(body) { return .finished }
        r.committing = false
        if status == 404 {
            return .failed(reason: Reason.sessionClosed,
                           message: "complete HTTP 404: the upload is no longer open (completed or aborted): check the object")
        }
        guard status == 200 else { return refusal(status, "complete") }
        guard let code = PartsXML.errorCode(body) else {
            return .failed(reason: Reason.unknown, message: "complete answered 200 without the completed object")
        }
        let busy = ["InternalError", "SlowDown", "ServiceUnavailable"].contains(code)
        return busy ? .interrupted(reason: Reason.serverError, message: "complete answered 200 with \(code)")
            : .failed(reason: Reason.sessionRefused, message: "complete answered 200 with \(code)")
    }

    static func refusal(_ status: Int, _ what: String) -> UploadOutcome {
        let (reason, resumable) = Reason.forStatus(status)
        let message = "\(what) HTTP \(status)"
        return resumable ? .interrupted(reason: reason, message: message) : .failed(reason: reason, message: message)
    }

    /// `url` with `extra` added to its query.
    public static func withQuery(_ url: String, _ extra: String) -> String {
        let base = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        return base + (base.contains("?") ? "&" : "?") + extra
    }
}
