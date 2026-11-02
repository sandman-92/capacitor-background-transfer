import XCTest
@testable import BackgroundTransferCore

final class UploadProtocolTests: XCTestCase {
    func testNoProtocolMeansFirebaseResumable() {
        XCTAssertEqual(UploadProtocol.resolve(nil), .firebaseResumable)
        XCTAssertEqual(UploadProtocol.resolve("firebase-resumable"), .firebaseResumable)
    }

    func testAnUnknownProtocolIsRefused() {
        XCTAssertNil(UploadProtocol.resolve("s3-multipart"))
        XCTAssertNil(UploadProtocol.resolve(""))
        XCTAssertEqual(UploadProtocol.refusal, "protocol must be one of firebase-resumable")
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
