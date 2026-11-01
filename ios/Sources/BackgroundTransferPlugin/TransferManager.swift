import Foundation
import UIKit
#if canImport(BackgroundTransferCore)
import BackgroundTransferCore
#endif

/// Runs transfers in two background `URLSession`s, one per direction, so they carry on in the
/// system's transfer daemon with the app suspended or killed, and records every change in the
/// `TransferStore`. Each session allows one connection per host, so transfers in a direction go
/// one at a time.
///
/// Everything here runs on `queue`, which is also the sessions' delegate queue.
final class TransferManager: NSObject {
    static let shared = TransferManager()

    /// The app's events, while it is open.
    weak var listener: TransferListener?

    let queue = DispatchQueue(label: "io.github.sandman92.backgroundtransfer")
    private let delegateQueue = OperationQueue()
    private let store: TransferStore
    private let directory: URL
    private var completionHandlers: [String: () -> Void] = [:]
    /// Keys of transfers the app asked to cancel, so the task's cancellation reads as theirs.
    private var cancelling = Set<String>()
    private var lastSaved: [String: Date] = [:]
    private var lastProgress: [String: Date] = [:]
    /// Upload responses' bodies (the finalized object's metadata), kept to check its size.
    private var uploadBodies: [Int: Data] = [:]
    /// Session checks still waiting for an answer; the system's completion handler is held until none are.
    private var checks = 0
    private var heldHandlers: [() -> Void] = []
    /// Calls that arrive before `start()` has reconciled the records wait here.
    private var started = false
    private var waiting: [() -> Void] = []
    /// Download tasks' outcome, decided when the file arrives and applied when the task completes.
    private var downloadOutcome: [String: (state: TransferRecord.State, reason: String?, message: String?, status: Int?)] = [:]

    static var bundlePrefix: String { Bundle.main.bundleIdentifier ?? "io.github.sandman92.backgroundtransfer" }
    static var uploadSessionId: String { "\(bundlePrefix).background-transfer.upload" }
    static var downloadSessionId: String { "\(bundlePrefix).background-transfer.download" }

    private lazy var uploadSession: URLSession = makeSession(TransferManager.uploadSessionId)
    private lazy var downloadSession: URLSession = makeSession(TransferManager.downloadSessionId)

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("BackgroundTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TransferStore(file: directory.appendingPathComponent("transfers.json"))
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
    }

    private func makeSession(_ identifier: String) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: Launch

    /// Reconnects both sessions (their finished work is then delivered), and reports a record left
    /// queued or running with no task behind it as interrupted.
    func start() {
        queue.async {
            let sessions = [self.uploadSession, self.downloadSession]
            let group = DispatchGroup()
            var live = Set<String>()
            for session in sessions {
                group.enter()
                session.getAllTasks { tasks in
                    self.queue.async {
                        for t in tasks where t.state == .running || t.state == .suspended {
                            if let key = t.taskDescription { live.insert(key) }
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: self.queue) {
                for var r in self.store.all() where r.isActive && !live.contains(r.key) {
                    if r.direction == .upload, let refused = r.refusedStatus {
                        // A refusal was being checked when the process ended: check it again.
                        self.checkSession(r, refusedWith: refused)
                        continue
                    }
                    // No task behind it: the app was killed while preparing it. (A task that ended
                    // while the app was away is reported by the session and overrides this.)
                    r.state = .interrupted
                    r.reason = Reason.stoppedBySystem
                    r.message = "no transfer was running for this when the app opened"
                    r.taskIdentifier = nil
                    self.removeRemainder(&r)
                    self.save(r, event: "stateChange")
                }
                // Remainder copies no record names: left by a process that ended mid-copy.
                let named = Set(self.store.all().compactMap(\.remainderPath))
                Files.removeOrphans(in: self.directory.appendingPathComponent("remainders"), keeping: named)
                self.started = true
                let calls = self.waiting
                self.waiting = []
                calls.forEach { $0() }
            }
        }
    }

    /// Runs `work` on `queue` once `start()` has reconciled the records, so a new transfer is
    /// never mistaken for one the last process left behind.
    private func whenStarted(_ work: @escaping () -> Void) {
        queue.async {
            if self.started { work() } else { self.waiting.append(work) }
        }
    }

    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == TransferManager.uploadSessionId || identifier == TransferManager.downloadSessionId else { return false }
        NSLog("BackgroundTransfer: woken for %@", identifier)
        queue.async {
            self.completionHandlers[identifier] = completionHandler
            _ = identifier == TransferManager.uploadSessionId ? self.uploadSession : self.downloadSession
        }
        return true
    }

    // MARK: Calls from JavaScript

    func list() -> [TransferRecord] { store.all() }

    func forget(keys: Set<String>?) {
        queue.async {
            for r in self.store.all() where !r.isActive && r.state != .interrupted {
                if let keys = keys, !keys.contains(r.key) { continue }
                self.store.remove(key: r.key)
            }
        }
    }

    /// Queues a transfer and calls back with its record. One that is queued or running is left alone.
    func enqueue(_ wanted: TransferRecord, done: @escaping (TransferRecord) -> Void) {
        whenStarted {
            if let existing = self.store.get(key: wanted.key), existing.isActive {
                done(existing)
                return
            }
            var r = wanted
            r.state = .queued
            r.queuedAt = self.store.nextQueuedAt()
            r.reason = nil
            r.message = nil
            r.httpStatus = nil
            r.taskIdentifier = nil
            r.refusedStatus = nil
            if r.direction == .download {
                r.bytes = (try? Files.fileSize(Files.partURL(for: URL(fileURLWithPath: r.path)))) ?? 0
            }
            r = self.save(r, event: "stateChange")
            done(r)
            if r.direction == .upload { self.startUpload(r) } else { self.startDownload(r) }
        }
    }

    func cancel(key: String) {
        whenStarted {
            guard var r = self.store.get(key: key) else { return }
            if r.isActive, r.taskIdentifier != nil {
                self.cancelling.insert(key)
                let session = r.direction == .upload ? self.uploadSession : self.downloadSession
                session.getAllTasks { tasks in
                    self.queue.async {
                        let task = tasks.first { $0.taskDescription == key }
                        if let task = task {
                            task.cancel()
                        } else {
                            self.cancelling.remove(key)
                            self.markCancelled(&r)
                        }
                    }
                }
                return
            }
            if r.isActive || r.state == .interrupted { self.markCancelled(&r) }
        }
    }

    private func markCancelled(_ r: inout TransferRecord) {
        cleanUp(&r)
        r.state = .cancelled
        r.reason = Reason.cancelled
        r.message = "cancelled"
        r.taskIdentifier = nil
        save(r, event: "stateChange")
    }

    // MARK: Upload

    private func startUpload(_ record: TransferRecord) {
        var r = record
        // Where another protocol's adapter would plug in.
        switch UploadProtocol.resolve(r.protocol) {
        case .firebaseResumable:
            break
        case nil:
            fail(&r, Reason.unknown, "unknown upload protocol \(r.protocol ?? "")")
            return
        }
        let file = URL(fileURLWithPath: r.path)
        let size: Int64
        do {
            size = try Files.fileSize(file)
        } catch {
            fail(&r, Reason.fileMissing, "no file at \(r.path)")
            return
        }
        r.total = size
        guard let url = URL(string: r.url) else {
            fail(&r, Reason.sessionRefused, "not a URL")
            return
        }
        // Ask the session what it holds. A plain (foreground) request: the app is on screen now.
        querySession(url, headers: r.headers) { response, error in
            self.afterQuery(r, file: file, size: size, response: response, error: error)
        }
    }

    /// `X-Goog-Upload-Command: query` on a plain ephemeral session; calls back on `queue`.
    private func querySession(_ url: URL, headers: [String: String], done: @escaping (URLResponse?, Error?) -> Void) {
        var query = URLRequest(url: url)
        query.httpMethod = "POST"
        query.setValue("query", forHTTPHeaderField: "X-Goog-Upload-Command")
        for (k, v) in headers { query.setValue(v, forHTTPHeaderField: k) }
        query.httpBody = Data()
        // Inside the ~30 s a relaunched app gets: the completion handler waits for this answer.
        query.timeoutInterval = UploadOutcome.checkTimeout
        let probe = URLSession(configuration: .ephemeral)
        probe.dataTask(with: query) { _, response, error in
            probe.finishTasksAndInvalidate()
            self.queue.async { done(response, error) }
        }.resume()
    }

    private func afterQuery(_ record: TransferRecord, file: URL, size: Int64, response: URLResponse?, error: Error?) {
        guard var r = store.get(key: record.key), r.state == .queued else { return } // cancelled meanwhile
        r.total = size
        if let error = error as NSError? {
            let (reason, resumable) = Reason.forError(error, cancelledByUs: false)
            if resumable { interrupt(&r, reason, "query: \(error.localizedDescription)") } else { fail(&r, reason, "query: \(error.localizedDescription)") }
            return
        }
        guard let http = response as? HTTPURLResponse else {
            interrupt(&r, Reason.network, "query: no response")
            return
        }
        guard http.statusCode == 200 else {
            let (reason, resumable) = Reason.forStatus(http.statusCode)
            r.httpStatus = http.statusCode
            if resumable { interrupt(&r, reason, "query HTTP \(http.statusCode)") } else { fail(&r, reason, "query HTTP \(http.statusCode)") }
            return
        }
        guard let received = (http.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received")).flatMap({ Int64($0) }) else {
            fail(&r, Reason.unknown, "query answered without X-Goog-Upload-Size-Received")
            return
        }
        if let stop = UploadOutcome.beforeSending(received: received, uploadStatus: http.value(forHTTPHeaderField: "X-Goog-Upload-Status"),
                                                  total: size) {
            apply(stop, to: &r, httpStatus: 0)
            return
        }
        guard received > 0 else {
            sendUpload(r, from: file, offset: 0)
            return
        }
        // A background upload sends a whole file, so resuming part-way sends a copy of the rest.
        let remainder = directory.appendingPathComponent("remainders/\(UUID().uuidString)")
        // Named before it is written, so a process that ends mid-copy leaves a file the next launch removes.
        r.remainderPath = remainder.path
        r = store.put(r)
        // Off the serial queue, so a copy of gigabytes doesn't hold up every call and callback, and
        // with background time, so leaving the app doesn't end it half-way.
        let time = BackgroundTime("BackgroundTransfer remainder copy")
        DispatchQueue.global(qos: .utility).async {
            var copyError: NSError?
            do {
                try Files.writeRemainder(of: file, from: received, to: remainder)
            } catch {
                copyError = error as NSError
            }
            self.queue.async {
                defer { time.end() }
                guard var now = self.store.get(key: r.key), now.state == .queued, now.remainderPath == remainder.path else {
                    // Cancelled (or started again) while copying.
                    try? FileManager.default.removeItem(at: remainder)
                    return
                }
                if let ns = copyError {
                    self.fail(&now, Reason.isDiskFull(ns) ? Reason.diskFull : Reason.fileMissing, "remainder copy: \(ns.localizedDescription)")
                    return
                }
                self.sendUpload(now, from: remainder, offset: received)
            }
        }
    }

    /// Hands the upload to the background session: `source` holds the bytes from `offset` to the end.
    private func sendUpload(_ record: TransferRecord, from source: URL, offset: Int64) {
        var r = record
        guard let url = URL(string: r.url) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(offset), forHTTPHeaderField: "X-Goog-Upload-Offset")
        // A body sent without one goes as a form.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = uploadSession.uploadTask(with: request, fromFile: source)
        task.taskDescription = r.key
        r.startOffset = offset
        r.bytes = offset
        r.taskIdentifier = task.taskIdentifier
        save(r, event: "progress")
        task.resume()
    }

    // MARK: Download

    private func startDownload(_ record: TransferRecord) {
        var r = record
        guard let url = URL(string: r.url) else {
            fail(&r, Reason.sessionRefused, "not a URL")
            return
        }
        let dest = URL(fileURLWithPath: r.path)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = Files.partURL(for: dest)
        let have = (try? Files.fileSize(part)) ?? 0
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeDataURL(r.key)) {
            // The system kept the bytes of an earlier attempt; it resumes those itself.
            try? FileManager.default.removeItem(at: resumeDataURL(r.key))
            task = downloadSession.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: url)
            for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            task = downloadSession.downloadTask(with: request)
        }
        task.taskDescription = r.key
        r.bytes = have
        r.startOffset = have
        r.taskIdentifier = task.taskIdentifier
        save(r, event: "progress")
        task.resume()
    }

    private func resumeDataURL(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return directory.appendingPathComponent("resume/\(safe).data")
    }

    /// Called on `queue` with the finished file in the system's temporary location, which is gone
    /// once this returns.
    private func downloadArrived(_ task: URLSessionDownloadTask, at location: URL) {
        guard let key = task.taskDescription, var r = store.get(key: key) else { return }
        let dest = URL(fileURLWithPath: r.path)
        let part = Files.partURL(for: dest)
        let http = task.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        do {
            // What the delivered file holds: from the start this task asked for (its Range, or 0) to the
            // end. The system may resume a dropped download by itself and answer 206 to a request that
            // had no Range; the file it hands over is still whole from that start.
            let asked = ContentRange.requestedStart(task.originalRequest?.value(forHTTPHeaderField: "Range"))
            switch status {
            case 200, 206:
                let range = ContentRange.parse(http?.value(forHTTPHeaderField: "Content-Range"))
                let total: Int64
                if status == 200 || asked == 0 {
                    // The whole object: it replaces whatever was in the part file.
                    if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
                    try FileManager.default.moveItem(at: location, to: part)
                    let expected = status == 206 ? (range?.total ?? -1) : (http?.expectedContentLength ?? -1)
                    total = expected >= 0 ? expected : (try Files.fileSize(part))
                } else {
                    // The rest after the part file's bytes.
                    let have = (try? Files.fileSize(part)) ?? 0
                    guard have == asked else {
                        try? FileManager.default.removeItem(at: part)
                        downloadOutcome[key] = (.interrupted, Reason.sizeMismatch, "the part file changed while downloading; starting again", status)
                        return
                    }
                    try Files.append(location, to: part)
                    total = range?.total ?? -1
                }
                try Files.finish(part: part, at: dest, size: total)
                r.total = try Files.fileSize(dest)
            case 416:
                let range = ContentRange.parse(http?.value(forHTTPHeaderField: "Content-Range"))
                let have = (try? Files.fileSize(part)) ?? 0
                if let range = range, range.total == have, have > 0 {
                    try Files.finish(part: part, at: dest, size: have)
                    r.total = have
                } else {
                    try? FileManager.default.removeItem(at: part)
                    downloadOutcome[key] = (.interrupted, Reason.sizeMismatch, "the part file didn't fit the object; starting again", status)
                    return
                }
            default:
                let (reason, resumable) = Reason.forStatus(status)
                downloadOutcome[key] = (resumable ? .interrupted : .failed, reason, "download HTTP \(status)", status)
                return
            }
            downloadOutcome[key] = (.finished, nil, nil, status)
            r.bytes = r.total
            store.put(r, save: false)
        } catch {
            let ns = error as NSError
            let full = Reason.isDiskFull(ns)
            if full { try? FileManager.default.removeItem(at: part) }
            downloadOutcome[key] = (.failed, full ? Reason.diskFull : Reason.sizeMismatch, ns.localizedDescription, status)
            if !full { try? FileManager.default.removeItem(at: part) }
        }
    }

    // MARK: Outcomes

    private func completed(_ task: URLSessionTask, error: Error?) {
        let body = uploadBodies.removeValue(forKey: task.taskIdentifier)
        guard let key = task.taskDescription, var r = store.get(key: key) else { return }
        guard r.taskIdentifier == task.taskIdentifier || r.taskIdentifier == nil else { return } // an older task
        let byUs = cancelling.remove(key) != nil
        r.taskIdentifier = nil
        if r.direction == .upload {
            removeRemainder(&r)
            if let error = error as NSError? {
                let (reason, resumable) = Reason.forError(error, cancelledByUs: byUs)
                if reason == Reason.cancelled { markCancelled(&r); return }
                if resumable { interrupt(&r, reason, error.localizedDescription) } else { fail(&r, reason, error.localizedDescription) }
                return
            }
            let http = task.response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let received = http?.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received").flatMap { Int64($0) }
            let outcome = UploadOutcome.afterResponse(status: status, uploadStatus: http?.value(forHTTPHeaderField: "X-Goog-Upload-Status"),
                                                      received: received, body: body, total: r.total)
            if outcome == .query {
                checkSession(r, refusedWith: status)
                return
            }
            apply(outcome, to: &r, httpStatus: status)
            return
        }
        // Download
        if let outcome = downloadOutcome.removeValue(forKey: key) {
            r = store.get(key: key) ?? r
            r.taskIdentifier = nil
            r.httpStatus = outcome.state == .finished ? nil : outcome.status
            switch outcome.state {
            case .finished:
                r.state = .finished
                r.reason = nil
                r.message = nil
                save(r, event: "stateChange")
            case .interrupted:
                interrupt(&r, outcome.reason ?? Reason.unknown, outcome.message ?? "")
            default:
                fail(&r, outcome.reason ?? Reason.unknown, outcome.message ?? "")
            }
            return
        }
        let ns = (error as NSError?) ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)
        let (reason, resumable) = Reason.forError(ns, cancelledByUs: byUs)
        if reason == Reason.cancelled { markCancelled(&r); return }
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? FileManager.default.createDirectory(at: resumeDataURL(key).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: resumeDataURL(key))
        }
        if resumable { interrupt(&r, reason, ns.localizedDescription) } else { fail(&r, reason, ns.localizedDescription) }
    }

    /// The answer wasn't a clean finalize: the system may have resent the request by itself, with the
    /// offset from when it was made, after the server had kept part of it. Ask the session before
    /// believing the answer. The refusal is recorded first, so a process that ends before the answer
    /// comes asks again at the next launch; the system's completion handler is held until it is in.
    private func checkSession(_ record: TransferRecord, refusedWith status: Int) {
        var r = record
        r.state = .running
        r.taskIdentifier = nil
        r.refusedStatus = status
        r = store.put(r)
        guard let url = URL(string: r.url) else {
            apply(.failed(reason: Reason.sessionRefused, message: "not a URL"), to: &r, httpStatus: status)
            return
        }
        checks += 1
        let time = BackgroundTime("BackgroundTransfer session check")
        querySession(url, headers: r.headers) { response, error in
            defer {
                time.end()
                self.checks -= 1
                if self.checks == 0 {
                    let handlers = self.heldHandlers
                    self.heldHandlers = []
                    handlers.forEach { DispatchQueue.main.async(execute: $0) }
                }
            }
            guard var now = self.store.get(key: r.key), now.isActive, now.taskIdentifier == nil, now.refusedStatus == status else { return }
            let q = response as? HTTPURLResponse
            let received = q?.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received").flatMap { Int64($0) }
            let after = UploadOutcome.afterQuery(originalStatus: status, queryStatus: error == nil ? q?.statusCode : nil, received: received,
                                                 uploadStatus: q?.value(forHTTPHeaderField: "X-Goog-Upload-Status"), total: now.total)
            if let received = received { now.bytes = received }
            self.apply(after, to: &now, httpStatus: status)
        }
    }

    private func apply(_ outcome: UploadOutcome, to r: inout TransferRecord, httpStatus: Int) {
        r.refusedStatus = nil
        switch outcome {
        case .finished:
            r.httpStatus = nil
            r.reason = nil
            r.message = nil
            r.bytes = r.total
            r.state = .finished
            save(r, event: "stateChange")
        case .interrupted(let reason, let message):
            r.httpStatus = httpStatus == 0 ? nil : httpStatus
            interrupt(&r, reason, message)
        case .failed(let reason, let message):
            r.httpStatus = httpStatus == 0 ? nil : httpStatus
            fail(&r, reason, message)
        case .query:
            r.httpStatus = httpStatus
            interrupt(&r, Reason.unknown, "upload HTTP \(httpStatus)")
        }
    }

    private func interrupt(_ r: inout TransferRecord, _ reason: String, _ message: String) {
        r.state = .interrupted
        r.reason = reason
        r.message = message
        r.taskIdentifier = nil
        save(r, event: "stateChange")
    }

    private func fail(_ r: inout TransferRecord, _ reason: String, _ message: String) {
        cleanUp(&r)
        r.state = .failed
        r.reason = reason
        r.message = message
        r.taskIdentifier = nil
        save(r, event: "stateChange")
    }

    /// Removes a transfer's temporary files: an upload's remainder copy, a download's part file and resume data.
    private func cleanUp(_ r: inout TransferRecord) {
        removeRemainder(&r)
        if r.direction == .download {
            try? FileManager.default.removeItem(at: Files.partURL(for: URL(fileURLWithPath: r.path)))
            try? FileManager.default.removeItem(at: resumeDataURL(r.key))
            r.bytes = 0
        }
    }

    private func removeRemainder(_ r: inout TransferRecord) {
        if let path = r.remainderPath {
            try? FileManager.default.removeItem(atPath: path)
            r.remainderPath = nil
        }
    }

    @discardableResult
    private func save(_ r: TransferRecord, event: String) -> TransferRecord {
        let stored = store.put(r)
        lastSaved[r.key] = Date()
        listener?.transferChanged(stored, event: event)
        return stored
    }

    /// Progress: told to the app at most four times a second, written to disk every two seconds.
    private func progressed(_ task: URLSessionTask, bytes: Int64, total: Int64) {
        guard let key = task.taskDescription, var r = store.get(key: key), r.taskIdentifier == task.taskIdentifier else { return }
        let wasQueued = r.state == .queued
        r.state = .running
        r.bytes = bytes
        if total >= 0 { r.total = total }
        let now = Date()
        let persist = wasQueued || now.timeIntervalSince(lastSaved[key] ?? .distantPast) >= 2
        let stored = store.put(r, save: persist)
        if persist { lastSaved[key] = now }
        if wasQueued { listener?.transferChanged(stored, event: "stateChange") }
        if wasQueued || now.timeIntervalSince(lastProgress[key] ?? .distantPast) >= 0.25 {
            lastProgress[key] = now
            listener?.transferChanged(stored, event: "progress")
        }
    }
}

protocol TransferListener: AnyObject {
    func transferChanged(_ record: TransferRecord, event: String)
}

extension TransferManager: URLSessionDataDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let key = task.taskDescription, let r = store.get(key: key) else { return }
        progressed(task, bytes: r.startOffset + totalBytesSent, total: r.total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // An upload's response: the finalized object's metadata. Small; capped all the same.
        var body = uploadBodies[dataTask.taskIdentifier] ?? Data()
        if body.count + data.count <= 64 * 1024 { body.append(data) }
        uploadBodies[dataTask.taskIdentifier] = body
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, let r = store.get(key: key) else { return }
        let total = totalBytesExpectedToWrite >= 0 ? r.startOffset + totalBytesExpectedToWrite : -1
        progressed(downloadTask, bytes: r.startOffset + totalBytesWritten, total: total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloadArrived(downloadTask, at: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completed(task, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let id = session.configuration.identifier, let handler = completionHandlers.removeValue(forKey: id) else { return }
        // Not while a session check is out: the app would be suspended before its answer.
        if checks > 0 { heldHandlers.append(handler) } else { DispatchQueue.main.async(execute: handler) }
    }
}

/// Background execution time for work that must not be cut short when the app leaves the screen.
final class BackgroundTime {
    private let lock = NSLock()
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        // Safe from any thread.
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
        lock.lock()
        self.id = id
        lock.unlock()
    }

    func end() {
        lock.lock()
        let current = id
        id = .invalid
        lock.unlock()
        if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
    }
}
