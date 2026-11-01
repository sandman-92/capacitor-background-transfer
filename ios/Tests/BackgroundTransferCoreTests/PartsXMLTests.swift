import XCTest
@testable import BackgroundTransferCore

final class PartsXMLTests: XCTestCase {
    func testReadsListPartsWithItsEntitiesAndPaging() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>b</Bucket><IsTruncated>true</IsTruncated>\
        <Part><PartNumber>1</PartNumber><ETag>&#34;aa&#34;</ETag><Size>5242880</Size></Part>\
        <Part><PartNumber>3</PartNumber><ETag>&quot;cc&quot;</ETag><Size>100</Size></Part></ListPartsResult>
        """
        let l = try XCTUnwrap(PartsXML.listParts(Data(xml.utf8)))
        XCTAssertTrue(l.truncated)
        XCTAssertEqual(l.highest, 3)
        XCTAssertEqual(l.parts[1]?.tag, "\"aa\"")
        XCTAssertEqual(l.parts[1]?.size, 5_242_880)
        XCTAssertEqual(l.parts[3]?.tag, "\"cc\"")
        XCTAssertNil(l.parts[2])
        XCTAssertNil(PartsXML.listParts(Data("<ListPartsResult><Part>".utf8)))
    }

    func testListsEveryPartInTheCompletion() {
        let body = PartsXML.completeBody(etags: ["2": "\"b\"", "1": "\"a&\""], count: 2)
        XCTAssertEqual(String(data: body, encoding: .utf8),
                       "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>"
                       + "<Part><PartNumber>1</PartNumber><ETag>&quot;a&amp;&quot;</ETag></Part>"
                       + "<Part><PartNumber>2</PartNumber><ETag>&quot;b&quot;</ETag></Part></CompleteMultipartUpload>")
    }

    func testTellsACompletedObjectFromAnErrorAnsweredWith200() {
        XCTAssertTrue(PartsXML.isCompleteResult(Data("<CompleteMultipartUploadResult><ETag>x</ETag></CompleteMultipartUploadResult>".utf8)))
        let error = Data("<?xml version=\"1.0\"?>\n<Error><Code>InternalError</Code><Message>m</Message></Error>".utf8)
        XCTAssertFalse(PartsXML.isCompleteResult(error))
        XCTAssertEqual(PartsXML.errorCode(error), "InternalError")
        XCTAssertFalse(PartsXML.isCompleteResult(Data()))
        XCTAssertNil(PartsXML.errorCode(Data("<CompleteMultipartUploadResult/>".utf8)))
    }

    func testReadsTheUncommittedBlocks() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><CommittedBlocks><Block><Name>Yw==</Name><Size>1</Size></Block></CommittedBlocks>"
            + "<UncommittedBlocks><Block><Name>QQ==</Name><Size>5</Size></Block><Block><Name>Qg==</Name><Size>6</Size></Block></UncommittedBlocks></BlockList>"
        let blocks = try XCTUnwrap(PartsXML.uncommittedBlocks(Data(xml.utf8)))
        XCTAssertEqual(blocks, ["QQ==": 5, "Qg==": 6])
        XCTAssertEqual(PartsXML.uncommittedBlocks(Data("<BlockList><UncommittedBlocks /></BlockList>".utf8)), [:])
    }

    func testBlockIdsAreStableTheSameLengthAndAsAndroidMakesThem() {
        let m = UploadOptionsCheck.mib
        let id = PartsXML.blockId(transferId: "clip-42", size: 12 * m, blockSize: 5 * m, n: 3)
        // The same value is asserted in the Android tests.
        XCTAssertEqual(id, "MTE4NGE1YmM0YjAxOGU3OC0wMDAwMDM=")
        XCTAssertNotEqual(id, PartsXML.blockId(transferId: "clip-43", size: 12 * m, blockSize: 5 * m, n: 3))
        XCTAssertEqual(id.count, PartsXML.blockId(transferId: "clip-42", size: 1, blockSize: 1, n: 999_999).count)
        XCTAssertEqual(String(data: PartsXML.blockListBody(["QQ==", "Qg=="]), encoding: .utf8),
                       "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>QQ==</Latest><Latest>Qg==</Latest></BlockList>")
    }
}
