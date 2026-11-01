import CryptoKit
import XCTest
@testable import BackgroundTransferCore

/// Each protocol's steps against real servers: MinIO for S3, Azurite for Azure, behind the
/// harness's recording proxy (test-servers/). The requests go as `TransferManager` makes them,
/// from the same temporary copies, on a plain session instead of a background one. Skipped unless
/// `BT_HARNESS` is set (`npm run test:servers` sets it).
final class ServersTests: XCTestCase {
    static let base = ProcessInfo.processInfo.environment["BT_HARNESS"] ?? ""
    let m = UploadOptionsCheck.mib
    lazy var size = 11 * m
    var dir: URL!
    var file: URL!
    var data = Data()
    var object = ""
    let session = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        try XCTSkipIf(Self.base.isEmpty, "BT_HARNESS is not set")
        _ = try await harness("POST", "/reset", [:])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var g = SystemRandomNumberGenerator()
        data = Data((0..<Int(size)).map { _ in UInt8.random(in: 0...255, using: &g) })
        file = dir.appendingPathComponent("upload.bin")
        try data.write(to: file)
    }

    override func tearDown() async throws {
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        if !Self.base.isEmpty { _ = try? await harness("POST", "/reset", [:]) }
    }

    // MARK: The harness

    @discardableResult
    func harness(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = method
        if let body = body, method == "POST" {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else { throw NSError(domain: "harness", code: status, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    func upload(_ p: UploadProtocol, _ options: [String: Any] = [:]) async throws -> TransferRecord {
        var r = TransferRecord(id: "t-\(p.rawValue)", direction: .upload, url: "", path: file.path)
        r.protocol = p.rawValue
        switch p {
        case .put:
            let put = try await harness("POST", "/s3/put", options)
            object = put["key"] as! String
            r.url = put["url"] as! String
        case .s3Multipart:
            var o = options
            o["size"] = size
            o["partSize"] = 5 * m
            let made = try await harness("POST", "/s3/multipart", o)
            object = made["key"] as! String
            r.url = made["url"] as! String
            r.partUrls = made["partUrls"] as? [String]
            r.partSize = 5 * m
            if options["noListParts"] == nil { r.listPartsUrl = made["listPartsUrl"] as? String }
        default:
            let blob = try await harness("POST", "/azure/blob", options)
            object = blob["name"] as! String
            r.url = blob["url"] as! String
            r.blockSize = 5 * m
        }
        return r
    }

    func stored(_ p: UploadProtocol) async throws -> [String: Any] {
        let name = object.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return try await harness("GET", p == .azureBlocks ? "/azure/blob?name=\(name)" : "/s3/object?key=\(name)", nil)
    }

    func assertStoredWhole(_ p: UploadProtocol, file: StaticString = #filePath, line: UInt = #line) async throws {
        let o = try await stored(p)
        XCTAssertEqual(o["exists"] as? Bool, true, "the object is on the server", file: file, line: line)
        XCTAssertEqual((o["size"] as? NSNumber)?.int64Value, size, file: file, line: line)
        XCTAssertEqual(o["sha256"] as? String, sha256(data), file: file, line: line)
    }

    func requests(_ p: UploadProtocol) async throws -> [[String: Any]] {
        (try await harness("GET", "/requests?target=\(p == .azureBlocks ? "azure" : "s3")", nil))["requests"] as? [[String: Any]] ?? []
    }

    func sends(_ p: UploadProtocol, part n: Int) async throws -> Int {
        let id = PartsXML.blockId(transferId: "t-\(p.rawValue)", size: size, blockSize: 5 * m, n: n)
        return try await requests(p).filter { q in
            guard q["method"] as? String == "PUT" else { return false }
            switch p {
            case .s3Multipart: return (q["partNumber"] as? Int) == n
            case .azureBlocks: return (q["blockid"] as? String) == id
            default: return true
            }
        }.count
    }

    // MARK: Running the steps

    /// One run of an upload, as `TransferManager` makes it: the probe, each part from a temporary
    /// copy of its range, the commit marked as sent before it goes. Returns how it ended.
    func run(_ r: inout TransferRecord) async throws -> UploadOutcome {
        let p = UploadProtocol.resolve(r.protocol)!
        let total = try Files.fileSize(file)
        if p == .put {
            guard let request = PartsUpload.putRequest(r) else { return .failed(reason: Reason.sessionRefused, message: "not a URL") }
            guard let (status, _, _) = try await send(request, from: file) else {
                return .interrupted(reason: Reason.network, message: "PUT: no answer")
            }
            return PartsUpload.afterPut(status: status)
        }
        if let stop = PartsUpload.beforeStart(r, size: total) { return stop }
        if let probe = PartsUpload.probe(r) {
            let answer = try? await session.data(for: probe)
            let status = (answer?.1 as? HTTPURLResponse)?.statusCode
            if let stop = PartsUpload.afterProbe(&r, status: status, body: answer?.0, size: total) { return stop }
        }
        while true {
            switch PartsUpload.next(r, size: total) {
            case .part(let n, let offset, let length):
                let copy = dir.appendingPathComponent("remainders/\(UUID().uuidString)")
                try Files.writeRange(of: file, from: offset, length: length, to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                guard let request = PartsUpload.partRequest(r, n: n, size: total) else { return .failed(reason: Reason.unknown, message: "no URL") }
                guard let (status, etag, _) = try await send(request, from: copy) else {
                    return .interrupted(reason: Reason.network, message: "part \(n): no answer")
                }
                if let stop = PartsUpload.afterPart(&r, n: n, status: status, etag: etag, size: total) { return stop }
            case .commit:
                let (request, body) = PartsUpload.commitRequest(r, size: total)!
                let copy = dir.appendingPathComponent("remainders/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                r.committing = true
                guard let (status, _, answer) = try await send(request, from: copy) else {
                    return .interrupted(reason: Reason.network, message: "commit: no answer")
                }
                return PartsUpload.afterCommit(&r, status: status, body: answer)
            }
        }
    }

    /// Nil when no answer came.
    func send(_ request: URLRequest, from source: URL) async throws -> (Int, String?, Data)? {
        do {
            let (body, response) = try await session.upload(for: request, fromFile: source)
            let http = response as! HTTPURLResponse
            return (http.statusCode, http.value(forHTTPHeaderField: "ETag"), body)
        } catch let e as URLError {
            _ = e
            return nil
        }
    }

    func onCommit(_ p: UploadProtocol, _ fault: [String: Any]) -> [String: Any] {
        var f = fault
        switch p {
        case .s3Multipart: f["target"] = "s3"; f["method"] = "POST"
        case .azureBlocks: f["target"] = "azure"; f["method"] = "PUT"; f["query"] = "comp=blocklist"
        default: f["target"] = "s3"; f["method"] = "PUT"
        }
        return f
    }

    func onSecondPart(_ p: UploadProtocol, _ fault: [String: Any]) -> [String: Any] {
        var f = fault
        switch p {
        case .s3Multipart: f["target"] = "s3"; f["method"] = "PUT"; f["query"] = "partNumber=2&"
        case .azureBlocks: f["target"] = "azure"; f["method"] = "PUT"; f["query"] = "comp=block&"; f["skip"] = 1
        default: f["target"] = "s3"; f["method"] = "PUT"
        }
        return f
    }

    static let protocols: [UploadProtocol] = [.put, .s3Multipart, .azureBlocks]

    // MARK: The criteria

    func testStoresTheWholeObject() async throws {
        for p in Self.protocols {
            var r = try await upload(p)
            let outcome = try await run(&r)
            XCTAssertEqual(outcome, .finished, p.rawValue)
            try await assertStoredWhole(p)
            if p != .put {
                for n in 1...3 { let s = try await sends(p, part: n); XCTAssertEqual(s, 1, "\(p.rawValue) part \(n)") }
            }
            _ = try await harness("POST", "/reset", [:])
        }
    }

    func testAnInterruptedUploadResumesWithoutResendingWhatIsStored() async throws {
        for p in Self.protocols {
            var r = try await upload(p)
            _ = try await harness("POST", "/faults", onSecondPart(p, ["action": "cut", "after": 3 * m]))
            let first = try await run(&r)
            guard case .interrupted(let reason, _) = first else { XCTFail("\(p.rawValue): \(first)"); continue }
            XCTAssertEqual(reason, Reason.network)
            let second = try await run(&r)
            XCTAssertEqual(second, .finished, p.rawValue)
            try await assertStoredWhole(p)
            if p == .put {
                let puts = try await sends(p, part: 1)
                XCTAssertEqual(puts, 2)
            } else {
                let one = try await sends(p, part: 1), two = try await sends(p, part: 2)
                XCTAssertEqual(one, 1, "\(p.rawValue): part 1 is not sent again")
                XCTAssertEqual(two, 2)
            }
            _ = try await harness("POST", "/reset", [:])
        }
    }

    func testAnExpiredUrlFailsAndSaysWhichRequest() async throws {
        for p in Self.protocols {
            var r = try await upload(p, ["expires": p == .azureBlocks ? -60 : 1, "noListParts": true])
            try await Task.sleep(nanoseconds: 2_100_000_000)
            let outcome = try await run(&r)
            let which = p == .s3Multipart ? "part 1 of 3" : p == .azureBlocks ? "block 1 of 3" : "PUT"
            XCTAssertEqual(outcome, .failed(reason: Reason.sessionRefused, message: "\(which) HTTP 403"), p.rawValue)
            let o = try await stored(p)
            XCTAssertEqual(o["exists"] as? Bool, false)
        }
    }

    func testARefusedCommitFailsAndSaysSo() async throws {
        for p in Self.protocols {
            var r = try await upload(p)
            _ = try await harness("POST", "/faults", onCommit(p, ["action": "status", "status": 403]))
            let outcome = try await run(&r)
            let which = p == .s3Multipart ? "complete" : p == .azureBlocks ? "commit (Put Block List)" : "PUT"
            XCTAssertEqual(outcome, .failed(reason: Reason.sessionRefused, message: "\(which) HTTP 403"), p.rawValue)
            XCTAssertNotEqual(r.committing, true)
            _ = try await harness("POST", "/reset", [:])
        }
    }

    func testALostCommitAnswerIsNeverTakenAsFinished() async throws {
        for p in Self.protocols {
            var r = try await upload(p)
            _ = try await harness("POST", "/faults", onCommit(p, ["action": "drop-answer"]))
            let first = try await run(&r)
            guard case .interrupted = first else { XCTFail("\(p.rawValue): \(first)"); continue }
            try await assertStoredWhole(p)
            let before = try await requests(p).count
            let second = try await run(&r)
            if p == .put {
                XCTAssertEqual(second, .finished)
            } else {
                guard case .failed(let reason, _) = second else { XCTFail("\(p.rawValue): \(second)"); continue }
                XCTAssertEqual(reason, Reason.sessionClosed)
                let after = try await requests(p).count
                XCTAssertEqual(after, before, "nothing more is sent")
            }
            _ = try await harness("POST", "/reset", [:])
        }
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
