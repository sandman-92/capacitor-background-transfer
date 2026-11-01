import XCTest
@testable import BackgroundTransferCore

final class PartsUploadTests: XCTestCase {
    let m = UploadOptionsCheck.mib
    lazy var size = 11 * m

    func s3(list: Bool = true) -> TransferRecord {
        var r = TransferRecord(id: "u1", direction: .upload, url: "http://s3/b/k?uploadId=x", path: "/f")
        r.protocol = "s3-multipart"
        r.partUrls = (1...3).map { "http://s3/b/k?partNumber=\($0)&uploadId=x" }
        r.partSize = 5 * m
        if list { r.listPartsUrl = "http://s3/b/k?uploadId=x&list" }
        return r
    }

    func azure() -> TransferRecord {
        var r = TransferRecord(id: "u1", direction: .upload, url: "http://az/acct/c/blob?sv=1&sig=abc", path: "/f")
        r.protocol = "azure-blocks"
        r.blockSize = 5 * m
        return r
    }

    func testAPutIsFinishedOnlyOnA2xx() {
        XCTAssertEqual(PartsUpload.afterPut(status: 200), .finished)
        XCTAssertEqual(PartsUpload.afterPut(status: 201), .finished)
        XCTAssertEqual(PartsUpload.afterPut(status: 403), .failed(reason: Reason.sessionRefused, message: "PUT HTTP 403"))
        XCTAssertEqual(PartsUpload.afterPut(status: 503), .interrupted(reason: Reason.serverError, message: "PUT HTTP 503"))
        let put = PartsUpload.putRequest(TransferRecord(id: "p", direction: .upload, url: "http://x/put", path: "/f"))
        XCTAssertEqual(put?.httpMethod, "PUT")
    }

    func testSendsEachPartInOrderThenCommits() {
        var r = s3()
        XCTAssertEqual(PartsUpload.next(r, size: size), .part(n: 1, offset: 0, length: 5 * m))
        XCTAssertNil(PartsUpload.afterPart(&r, n: 1, status: 200, etag: "\"a\"", size: size))
        XCTAssertEqual(PartsUpload.next(r, size: size), .part(n: 2, offset: 5 * m, length: 5 * m))
        XCTAssertEqual(PartsUpload.partRequest(r, n: 2, size: size)?.url?.absoluteString, "http://s3/b/k?partNumber=2&uploadId=x")
        XCTAssertNil(PartsUpload.afterPart(&r, n: 2, status: 200, etag: "\"b\"", size: size))
        XCTAssertNil(PartsUpload.afterPart(&r, n: 3, status: 200, etag: "\"c\"", size: size))
        XCTAssertEqual(PartsUpload.next(r, size: size), .commit)
        XCTAssertEqual(PartsUpload.storedBytes(r, size: size), size)
        let (request, body) = try! XCTUnwrap(PartsUpload.commitRequest(r, size: size))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("<PartNumber>3</PartNumber><ETag>&quot;c&quot;</ETag>"))
    }

    func testARefusedPartSaysWhichAndAMissingEtagIsNotStored() {
        var r = s3()
        XCTAssertEqual(PartsUpload.afterPart(&r, n: 2, status: 403, etag: nil, size: size),
                       .failed(reason: Reason.sessionRefused, message: "part 2 of 3 HTTP 403"))
        XCTAssertEqual(PartsUpload.afterPart(&r, n: 2, status: 200, etag: nil, size: size),
                       .failed(reason: Reason.unknown, message: "part 2 of 3 answered without an ETag"))
        XCTAssertNil(r.parts?["2"])
        var a = azure()
        XCTAssertEqual(PartsUpload.afterPart(&a, n: 1, status: 403, etag: nil, size: size),
                       .failed(reason: Reason.sessionRefused, message: "block 1 of 3 HTTP 403"))
    }

    func testListPartsDecidesWhatIsStored() {
        var r = s3()
        r.parts = ["1": "\"old1\"", "3": "\"old3\""]
        let xml = "<ListPartsResult><IsTruncated>false</IsTruncated>"
            + "<Part><PartNumber>1</PartNumber><ETag>\"s1\"</ETag><Size>5242880</Size></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>\"s2\"</ETag><Size>100</Size></Part></ListPartsResult>"
        XCTAssertNil(PartsUpload.afterProbe(&r, status: 200, body: Data(xml.utf8), size: size))
        // Part 1 as the server has it; part 2 is short, so it goes again; part 3 the server doesn't hold.
        XCTAssertEqual(r.parts, ["1": "\"s1\""])
        XCTAssertEqual(PartsUpload.afterProbe(&r, status: 404, body: nil, size: size),
                       .failed(reason: Reason.sessionExpired, message: "ListParts HTTP 404"))
        XCTAssertEqual(PartsUpload.afterProbe(&r, status: nil, body: nil, size: size),
                       .interrupted(reason: Reason.network, message: "ListParts: no answer"))
    }

    func testPastATruncatedListTheRecordIsTrusted() {
        var r = s3()
        r.parts = ["3": "\"mine\""]
        let xml = "<ListPartsResult><IsTruncated>true</IsTruncated><Part><PartNumber>1</PartNumber><ETag>\"s1\"</ETag><Size>5242880</Size></Part></ListPartsResult>"
        XCTAssertNil(PartsUpload.afterProbe(&r, status: 200, body: Data(xml.utf8), size: size))
        XCTAssertEqual(r.parts, ["1": "\"s1\"", "3": "\"mine\""])
    }

    func testWithoutAListPartsUrlTheRecordIsAllThereIs() {
        XCTAssertNil(PartsUpload.probe(s3(list: false)))
        XCTAssertEqual(PartsUpload.probe(s3())?.url?.absoluteString, "http://s3/b/k?uploadId=x&list")
    }

    func testTheBlockListDecidesWhatIsStoredAndA403TrustsTheRecord() {
        var r = azure()
        let id1 = PartsXML.blockId(transferId: "u1", size: size, blockSize: 5 * m, n: 1)
        let id2 = PartsXML.blockId(transferId: "u1", size: size, blockSize: 5 * m, n: 2)
        XCTAssertEqual(PartsUpload.probe(r)?.url?.absoluteString, "http://az/acct/c/blob?sv=1&sig=abc&comp=blocklist&blocklisttype=uncommitted")
        let xml = "<BlockList><UncommittedBlocks><Block><Name>\(id1)</Name><Size>5242880</Size></Block>"
            + "<Block><Name>\(id2)</Name><Size>7</Size></Block><Block><Name>other</Name><Size>5242880</Size></Block></UncommittedBlocks></BlockList>"
        XCTAssertNil(PartsUpload.afterProbe(&r, status: 200, body: Data(xml.utf8), size: size))
        XCTAssertEqual(r.parts, ["1": id1])
        r.parts = ["1": id1, "2": "not-ours"]
        XCTAssertNil(PartsUpload.afterProbe(&r, status: 403, body: nil, size: size))
        XCTAssertEqual(r.parts, ["1": id1])
        XCTAssertNil(PartsUpload.afterProbe(&r, status: 404, body: nil, size: size))
        XCTAssertEqual(r.parts, [:])
        XCTAssertEqual(PartsUpload.afterProbe(&r, status: 500, body: nil, size: size),
                       .interrupted(reason: Reason.serverError, message: "Get Block List HTTP 500"))
        let block = PartsUpload.partRequest(r, n: 1, size: size)?.url?.absoluteString ?? ""
        XCTAssertTrue(block.hasPrefix("http://az/acct/c/blob?sv=1&sig=abc&comp=block&blockid="))
        XCTAssertFalse(block.contains("="+"=")) // the id's padding is percent-encoded
    }

    func testTheCommitIsFinishedOnlyWhenTheServerConfirmsIt() {
        var r = s3()
        r.committing = true
        XCTAssertEqual(PartsUpload.afterCommit(&r, status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8)), .finished)
        r.committing = true
        XCTAssertEqual(PartsUpload.afterCommit(&r, status: 200, body: Data("<Error><Code>InternalError</Code></Error>".utf8)),
                       .interrupted(reason: Reason.serverError, message: "complete answered 200 with InternalError"))
        XCTAssertEqual(r.committing, false)
        XCTAssertEqual(PartsUpload.afterCommit(&r, status: 200, body: Data()),
                       .failed(reason: Reason.unknown, message: "complete answered 200 without the completed object"))
        XCTAssertEqual(PartsUpload.afterCommit(&r, status: 403, body: nil), .failed(reason: Reason.sessionRefused, message: "complete HTTP 403"))
        if case .failed(let reason, _) = PartsUpload.afterCommit(&r, status: 404, body: nil) {
            XCTAssertEqual(reason, Reason.sessionClosed)
        } else { XCTFail("a gone upload is failed") }
        var a = azure()
        XCTAssertEqual(PartsUpload.afterCommit(&a, status: 201, body: nil), .finished)
        XCTAssertEqual(PartsUpload.afterCommit(&a, status: 403, body: nil),
                       .failed(reason: Reason.sessionRefused, message: "commit (Put Block List) HTTP 403"))
        XCTAssertEqual(PartsUpload.commitRequest(a, size: size)?.0.url?.absoluteString, "http://az/acct/c/blob?sv=1&sig=abc&comp=blocklist")
    }

    func testACommitAlreadySentIsNeverTakenAsDone() {
        var r = s3()
        r.committing = true
        guard case .failed(let reason, let message) = PartsUpload.beforeStart(r, size: size) else { return XCTFail("expected a stop") }
        XCTAssertEqual(reason, Reason.sessionClosed)
        XCTAssertTrue(message.contains("answer never came"))
        r.committing = nil
        XCTAssertNil(PartsUpload.beforeStart(r, size: size))
        XCTAssertEqual(PartsUpload.beforeStart(r, size: 20 * m),
                       .failed(reason: Reason.sizeMismatch, message: "partUrls holds 3 parts but a 20971520-byte file in 5242880-byte parts needs 4"))
    }

    func testHandedOverPartsAreTrackedByTaskAndCommitWaitsForAll() {
        var r = s3()
        XCTAssertEqual(PartsUpload.pending(r, size: size).count, 3)
        XCTAssertEqual(PartsUpload.pendingBytes(r, size: size), size)
        PartsUpload.assign(&r, task: 7, part: 1, copy: "/c/1")
        PartsUpload.assign(&r, task: 8, part: 2, copy: "/c/2")
        PartsUpload.assign(&r, task: 9, part: 3, copy: "/c/3")
        XCTAssertEqual(PartsUpload.inFlight(r), [1, 2, 3])
        XCTAssertEqual(PartsUpload.pendingBytes(r, size: size), 0)
        XCTAssertNil(PartsUpload.next(r, size: size), "no commit while parts are in tasks")
        XCTAssertEqual(Set(PartsUpload.copies(r)), ["/c/1", "/c/2", "/c/3"])
        // Answers in any order land against the part each task carried.
        let third = PartsUpload.release(&r, task: 9)
        XCTAssertEqual(third, PartTask(part: 3, copy: "/c/3"))
        XCTAssertNil(PartsUpload.afterPart(&r, n: third!.part, status: 200, etag: "\"c\"", size: size))
        XCTAssertNil(PartsUpload.release(&r, task: 42), "an unknown task carries nothing")
        let first = PartsUpload.release(&r, task: 7)!
        XCTAssertNil(PartsUpload.afterPart(&r, n: first.part, status: 200, etag: "\"a\"", size: size))
        XCTAssertNil(PartsUpload.next(r, size: size))
        let second = PartsUpload.release(&r, task: 8)!
        XCTAssertNil(PartsUpload.afterPart(&r, n: second.part, status: 200, etag: "\"b\"", size: size))
        XCTAssertNil(r.partTasks)
        XCTAssertEqual(r.parts, ["1": "\"a\"", "2": "\"b\"", "3": "\"c\""])
        XCTAssertEqual(PartsUpload.next(r, size: size), .commit)
    }

    func testAPartStillPendingIsHandedOverOnlyOnce() {
        var r = s3()
        r.parts = ["1": "\"a\""]
        PartsUpload.assign(&r, task: 1, part: 2, copy: "/c/2")
        XCTAssertEqual(PartsUpload.pending(r, size: size), [.part(n: 3, offset: 10 * m, length: m)])
        XCTAssertEqual(PartsUpload.next(r, size: size), .part(n: 3, offset: 10 * m, length: m))
        XCTAssertEqual(PartsUpload.pendingBytes(r, size: size), m)
    }

    func testTheHandOverNeedsTheRemainingBytesAndAMarginFree() {
        let margin = PartsUpload.diskMargin
        XCTAssertTrue(PartsUpload.handOverFits(bytes: 100 * m, free: 100 * m + margin))
        XCTAssertFalse(PartsUpload.handOverFits(bytes: 100 * m, free: 100 * m + margin - 1))
        XCTAssertFalse(PartsUpload.handOverFits(bytes: 0, free: margin - 1))
    }

    func testARecordWithHandedOverPartsSurvivesTheStore() throws {
        var r = s3()
        PartsUpload.assign(&r, task: 3, part: 2, copy: "/c/2")
        let back = try JSONDecoder().decode(TransferRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.partTasks, ["3": PartTask(part: 2, copy: "/c/2")])
        XCTAssertNil(r.js["partTasks"])
    }

    func testOnlyACancelledTaskReadsAsTheAppsCancel() {
        typealias A = PartsUpload.AfterCancel
        func after(_ requested: Bool, commit: Bool = false, cancelled: Bool = false, other: Bool = false, others: Bool = false) -> A {
            PartsUpload.afterCancel(requested: requested, isCommit: commit, cancelledError: cancelled, otherError: other, othersInFlight: others)
        }
        XCTAssertEqual(after(false, cancelled: true), .asUsual, "a cancel nobody asked for is the system's")
        XCTAssertEqual(after(true, cancelled: true, others: true), .cancelled)
        XCTAssertEqual(after(true, others: true), .ignore, "a part that landed anyway starts nothing more")
        XCTAssertEqual(after(true, others: false), .cancelled, "the last task out reports the cancel")
        XCTAssertEqual(after(true, commit: true), .asUsual, "a commit's answer still decides")
        XCTAssertEqual(after(true, other: true, others: true), .asUsual, "a refusal is reported as it is")
    }

    func testPartsCarryOverOnlyForTheSameRanges() {
        let existing = { () -> TransferRecord in var e = self.s3(); e.total = self.size; e.parts = ["1": "\"a\""]; return e }()
        XCTAssertTrue(PartsUpload.carriesOver(existing, s3(), fileSize: size))
        var otherSize = s3()
        otherSize.partSize = 6 * m
        XCTAssertFalse(PartsUpload.carriesOver(existing, otherSize, fileSize: size), "another part size covers other ranges")
        XCTAssertFalse(PartsUpload.carriesOver(existing, s3(), fileSize: size + 1), "the file changed")
        var otherUrl = s3()
        otherUrl.url = "http://s3/b/k?uploadId=y"
        XCTAssertFalse(PartsUpload.carriesOver(existing, otherUrl, fileSize: size))
        XCTAssertFalse(PartsUpload.carriesOver(nil, s3(), fileSize: size))
        var a = azure()
        a.total = size
        var b = azure()
        b.blockSize = 4 * m
        XCTAssertFalse(PartsUpload.carriesOver(a, b, fileSize: size))
        XCTAssertTrue(PartsUpload.carriesOver(a, azure(), fileSize: size))
    }

    func testTheBlobsPropertiesGoOnlyWithTheCommit() {
        var r = azure()
        r.headers = ["x-ms-blob-content-type": "video/mp4", "X-Custom": "1"]
        let block = PartsUpload.partRequest(r, n: 1, size: size)!
        XCTAssertNil(block.value(forHTTPHeaderField: "x-ms-blob-content-type"))
        XCTAssertEqual(block.value(forHTTPHeaderField: "X-Custom"), "1")
        let commit = PartsUpload.commitRequest(r, size: size)!.0
        XCTAssertEqual(commit.value(forHTTPHeaderField: "x-ms-blob-content-type"), "video/mp4")
        var s = s3()
        s.headers = ["x-ms-blob-content-type": "kept"]
        XCTAssertEqual(PartsUpload.partRequest(s, n: 1, size: size)?.value(forHTTPHeaderField: "x-ms-blob-content-type"), "kept")
    }
}
