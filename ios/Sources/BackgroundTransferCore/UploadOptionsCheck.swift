import Foundation

/// Checks an upload's protocol options the way `checkUploadOptions` in validate.ts does, with the
/// same words, and the part count against the file's size, which only the native side can read.
public enum UploadOptionsCheck {
    public static let mib: Int64 = 1024 * 1024
    public static let defaultPartSize: Int64 = 8 * mib
    public static let s3MinPartSize: Int64 = 5 * mib
    public static let s3MaxPartSize: Int64 = 5 * 1024 * mib
    public static let s3MaxParts = 10_000
    public static let azureMaxBlockSize: Int64 = 4000 * mib
    public static let azureMaxBlocks = 50_000

    /// What is wrong with the options, or nil. `partUrls` holds whatever JavaScript sent;
    /// `partSize` and `blockSize` are nil when not given.
    public static func check(protocol p: UploadProtocol, url: String, partUrls: [Any]?, partSize: Double?,
                             listPartsUrl: Any?, blockSize: Double?) -> String? {
        if p != .s3Multipart && (partUrls != nil || partSize != nil || listPartsUrl != nil) {
            return "partUrls, partSize and listPartsUrl are only for s3-multipart"
        }
        if p != .azureBlocks && blockSize != nil { return "blockSize is only for azure-blocks" }
        if p == .s3Multipart {
            guard let urls = partUrls, !urls.isEmpty else { return "partUrls is required for s3-multipart" }
            if urls.count > s3MaxParts { return "partUrls holds more than \(s3MaxParts) parts" }
            if !urls.allSatisfy({ ($0 as? String).map(isHttpUrl) ?? false }) { return "partUrls must be http or https URLs" }
            let size = partSize ?? Double(defaultPartSize)
            if !isWhole(size) || size < 1 || size > Double(s3MaxPartSize) { return "partSize must be a whole number of bytes up to 5 GiB" }
            if urls.count > 1 && size < Double(s3MinPartSize) { return "partSize must be at least 5 MiB when there is more than one part" }
            if let list = listPartsUrl, !((list as? String).map(isHttpUrl) ?? false) { return "listPartsUrl must be an http or https URL" }
        }
        if p == .azureBlocks {
            if !isSasUrl(url) { return "url must be a blob SAS URL (with a sig parameter)" }
            let size = blockSize ?? Double(defaultPartSize)
            if !isWhole(size) || size < 1 || size > Double(azureMaxBlockSize) { return "blockSize must be a whole number of bytes up to 4000 MiB" }
        }
        return nil
    }

    /// What is wrong with the part or block count for a `fileSize`-byte file, or nil.
    public static func checkSize(protocol p: UploadProtocol, partUrlCount: Int, partSize: Int64, blockSize: Int64, fileSize: Int64) -> String? {
        if p == .s3Multipart {
            let needed = PartPlan.count(size: fileSize, partSize: partSize, atLeastOne: true)
            if needed > s3MaxParts { return "a \(fileSize)-byte file in \(partSize)-byte parts needs more than \(s3MaxParts) parts" }
            if needed != partUrlCount {
                return "partUrls holds \(partUrlCount) parts but a \(fileSize)-byte file in \(partSize)-byte parts needs \(needed)"
            }
        }
        if p == .azureBlocks && PartPlan.count(size: fileSize, partSize: blockSize, atLeastOne: false) > azureMaxBlocks {
            return "a \(fileSize)-byte file in \(blockSize)-byte blocks needs more than \(azureMaxBlocks) blocks"
        }
        return nil
    }

    static func isHttpUrl(_ s: String) -> Bool {
        s.range(of: "^https?://[^/]+", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isWhole(_ d: Double) -> Bool {
        d.isFinite && d.rounded(.down) == d && abs(d) <= 9_007_199_254_740_991
    }

    /// A blob URL with a SAS token: a non-empty `sig` parameter, and no `comp`.
    public static func isSasUrl(_ url: String) -> Bool {
        let base = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        guard let q = base.firstIndex(of: "?") else { return false }
        var sig = false
        for p in base[base.index(after: q)...].split(separator: "&", omittingEmptySubsequences: false) {
            let name = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if name == "comp" { return false }
            if name == "sig" && p.count > "sig=".count { sig = true }
        }
        return sig
    }
}

/// How a file divides into parts (S3) or blocks (Azure), numbered from 1.
public enum PartPlan {
    /// An empty file is one (empty) part when `atLeastOne` (S3 needs a part to complete), none otherwise.
    public static func count(size: Int64, partSize: Int64, atLeastOne: Bool) -> Int {
        if size <= 0 { return atLeastOne ? 1 : 0 }
        let n = (size + partSize - 1) / partSize
        return n > Int64(Int.max) ? Int.max : Int(n)
    }

    public static func offset(_ n: Int, partSize: Int64) -> Int64 { Int64(n - 1) * partSize }

    public static func length(_ n: Int, size: Int64, partSize: Int64) -> Int64 {
        max(0, min(partSize, size - offset(n, partSize: partSize)))
    }
}
