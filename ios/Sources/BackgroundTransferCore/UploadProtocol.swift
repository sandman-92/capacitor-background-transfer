import Foundation

/// The upload protocols this version speaks, by the name the JavaScript side passes in `protocol`.
/// Another protocol plugs in as a new case here and a branch where `TransferManager` starts an upload.
public enum UploadProtocol: String, CaseIterable, Codable {
    /// A Firebase Storage resumable upload: the `X-Goog-Upload-*` protocol.
    case firebaseResumable = "firebase-resumable"

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
