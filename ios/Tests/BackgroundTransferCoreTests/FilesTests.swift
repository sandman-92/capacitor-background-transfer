import XCTest
@testable import BackgroundTransferCore

final class FilesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pattern(_ n: Int) -> Data {
        Data((0..<n).map { UInt8(($0 * 7 + 13) % 251) })
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testRemainderHoldsExactlyTheBytesAfterTheOffset() throws {
        let data = pattern(1_000_003)
        let source = try write("v.mp4", data)
        let rest = dir.appendingPathComponent("rest/v.remainder")
        // A small piece, so the copy takes many reads.
        let written = try Files.writeRemainder(of: source, from: 262_144, to: rest, piece: 65_536)
        XCTAssertEqual(written, 1_000_003 - 262_144)
        XCTAssertEqual(try Data(contentsOf: rest), data.subdata(in: 262_144..<data.count))
    }

    func testRemainderFromZeroIsTheWholeFileAndFromTheEndIsEmpty() throws {
        let data = pattern(5000)
        let source = try write("v.mp4", data)
        let rest = dir.appendingPathComponent("r")
        try Files.writeRemainder(of: source, from: 0, to: rest)
        XCTAssertEqual(try Data(contentsOf: rest), data)
        XCTAssertEqual(try Files.writeRemainder(of: source, from: 5000, to: rest), 0)
        XCTAssertEqual(try Files.fileSize(rest), 0)
    }

    func testRemainderReplacesAnOldCopy() throws {
        let source = try write("v.mp4", pattern(100))
        let rest = try write("r", pattern(500))
        try Files.writeRemainder(of: source, from: 60, to: rest)
        XCTAssertEqual(try Files.fileSize(rest), 40)
    }

    func testRemainderRefusesAnOffsetPastTheEndAndLeavesNothing() throws {
        let source = try write("v.mp4", pattern(100))
        let rest = dir.appendingPathComponent("r")
        XCTAssertThrowsError(try Files.writeRemainder(of: source, from: 101, to: rest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rest.path))
    }

    func testRemainderOfAMissingFileThrows() {
        XCTAssertThrowsError(try Files.writeRemainder(of: dir.appendingPathComponent("gone"), from: 0, to: dir.appendingPathComponent("r")))
    }

    func testAppendAndFinish() throws {
        let data = pattern(300_000)
        let dest = dir.appendingPathComponent("v.mp4")
        let part = Files.partURL(for: dest)
        XCTAssertEqual(part.lastPathComponent, "v.mp4.part")
        try data.subdata(in: 0..<100_000).write(to: part)
        let piece = try write("piece", data.subdata(in: 100_000..<300_000))
        try Files.append(piece, to: part)
        XCTAssertThrowsError(try Files.finish(part: part, at: dest, size: 300_001), "a short file is never moved into place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        try Files.finish(part: part, at: dest, size: 300_000)
        XCTAssertEqual(try Data(contentsOf: dest), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testFinishReplacesAnOldFile() throws {
        let dest = try write("v.mp4", pattern(10))
        let part = Files.partURL(for: dest)
        try pattern(20).write(to: part)
        try Files.finish(part: part, at: dest, size: 20)
        XCTAssertEqual(try Files.fileSize(dest), 20)
    }

    func testADirectoryIsNotAFile() {
        XCTAssertThrowsError(try Files.fileSize(dir))
    }

    func testContentRange() {
        XCTAssertEqual(ContentRange.parse("bytes 100-199/1000"), ContentRange(start: 100, end: 199, total: 1000))
        XCTAssertEqual(ContentRange.parse("bytes */1000"), ContentRange(start: -1, end: -1, total: 1000))
        XCTAssertEqual(ContentRange.parse("bytes 0-9/*"), ContentRange(start: 0, end: 9, total: -1))
        XCTAssertNil(ContentRange.parse("items 1-2/3"))
        XCTAssertNil(ContentRange.parse("bytes 9-1/10"))
        XCTAssertNil(ContentRange.parse(nil))
    }

    func testRequestedStart() {
        XCTAssertEqual(ContentRange.requestedStart("bytes=3145728-"), 3_145_728)
        XCTAssertEqual(ContentRange.requestedStart(nil), 0)
        XCTAssertEqual(ContentRange.requestedStart("bytes=0-99"), 0)
        XCTAssertEqual(ContentRange.requestedStart("items=5-"), 0)
    }
}

final class ReasonTests: XCTestCase {
    func testStatuses() {
        XCTAssertEqual(Reason.forStatus(404).reason, Reason.sessionExpired)
        XCTAssertEqual(Reason.forStatus(410).reason, Reason.sessionExpired)
        XCTAssertEqual(Reason.forStatus(403).reason, Reason.sessionRefused)
        XCTAssertFalse(Reason.forStatus(403).resumable)
        XCTAssertEqual(Reason.forStatus(503).reason, Reason.serverError)
        XCTAssertTrue(Reason.forStatus(503).resumable)
        XCTAssertTrue(Reason.forStatus(429).resumable)
    }

    func testErrors() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(Reason.forError(cancelled, cancelledByUs: true).reason, Reason.cancelled)
        XCTAssertFalse(Reason.forError(cancelled, cancelledByUs: true).resumable)
        // Swiped away: the system cancels the task; it can carry on next time.
        let swiped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                             userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication])
        XCTAssertEqual(Reason.forError(swiped, cancelledByUs: false).reason, Reason.stoppedBySystem)
        XCTAssertTrue(Reason.forError(swiped, cancelledByUs: false).resumable)
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(Reason.forError(lost, cancelledByUs: false).reason, Reason.network)
        XCTAssertTrue(Reason.forError(lost, cancelledByUs: false).resumable)
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(Reason.forError(full, cancelledByUs: false).reason, Reason.diskFull)
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(Reason.isDiskFull(wrapped))
    }
}

final class StoreTests: XCTestCase {
    func testRecordsSurviveAReloadAndComeBackOldestFirst() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bt-store-\(UUID().uuidString)/transfers.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = TransferStore(file: file)
        var a = TransferRecord(id: "a", direction: .upload, url: "https://x/u", path: "/a")
        a.queuedAt = store.nextQueuedAt()
        a.headers = ["X-A": "1"]
        var b = TransferRecord(id: "a", direction: .download, url: "https://x/d", path: "/b")
        b.queuedAt = store.nextQueuedAt()
        XCTAssertGreaterThan(b.queuedAt, a.queuedAt)
        store.put(b)
        store.put(a)
        let again = TransferStore(file: file)
        XCTAssertEqual(again.all().map(\.key), ["upload:a", "download:a"])
        XCTAssertEqual(again.get(.upload, "a")?.headers, ["X-A": "1"])
        XCTAssertGreaterThan(again.nextQueuedAt(), b.queuedAt)
        again.remove(key: "upload:a")
        XCTAssertNil(TransferStore(file: file).get(.upload, "a"))
    }

    func testJsShapeHasOnlyThePublicFields() {
        var r = TransferRecord(id: "a", direction: .download, url: "u", path: "/p")
        r.reason = Reason.network
        r.remainderPath = "/tmp/x"
        let js = r.js
        XCTAssertEqual(js["reason"] as? String, "network")
        XCTAssertNil(js["remainderPath"])
        XCTAssertNil(js["httpStatus"])
        XCTAssertEqual(js["state"] as? String, "queued")
    }
}

final class FilesRangeTests: XCTestCase {
    func testARangeHoldsExactlyItsBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-range-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data((0..<100_003).map { UInt8(($0 * 7 + 13) % 251) })
        let source = dir.appendingPathComponent("f")
        try data.write(to: source)
        let part = dir.appendingPathComponent("parts/2")
        XCTAssertEqual(try Files.writeRange(of: source, from: 40_000, length: 30_000, to: part, piece: 4096), 30_000)
        XCTAssertEqual(try Data(contentsOf: part), data.subdata(in: 40_000..<70_000))
        XCTAssertEqual(try Files.writeRange(of: source, from: 100_000, length: 3, to: part), 3)
        XCTAssertThrowsError(try Files.writeRange(of: source, from: 100_000, length: 4, to: part))
        XCTAssertEqual(try Files.writeRange(of: source, from: 0, length: 0, to: part), 0)
    }
}
