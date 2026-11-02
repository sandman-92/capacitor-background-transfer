import XCTest
@testable import BackgroundTransferCore

/// The same refusals, in the same words, as validate.test.ts and the Android tests.
final class UploadOptionsCheckTests: XCTestCase {
    let mib = Double(UploadOptionsCheck.mib)
    let sas = "https://acct.blob.core.windows.net/c/blob.bin?sv=2021-08-06&sr=b&sp=cw&sig=abc%3D"
    let two: [Any] = ["https://s3/b/k?partNumber=1", "https://s3/b/k?partNumber=2"]
    let complete = "https://s3/b/k?uploadId=x"

    private func check(_ p: UploadProtocol, _ url: String, parts: [Any]? = nil, partSize: Double? = nil, list: Any? = nil,
                       block: Double? = nil) -> String? {
        UploadOptionsCheck.check(protocol: p, url: url, partUrls: parts, partSize: partSize, listPartsUrl: list, blockSize: block)
    }

    func testAcceptsWellFormedOptions() {
        XCTAssertNil(check(.put, "https://x/put"))
        XCTAssertNil(check(.s3Multipart, complete, parts: two))
        XCTAssertNil(check(.s3Multipart, complete, parts: two, partSize: 5 * mib, list: complete))
        XCTAssertNil(check(.s3Multipart, complete, parts: ["https://s3/1"], partSize: 1000))
        XCTAssertNil(check(.azureBlocks, sas, block: 1024))
    }

    func testRefusesWhatTheWebRefuses() {
        XCTAssertEqual(check(.s3Multipart, complete), "partUrls is required for s3-multipart")
        XCTAssertEqual(check(.s3Multipart, complete, parts: []), "partUrls is required for s3-multipart")
        XCTAssertEqual(check(.s3Multipart, complete, parts: ["https://s3/1", "ftp://x/2"]), "partUrls must be http or https URLs")
        XCTAssertEqual(check(.s3Multipart, complete, parts: ["https://s3/1", 7]), "partUrls must be http or https URLs")
        XCTAssertEqual(check(.s3Multipart, complete, parts: Array(repeating: "https://s3/1", count: 10_001)), "partUrls holds more than 10000 parts")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, partSize: 5 * mib - 1), "partSize must be at least 5 MiB when there is more than one part")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, partSize: 0), "partSize must be a whole number of bytes up to 5 GiB")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, partSize: 5.5 * mib + 0.5), "partSize must be a whole number of bytes up to 5 GiB")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, partSize: 5 * 1024 * mib + 1), "partSize must be a whole number of bytes up to 5 GiB")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, list: "list"), "listPartsUrl must be an http or https URL")
        XCTAssertEqual(check(.put, "https://x/put", parts: two), "partUrls, partSize and listPartsUrl are only for s3-multipart")
        XCTAssertEqual(check(.azureBlocks, sas, partSize: 8 * mib), "partUrls, partSize and listPartsUrl are only for s3-multipart")
        XCTAssertEqual(check(.s3Multipart, complete, parts: two, block: 8 * mib), "blockSize is only for azure-blocks")
        XCTAssertEqual(check(.firebaseResumable, "https://x/u", block: 1), "blockSize is only for azure-blocks")
        XCTAssertEqual(check(.azureBlocks, "https://acct/c/blob"), "url must be a blob SAS URL (with a sig parameter)")
        XCTAssertEqual(check(.azureBlocks, "https://acct/c/blob?sv=1&sig="), "url must be a blob SAS URL (with a sig parameter)")
        XCTAssertEqual(check(.azureBlocks, sas + "&comp=block"), "url must be a blob SAS URL (with a sig parameter)")
        XCTAssertEqual(check(.azureBlocks, sas, block: 4000 * mib + 1), "blockSize must be a whole number of bytes up to 4000 MiB")
        XCTAssertEqual(check(.azureBlocks, sas, block: -1), "blockSize must be a whole number of bytes up to 4000 MiB")
    }

    func testThePartCountMustFitTheFile() {
        let m = UploadOptionsCheck.mib
        XCTAssertNil(UploadOptionsCheck.checkSize(protocol: .s3Multipart, partUrlCount: 3, partSize: 5 * m, blockSize: 0, fileSize: 11 * m))
        XCTAssertNil(UploadOptionsCheck.checkSize(protocol: .s3Multipart, partUrlCount: 1, partSize: 5 * m, blockSize: 0, fileSize: 0))
        XCTAssertEqual(UploadOptionsCheck.checkSize(protocol: .s3Multipart, partUrlCount: 2, partSize: 5 * m, blockSize: 0, fileSize: 11 * m),
                       "partUrls holds 2 parts but a 11534336-byte file in 5242880-byte parts needs 3")
        XCTAssertEqual(UploadOptionsCheck.checkSize(protocol: .s3Multipart, partUrlCount: 10_000, partSize: 5 * m, blockSize: 0, fileSize: 51_200 * m + 1),
                       "a 53687091201-byte file in 5242880-byte parts needs more than 10000 parts")
        XCTAssertNil(UploadOptionsCheck.checkSize(protocol: .azureBlocks, partUrlCount: 0, partSize: 0, blockSize: m, fileSize: 50_000 * m))
        XCTAssertEqual(UploadOptionsCheck.checkSize(protocol: .azureBlocks, partUrlCount: 0, partSize: 0, blockSize: m, fileSize: 50_000 * m + 1),
                       "a 52428800001-byte file in 1048576-byte blocks needs more than 50000 blocks")
    }

    func testPartsCoverTheFile() {
        let m = UploadOptionsCheck.mib
        XCTAssertEqual(PartPlan.count(size: 11 * m, partSize: 5 * m, atLeastOne: true), 3)
        XCTAssertEqual(PartPlan.count(size: 0, partSize: 5 * m, atLeastOne: true), 1)
        XCTAssertEqual(PartPlan.count(size: 0, partSize: 5 * m, atLeastOne: false), 0)
        XCTAssertEqual(PartPlan.offset(3, partSize: 5 * m), 10 * m)
        XCTAssertEqual(PartPlan.length(3, size: 11 * m, partSize: 5 * m), m)
    }
}
