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
    /// Session checks still waiting for an answer, and parts being made ready for their task; the
    /// system's completion handler is held until none are.
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

    /// Whether the app is on screen. Parts and blocks go one at a time then; once it leaves the
    /// screen every remaining one is handed to the session at once, because the system holds back
    /// each background wake that would start the next part, doubling the wait every time.
    private var onScreen: Bool
    /// Uploads whose part copies are being made, so a second hand-over doesn't copy them again.
    private var preparing = Set<String>()

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("BackgroundTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TransferStore(file: directory.appendingPathComponent("transfers.json"))
        // Made on the main thread (the plugin's load, or the system's background session events).
        onScreen = Thread.isMainThread ? UIApplication.shared.applicationState != .background : false
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            // Background time so the copies are made and handed over before the app is suspended.
            let time = BackgroundTime("BackgroundTransfer hand-over")
            self.queue.async {
                defer { time.end() }
                self.onScreen = false
                self.handOverEverything()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.onScreen = true }
        }
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
                    if r.partTasks == nil {
                        r.currentPart = nil
                        self.removeRemainder(&r)
                    }
                    // Parts handed over stay recorded with their copies: tasks that ended while the
                    // app was away are reported after this, find their parts, and carry the upload on.
                    self.save(r, event: "stateChange")
                }
                // Copies no record names: left by a process that ended mid-copy.
                let named = Set(self.store.all().flatMap { PartsUpload.copies($0) })
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
        let background = UIApplication.shared.applicationState == .background
        queue.async {
            if background { self.onScreen = false }
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
            if var old = self.store.get(key: wanted.key), old.partTasks != nil {
                // Parts an earlier run handed over: stopped, and their copies removed.
                self.dropParts(&old)
                self.store.put(old)
            }
            var r = wanted
            r.state = .queued
            r.queuedAt = self.store.nextQueuedAt()
            r.reason = nil
            r.message = nil
            r.httpStatus = nil
            r.taskIdentifier = nil
            r.refusedStatus = nil
            r.currentPart = nil
            if r.direction == .download {
                r.bytes = (try? Files.fileSize(Files.partURL(for: URL(fileURLWithPath: r.path)))) ?? 0
            } else if UploadProtocol.resolve(r.protocol)?.inParts == true, let existing = self.store.get(key: wanted.key),
                      PartsUpload.carriesOver(existing, r, fileSize: (try? Files.fileSize(URL(fileURLWithPath: r.path))) ?? -2) {
                // The same upload: what it sent, and whether its commit went, carry over.
                r.parts = existing.parts
                r.committing = existing.committing
                r.bytes = existing.bytes
            }
            r = self.save(r, event: "stateChange")
            done(r)
            if r.direction == .upload { self.startUpload(r) } else { self.startDownload(r) }
        }
    }

    func cancel(key: String) {
        whenStarted {
            guard var r = self.store.get(key: key) else { return }
            if r.isActive, r.taskIdentifier != nil || r.partTasks != nil {
                self.cancelling.insert(key)
                let session = r.direction == .upload ? self.uploadSession : self.downloadSession
                session.getAllTasks { tasks in
                    self.queue.async {
                        guard var now = self.store.get(key: key), now.isActive else { return }
                        // Every task of the transfer: an upload in parts may have several handed over.
                        let mine = tasks.filter { $0.taskDescription == key }
                        let unfinished = mine.filter { $0.state != .completed }
                        let commitOut = UploadProtocol.resolve(now.protocol)?.inParts == true && now.currentPart == 0
                        switch PartsUpload.cancelPlan(commitOut: commitOut, unfinishedTasks: unfinished.count,
                                                      endedTasks: mine.count - unfinished.count) {
                        case .cancelTasks:
                            unfinished.forEach { $0.cancel() }
                        case .awaitCommit, .awaitEnd:
                            break // That task's end decides, with the cancel noted.
                        case .markCancelled:
                            self.markCancelled(&now)
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
        guard let chosen = UploadProtocol.resolve(r.protocol) else {
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
        // Each protocol's adapter plugs in here.
        switch chosen {
        case .firebaseResumable:
            break
        case .put:
            sendWhole(r, from: file)
            return
        case .s3Multipart, .azureBlocks:
            startParts(r)
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

    // MARK: put, and uploads in parts

    /// `put`: the whole file in one background task, sent in place (no copy).
    private func sendWhole(_ record: TransferRecord, from file: URL) {
        var r = record
        guard let request = PartsUpload.putRequest(r) else { return fail(&r, Reason.sessionRefused, "not a URL") }
        let task = uploadSession.uploadTask(with: request, fromFile: file)
        task.taskDescription = r.key
        r.startOffset = 0
        r.bytes = 0
        r.taskIdentifier = task.taskIdentifier
        save(r, event: "progress")
        task.resume()
    }

    /// `s3-multipart` and `azure-blocks`: asks the server what it holds (ListParts or Get Block List,
    /// on a plain session: the app is on screen), then hands the parts to the background session
    /// one at a time.
    private func startParts(_ record: TransferRecord) {
        var r = record
        if let stop = PartsUpload.beforeStart(r, size: r.total) {
            apply(stop, to: &r, httpStatus: 0)
            return
        }
        guard var probe = PartsUpload.probe(r) else {
            sendNextPart(r)
            return
        }
        probe.timeoutInterval = UploadOutcome.checkTimeout
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: probe) { body, response, error in
            session.finishTasksAndInvalidate()
            self.queue.async {
                guard var now = self.store.get(key: r.key), now.state == .queued else { return } // cancelled meanwhile
                now.total = r.total
                let status = error == nil ? (response as? HTTPURLResponse)?.statusCode : nil
                if let stop = PartsUpload.afterProbe(&now, status: status, body: body, size: now.total) {
                    self.apply(stop, to: &now, httpStatus: status ?? 0)
                    return
                }
                now.bytes = min(PartsUpload.storedBytes(now, size: now.total), max(now.total - 1, 0))
                self.sendNextPart(self.store.put(now))
            }
        }.resume()
    }

    /// Hands the next part or block to the background session (one, while the app is on screen;
    /// every remaining one, once it has left it), or the commit once every part is stored. Runs after
    /// each part's answer too, with the app perhaps woken in the background for it: the system's
    /// completion handler is held until the tasks are handed over, so the app isn't suspended half-way.
    private func sendNextPart(_ record: TransferRecord) {
        var r = record
        guard !cancelling.contains(r.key) else { return } // Nothing more goes once the app has asked to cancel.
        let size = r.total
        r.taskIdentifier = nil
        guard let step = PartsUpload.next(r, size: size) else {
            store.put(r) // The last parts are still in tasks' hands.
            return
        }
        switch step {
        case .part:
            if onScreen {
                handOver(r, [step])
            } else {
                handOverRemaining(r)
            }
        case .commit:
            guard let (request, body) = PartsUpload.commitRequest(r, size: size) else {
                return fail(&r, Reason.sessionRefused, "not a URL")
            }
            let copy = directory.appendingPathComponent("remainders/\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: copy, options: [.completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                let ns = error as NSError
                return fail(&r, Reason.isDiskFull(ns) ? Reason.diskFull : Reason.unknown, "commit body: \(ns.localizedDescription)")
            }
            let task = uploadSession.uploadTask(with: request, fromFile: copy)
            task.taskDescription = r.key
            r.remainderPath = copy.path
            r.currentPart = 0
            // From here a lost answer can't be told from a committed object.
            r.committing = true
            r.startOffset = size
            r.taskIdentifier = task.taskIdentifier
            save(r, event: "progress")
            task.resume()
        }
    }

    /// The app has left the screen: every upload in parts that is running hands all its remaining
    /// parts over now.
    private func handOverEverything() {
        for r in store.all() where r.direction == .upload && r.isActive && r.total >= 0
            && UploadProtocol.resolve(r.protocol)?.inParts == true && r.currentPart != 0 && r.committing != true {
            if !PartsUpload.pending(r, size: r.total).isEmpty { handOverRemaining(r) }
        }
    }

    /// Hands every part neither stored nor in a task's hands to the session, if their copies fit on
    /// the disk with room to spare; otherwise the next one only, saying so.
    private func handOverRemaining(_ record: TransferRecord) {
        var r = record
        let pending = PartsUpload.pending(r, size: r.total)
        guard let first = pending.first else { return }
        let bytes = PartsUpload.pendingBytes(r, size: r.total)
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if PartsUpload.handOverFits(bytes: bytes, free: free) {
            handOver(r, pending)
        } else {
            let message = "not enough free disk to hand over the \(bytes) bytes left (\(free) free): sending one part at a time"
            NSLog("BackgroundTransfer: %@: %@", r.id, message)
            r.message = message
            handOver(store.put(r), [first])
        }
    }

    /// Copies each part's range to a temporary file (off the serial queue, with background time),
    /// then hands them to the session, recording which part each task carries. Each copy is removed
    /// when its task ends, and by the launch sweep after a process that ended mid-copy.
    private func handOver(_ record: TransferRecord, _ steps: [PartsUpload.Step]) {
        let r = record
        guard !preparing.contains(r.key) else { return }
        let parts: [(n: Int, offset: Int64, length: Int64, copy: URL)] = steps.compactMap { step in
            guard case .part(let n, let offset, let length) = step else { return nil }
            return (n, offset, length, directory.appendingPathComponent("remainders/\(UUID().uuidString)"))
        }
        guard !parts.isEmpty else { return }
        // The file's size and what is stored so far, for the answers that read the record back.
        store.put(r)
        preparing.insert(r.key)
        hold()
        let time = BackgroundTime("BackgroundTransfer part copy")
        DispatchQueue.global(qos: .utility).async {
            var copyError: NSError?
            var made: [URL] = []
            for p in parts {
                do {
                    try Files.writeRange(of: URL(fileURLWithPath: r.path), from: p.offset, length: p.length, to: p.copy)
                    made.append(p.copy)
                } catch {
                    copyError = error as NSError
                    break
                }
            }
            self.queue.async {
                defer {
                    time.end()
                    self.release()
                }
                self.preparing.remove(r.key)
                let removeCopies = { for p in parts { try? FileManager.default.removeItem(at: p.copy) } }
                guard var now = self.store.get(key: r.key), now.isActive, now.queuedAt == r.queuedAt, now.currentPart != 0,
                      !self.cancelling.contains(r.key) else {
                    // Cancelled, stopped or started again while copying.
                    removeCopies()
                    return
                }
                if let ns = copyError {
                    removeCopies()
                    if Reason.isDiskFull(ns) && parts.count > 1 {
                        // The disk filled up after all: one part at a time instead.
                        now.message = "the disk filled up handing every part over: sending one part at a time"
                        NSLog("BackgroundTransfer: %@: %@", now.id, now.message ?? "")
                        self.handOver(self.store.put(now), [.part(n: parts[0].n, offset: parts[0].offset, length: parts[0].length)])
                        return
                    }
                    let missing = !FileManager.default.fileExists(atPath: now.path)
                    self.fail(&now, Reason.isDiskFull(ns) ? Reason.diskFull : (missing ? Reason.fileMissing : Reason.sizeMismatch),
                              "part \(parts[0].n) copy: \(ns.localizedDescription)")
                    return
                }
                var tasks: [URLSessionUploadTask] = []
                for p in parts {
                    guard let request = PartsUpload.partRequest(now, n: p.n, size: now.total) else {
                        removeCopies()
                        tasks.forEach { $0.cancel() }
                        self.fail(&now, Reason.sessionRefused, "part \(p.n) has no URL")
                        return
                    }
                    let task = self.uploadSession.uploadTask(with: request, fromFile: p.copy)
                    task.taskDescription = now.key
                    PartsUpload.assign(&now, task: task.taskIdentifier, part: p.n, copy: p.copy.path)
                    tasks.append(task)
                }
                now.taskIdentifier = nil
                now.startOffset = PartsUpload.storedBytes(now, size: now.total)
                // Recorded before any task can end, so every answer finds its part.
                self.save(now, event: "progress")
                tasks.forEach { $0.resume() }
                // The app left the screen while this one part was being copied: the rest go too.
                if !self.onScreen && !PartsUpload.pending(now, size: now.total).isEmpty { self.handOverRemaining(now) }
            }
        }
    }

    /// Cancels every task the upload's record has handed over and removes their copies.
    private func dropParts(_ r: inout TransferRecord) {
        guard let tasks = r.partTasks else { return }
        for t in tasks.values { try? FileManager.default.removeItem(atPath: t.copy) }
        r.partTasks = nil
        let key = r.key
        let ids = Set(tasks.keys.compactMap(Int.init))
        uploadSession.getAllTasks { all in
            for task in all where task.taskDescription == key && ids.contains(task.taskIdentifier) { task.cancel() }
        }
    }

    /// The answer to a `put`'s task or to a part's or the commit's.
    private func answered(_ record: TransferRecord, part n: Int, status: Int, etag: String?, body: Data?) {
        var r = record
        guard UploadProtocol.resolve(r.protocol)?.inParts == true else {
            apply(PartsUpload.afterPut(status: status), to: &r, httpStatus: status)
            return
        }
        if n == 0 {
            r.currentPart = nil
            if cancelling.contains(r.key) {
                // Cancelled while the commit was out: only the server's confirmation outranks the cancel.
                let outcome = PartsUpload.afterCommit(&r, status: status, body: body)
                if outcome == .finished { apply(outcome, to: &r, httpStatus: status); return }
                // An answer that leaves it open whether the commit was applied (S3's 404 to a resent
                // completion) keeps `committing`, so a restart reports session-closed.
                if case .failed(let reason, _) = outcome, reason == Reason.sessionClosed { r.committing = true }
                markCancelled(&r)
                return
            }
            let outcome = PartsUpload.afterCommit(&r, status: status, body: body)
            apply(outcome, to: &r, httpStatus: status)
            return
        }
        guard n > 0 else {
            apply(.failed(reason: Reason.unknown, message: "an answer came for no part"), to: &r, httpStatus: status)
            return
        }
        if let stop = PartsUpload.afterPart(&r, n: n, status: status, etag: etag, size: r.total) {
            apply(stop, to: &r, httpStatus: status)
            return
        }
        // Stored: on to the next one, or the commit once the others in tasks' hands are in too.
        r.state = .running
        r.reason = nil
        r.message = nil
        r.httpStatus = nil
        // Never the whole object before the commit is confirmed.
        r.bytes = min(PartsUpload.storedBytes(r, size: r.total), max(r.total - 1, 0))
        r = store.put(r)
        listener?.transferChanged(r, event: "progress")
        sendNextPart(r)
    }

    /// Keeps the system's completion handler while work the app must finish is under way.
    private func hold() { checks += 1 }

    private func release() {
        checks -= 1
        if checks == 0 {
            let handlers = heldHandlers
            heldHandlers = []
            handlers.forEach { DispatchQueue.main.async(execute: $0) }
        }
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
        // Once finished, failed or cancelled, a transfer has said its last word: one final state each.
        if r.state == .finished || r.state == .failed || r.state == .cancelled { return }
        // An upload in parts: which part the task carried (none: cancelled with the others, or older).
        var part = -1
        if r.direction == .upload, UploadProtocol.resolve(r.protocol)?.inParts == true {
            if let t = PartsUpload.release(&r, task: task.taskIdentifier) {
                try? FileManager.default.removeItem(atPath: t.copy)
                part = t.part
            } else if r.currentPart == 0 && (r.taskIdentifier == task.taskIdentifier || r.taskIdentifier == nil) {
                part = 0
            } else {
                return
            }
        } else {
            guard r.taskIdentifier == task.taskIdentifier || r.taskIdentifier == nil else { return } // an older task
        }
        let byUs = cancelling.contains(key)
        r.taskIdentifier = nil
        if r.direction == .upload {
            if part <= 0 { removeRemainder(&r) }
            let ns = error as NSError?
            let cancelledError = ns?.domain == NSURLErrorDomain && ns?.code == NSURLErrorCancelled
            switch PartsUpload.afterCancel(requested: byUs, inParts: UploadProtocol.resolve(r.protocol)?.inParts == true,
                                           isCommit: part == 0, cancelledError: cancelledError,
                                           otherError: ns != nil && !cancelledError, othersInFlight: r.partTasks != nil) {
            case .cancelled:
                // `committing` stays as it was: a commit cut off may have been applied.
                markCancelled(&r)
                return
            case .ignore:
                store.put(r) // A part landed after the cancel: nothing more goes; the others' ends report it.
                return
            case .asUsual, .confirmOrCancel:
                break // An answered commit is decided in `answered`: finished only if confirmed.
            }
            if let error = ns {
                let (reason, resumable) = Reason.forError(error, cancelledByUs: byUs)
                if reason == Reason.cancelled { markCancelled(&r); return }
                if resumable { interrupt(&r, reason, error.localizedDescription) } else { fail(&r, reason, error.localizedDescription) }
                return
            }
            let http = task.response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if UploadProtocol.resolve(r.protocol) != .firebaseResumable {
                answered(r, part: part, status: status, etag: http?.value(forHTTPHeaderField: "ETag"), body: body)
                return
            }
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
        hold()
        let time = BackgroundTime("BackgroundTransfer session check")
        querySession(url, headers: r.headers) { response, error in
            defer {
                time.end()
                self.release()
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
        // The other parts handed over stop too: starting the upload again asks the server what it holds.
        dropParts(&r)
        r.currentPart = nil
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
        dropParts(&r)
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
        if !stored.isActive { cancelling.remove(stored.key) }
        lastSaved[r.key] = Date()
        listener?.transferChanged(stored, event: event)
        return stored
    }

    /// Progress: told to the app at most four times a second, written to disk every two seconds.
    private func progressed(_ task: URLSessionTask, bytes: Int64, total: Int64) {
        guard let key = task.taskDescription, var r = store.get(key: key),
              r.taskIdentifier == task.taskIdentifier || r.partTasks?[String(task.taskIdentifier)] != nil else { return }
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
        var bytes = r.startOffset + totalBytesSent
        if r.partTasks?[String(task.taskIdentifier)] != nil {
            // One of the parts handed over: the session sends them one by one.
            bytes = PartsUpload.storedBytes(r, size: r.total) + totalBytesSent
        }
        if UploadProtocol.resolve(r.protocol) != .firebaseResumable {
            // Never the whole object before the server has confirmed it (a commit's body isn't file bytes).
            bytes = min(r.currentPart == 0 ? r.total : bytes, max(r.total - 1, 0))
        }
        progressed(task, bytes: bytes, total: r.total)
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
