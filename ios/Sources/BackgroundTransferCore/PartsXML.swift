import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The XML that S3 multipart uploads and Azure block blobs speak, and Azure's block ids.
public enum PartsXML {
    /// What `ListParts` answered: part number → (ETag, size), and whether more pages follow.
    public struct Listed: Equatable {
        public var parts: [Int: (tag: String, size: Int64)] = [:]
        public var truncated = false
        public var highest = 0

        public static func == (a: Listed, b: Listed) -> Bool {
            a.truncated == b.truncated && a.highest == b.highest && a.parts.mapValues { "\($0.tag)|\($0.size)" } == b.parts.mapValues { "\($0.tag)|\($0.size)" }
        }
    }

    /// Nil when the XML can't be read.
    public static func listParts(_ data: Data) -> Listed? {
        guard let root = Element.parse(data) else { return nil }
        var out = Listed()
        out.truncated = root.child("IsTruncated")?.text.lowercased() == "true"
        for part in root.children("Part") {
            guard let n = Int(part.child("PartNumber")?.text.trimmingCharacters(in: .whitespaces) ?? ""),
                  let size = Int64(part.child("Size")?.text.trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
            out.parts[n] = (part.child("ETag")?.text ?? "", size)
            out.highest = max(out.highest, n)
        }
        return out
    }

    /// The `CompleteMultipartUpload` body listing parts 1 to `count`.
    public static func completeBody(etags: [String: String], count: Int) -> Data {
        var b = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>"
        for n in stride(from: 1, through: count, by: 1) {
            b += "<Part><PartNumber>\(n)</PartNumber><ETag>\(escape(etags[String(n)] ?? ""))</ETag></Part>"
        }
        b += "</CompleteMultipartUpload>"
        return Data(b.utf8)
    }

    /// The error code in an S3 answer, or nil when it isn't an `<Error>`. S3 can answer
    /// `CompleteMultipartUpload` with 200 and an error in the body.
    public static func errorCode(_ data: Data?) -> String? {
        guard let data = data, let text = String(data: data, encoding: .utf8), text.contains("<Error") else { return nil }
        guard let root = Element.parse(data) else { return "Error" }
        guard root.name == "Error" else { return nil }
        let code = root.child("Code")?.text ?? ""
        return code.isEmpty ? "Error" : code
    }

    /// Whether a 200 answer to `CompleteMultipartUpload` is the completed object.
    public static func isCompleteResult(_ data: Data?) -> Bool {
        guard let data = data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("CompleteMultipartUploadResult") && errorCode(data) == nil
    }

    /// Azure's `Get Block List`: block id → size, for the uncommitted blocks. Nil when unreadable.
    public static func uncommittedBlocks(_ data: Data) -> [String: Int64]? {
        guard let root = Element.parse(data) else { return nil }
        var out: [String: Int64] = [:]
        for section in root.children("UncommittedBlocks") {
            for block in section.children("Block") {
                guard let size = Int64(block.child("Size")?.text.trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
                out[block.child("Name")?.text ?? ""] = size
            }
        }
        return out
    }

    /// The `Put Block List` body committing `ids` in order.
    public static func blockListBody(_ ids: [String]) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>" + ids.map { "<Latest>\(escape($0))</Latest>" }.joined() + "</BlockList>").utf8)
    }

    /// Block `n`'s id: the same for the same transfer, file size and block size, so a resumed upload
    /// finds its blocks, and different for a different file. Every id of a blob has the same length,
    /// as Azure requires. Android makes the same ids.
    public static func blockId(transferId: String, size: Int64, blockSize: Int64, n: Int) -> String {
        let digest = SHA256.hash(data: Data("\(transferId)|\(size)|\(blockSize)".utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Data((prefix + "-" + String(format: "%06d", n)).utf8).base64EncodedString()
    }

    public static func blockIds(transferId: String, size: Int64, blockSize: Int64, count: Int) -> [String] {
        (0..<count).map { blockId(transferId: transferId, size: size, blockSize: blockSize, n: $0 + 1) }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A small DOM, enough for these answers.
    final class Element {
        let name: String
        var text = ""
        var elements: [Element] = []

        init(_ name: String) { self.name = name }

        func children(_ tag: String) -> [Element] { elements.filter { $0.name == tag } }
        func child(_ tag: String) -> Element? { elements.first { $0.name == tag } }

        static func parse(_ data: Data) -> Element? {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = builder
            guard parser.parse(), let root = builder.root else { return nil }
            return root
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let e = Element(local)
            stack.last?.elements.append(e)
            if root == nil { root = e }
            stack.append(e)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}
