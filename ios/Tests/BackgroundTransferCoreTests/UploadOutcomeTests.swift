import XCTest
@testable import BackgroundTransferCore

final class UploadOutcomeTests: XCTestCase {
    let total: Int64 = 1000

    func testACleanFinalizeOfTheWholeFileIsFinished() {
        let body = #"{"name":"sessions/x/source","size":"1000"}"#.data(using: .utf8)
        XCTAssertEqual(UploadOutcome.afterResponse(status: 200, uploadStatus: "final", received: 1000, body: body, total: total), .finished)
        XCTAssertEqual(UploadOutcome.afterResponse(status: 200, uploadStatus: nil, received: nil, body: nil, total: total), .finished)
    }

    func testAFinalizedObjectOfTheWrongSizeIsNeverFinished() {
        // A stale resend accepted and appended leaves a bigger object.
        let body = #"{"size":"1500"}"#.data(using: .utf8)
        guard case .failed(let reason, _) = UploadOutcome.afterResponse(status: 200, uploadStatus: "final", received: nil, body: body, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(reason, Reason.sizeMismatch)
        guard case .failed(let r2, _) = UploadOutcome.afterResponse(status: 200, uploadStatus: "final", received: 1500, body: nil, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(r2, Reason.sizeMismatch)
        guard case .failed(let r3, _) = UploadOutcome.afterResponse(status: 200, uploadStatus: "active", received: 900, body: nil, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(r3, Reason.sizeMismatch)
    }

    func testAGoneSessionFailsWithoutAsking() {
        guard case .failed(let reason, _) = UploadOutcome.afterResponse(status: 404, uploadStatus: nil, received: nil, body: nil, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(reason, Reason.sessionExpired)
    }

    func testAnyOtherRefusalAsksTheSession() {
        for status in [400, 403, 409, 500, 503] {
            XCTAssertEqual(UploadOutcome.afterResponse(status: status, uploadStatus: nil, received: nil, body: nil, total: total), .query)
        }
    }

    func testAStaleResendRefusedWhileTheSessionIsStillOpenIsInterrupted() {
        // The system resent the request with its old offset; the server already held 400 bytes and said 400.
        guard case .interrupted(let reason, _) = UploadOutcome.afterQuery(originalStatus: 400, queryStatus: 200, received: 400,
                                                                          uploadStatus: "active", total: total) else {
            return XCTFail("expected interrupted")
        }
        XCTAssertEqual(reason, Reason.network)
    }

    func testAQueryWithNoResponseIsInterrupted() {
        guard case .interrupted(let reason, _) = UploadOutcome.afterQuery(originalStatus: 400, queryStatus: nil, received: nil,
                                                                          uploadStatus: nil, total: total) else {
            return XCTFail("expected interrupted")
        }
        XCTAssertEqual(reason, Reason.network)
    }

    func testTheRulesRefusingAtFinalizeStaysRefused() {
        // Finalize got 403; the session is gone or refuses the query too.
        guard case .failed(let reason, _) = UploadOutcome.afterQuery(originalStatus: 403, queryStatus: 403, received: nil,
                                                                     uploadStatus: nil, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(reason, Reason.sessionRefused)
        guard case .failed(let r2, _) = UploadOutcome.afterQuery(originalStatus: 403, queryStatus: 404, received: nil,
                                                                 uploadStatus: nil, total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(r2, Reason.sessionExpired)
    }

    func testARefusedFinalizeOfAClosedSessionIsNeverFinished() {
        // The rules refused the object at finalize; the session reads as closed with every byte.
        guard case .failed(let r1, _) = UploadOutcome.afterQuery(originalStatus: 403, queryStatus: 200, received: 1000,
                                                                 uploadStatus: "final", total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(r1, Reason.sessionRefused)
        guard case .failed(let reason, _) = UploadOutcome.afterQuery(originalStatus: 503, queryStatus: 200, received: 1200,
                                                                     uploadStatus: "final", total: total) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(reason, Reason.sizeMismatch)
    }

    func testAClosedSessionAtTheStartIsNeverFinished() {
        // Even at the file's full size: a server may close a session whose finalize it refused.
        for received in [Int64(1000), 400] {
            guard case .failed(let reason, _) = UploadOutcome.beforeSending(received: received, uploadStatus: "final", total: total)! else {
                return XCTFail("expected failed")
            }
            XCTAssertEqual(reason, Reason.sessionClosed)
        }
        guard case .failed(let r2, _) = UploadOutcome.beforeSending(received: 1200, uploadStatus: "active", total: total)! else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(r2, Reason.sizeMismatch)
        XCTAssertNil(UploadOutcome.beforeSending(received: 400, uploadStatus: "active", total: total))
        XCTAssertNil(UploadOutcome.beforeSending(received: 0, uploadStatus: nil, total: total))
    }

    func testARefusalBeingCheckedSurvivesAReload() throws {
        var r = TransferRecord(id: "a", direction: .upload, url: "u", path: "/p")
        r.refusedStatus = 403
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(TransferRecord.self, from: data).refusedStatus, 403)
        XCTAssertNil(r.js["refusedStatus"])
    }

    func testASessionCheckEndsWellInsideABackgroundRelaunch() {
        // A relaunched app gets about 30 s; the held completion handler waits for the check.
        XCTAssertEqual(UploadOutcome.checkTimeout, 20)
        XCTAssertLessThan(UploadOutcome.checkTimeout, 30)
    }

    func testObjectSize() {
        XCTAssertEqual(UploadOutcome.objectSize(#"{"size":"42"}"#.data(using: .utf8)), 42)
        XCTAssertEqual(UploadOutcome.objectSize(#"{"size":42}"#.data(using: .utf8)), 42)
        XCTAssertNil(UploadOutcome.objectSize(Data("not json".utf8)))
        XCTAssertNil(UploadOutcome.objectSize(nil))
    }
}

final class OrphanTests: XCTestCase {
    func testRemainderCopiesNoRecordNamesAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-orphans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kept = dir.appendingPathComponent("kept")
        let orphan = dir.appendingPathComponent("left-by-a-killed-copy")
        try Data("a".utf8).write(to: kept)
        try Data("b".utf8).write(to: orphan)
        let removed = Files.removeOrphans(in: dir, keeping: [kept.path])
        XCTAssertEqual(removed.map(\.lastPathComponent), ["left-by-a-killed-copy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(Files.removeOrphans(in: dir.appendingPathComponent("missing"), keeping: []), [])
    }
}
