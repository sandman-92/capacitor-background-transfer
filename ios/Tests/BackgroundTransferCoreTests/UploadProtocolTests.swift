import XCTest
@testable import BackgroundTransferCore

final class UploadProtocolTests: XCTestCase {
    func testNoProtocolMeansFirebaseResumable() {
        XCTAssertEqual(UploadProtocol.resolve(nil), .firebaseResumable)
        XCTAssertEqual(UploadProtocol.resolve("firebase-resumable"), .firebaseResumable)
    }

    func testAnUnknownProtocolIsRefused() {
        XCTAssertNil(UploadProtocol.resolve("gcs-resumable"))
        XCTAssertNil(UploadProtocol.resolve(""))
        XCTAssertEqual(UploadProtocol.refusal, "protocol must be one of firebase-resumable, put, s3-multipart, azure-blocks")
    }

    func testTheNewProtocolsResolve() {
        XCTAssertEqual(UploadProtocol.resolve("put"), .put)
        XCTAssertEqual(UploadProtocol.resolve("s3-multipart"), .s3Multipart)
        XCTAssertEqual(UploadProtocol.resolve("azure-blocks"), .azureBlocks)
        XCTAssertTrue(UploadProtocol.s3Multipart.inParts)
        XCTAssertFalse(UploadProtocol.put.inParts)
    }

    func testARecordWithPartsSurvivesTheStoreAndAnOldOneStillReads() throws {
        var r = TransferRecord(id: "a", direction: .upload, url: "u", path: "/p")
        r.protocol = "s3-multipart"
        r.partUrls = ["http://x/1", "http://x/2"]
        r.partSize = 5 * 1024 * 1024
        r.parts = ["1": "\"e1\""]
        r.committing = true
        r.currentPart = 2
        let back = try JSONDecoder().decode(TransferRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertNil(r.js["partUrls"])
        XCTAssertNil(r.js["parts"])
        // A record written before these fields existed.
        let old = #"[{"id":"o","direction":"upload","state":"finished","url":"u","path":"/p","bytes":1,"total":1,"updatedAt":0,"queuedAt":0,"headers":{},"startOffset":0}]"#
        let list = try JSONDecoder().decode([TransferRecord].self, from: Data(old.utf8))
        XCTAssertNil(list[0].parts)
        XCTAssertNil(list[0].committing)
    }

    func testARecordKeepsItsProtocolAndShowsItToJavaScript() throws {
        var r = TransferRecord(id: "a", direction: .upload, url: "u", path: "/p")
        r.protocol = UploadProtocol.firebaseResumable.rawValue
        let back = try JSONDecoder().decode(TransferRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.protocol, "firebase-resumable")
        XCTAssertEqual(r.js["protocol"] as? String, "firebase-resumable")
        XCTAssertNil(TransferRecord(id: "d", direction: .download, url: "u", path: "/p").js["protocol"])
    }
}
