import Foundation

/// The upload protocols this version speaks, by the name the JavaScript side passes in `protocol`.
/// Another protocol plugs in as a new case here and a branch where `TransferManager` starts an upload.
public enum UploadProtocol: String, CaseIterable, Codable {
    /// A Firebase Storage resumable upload: the `X-Goog-Upload-*` protocol.
    case firebaseResumable = "firebase-resumable"
    /// The whole file in one `PUT`.
    case put
    /// An S3 multipart upload with every URL presigned up front.
    case s3Multipart = "s3-multipart"
    /// An Azure block blob through one SAS URL.
    case azureBlocks = "azure-blocks"

    /// Sent in parts or blocks, each a background task of its own, then committed.
    public var inParts: Bool { self == .s3Multipart || self == .azureBlocks }

    public static let defaultProtocol: UploadProtocol = .firebaseResumable

    /// The protocol for `name`: the default when nil, or nil when unknown.
    public static func resolve(_ name: String?) -> UploadProtocol? {
        guard let name = name else { return defaultProtocol }
        return UploadProtocol(rawValue: name)
    }

    /// What the plugin says when it refuses an unknown protocol.
    public static var refusal: String {
        "protocol must be one of " + allCases.map(\.rawValue).joined(separator: ", ")
    }
}
