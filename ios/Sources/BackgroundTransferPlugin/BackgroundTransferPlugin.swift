import Foundation
import Capacitor
#if canImport(BackgroundTransferCore)
import BackgroundTransferCore
#endif

/// The JavaScript side's handle on background transfers (definitions.ts). The work is done by
/// `TransferManager` in background `URLSession`s.
///
/// The app's delegate must hand the system's background session events over, or transfers that
/// finish while the app is closed aren't recorded until it is next opened:
///
/// ```swift
/// func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
///                  completionHandler: @escaping () -> Void) {
///     if BackgroundTransferPlugin.handleEvents(forBackgroundURLSession: identifier, completionHandler: completionHandler) { return }
///     completionHandler()
/// }
/// ```
@objc(BackgroundTransferPlugin)
public class BackgroundTransferPlugin: CAPPlugin, CAPBridgedPlugin, TransferListener {
    public let identifier = "BackgroundTransferPlugin"
    public let jsName = "BackgroundTransfer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "upload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "download", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "list", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "forget", returnType: CAPPluginReturnPromise)
    ]

    /// Hands a background session's events to the plugin. Returns false if `identifier` isn't
    /// one of the plugin's sessions (call `completionHandler` yourself then).
    @objc public static func handleEvents(forBackgroundURLSession identifier: String,
                                          completionHandler: @escaping () -> Void) -> Bool {
        TransferManager.shared.handleEvents(identifier: identifier, completionHandler: completionHandler)
    }

    override public func load() {
        TransferManager.shared.listener = self
        TransferManager.shared.start()
    }

    func transferChanged(_ record: TransferRecord, event: String) {
        notifyListeners(event, data: ["transfer": record.js])
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": true, "mechanism": "urlsession"])
    }

    @objc func upload(_ call: CAPPluginCall) {
        start(call, .upload)
    }

    @objc func download(_ call: CAPPluginCall) {
        start(call, .download)
    }

    private func start(_ call: CAPPluginCall, _ direction: TransferRecord.Direction) {
        guard let id = call.getString("id"), !id.isEmpty, let url = call.getString("url"),
              let path = call.getString("path"), path.hasPrefix("/") else {
            call.reject("id, url and an absolute path are required")
            return
        }
        var record = TransferRecord(id: id, direction: direction, url: url, path: path)
        if direction == .upload {
            guard let chosen = UploadProtocol.resolve(call.getString("protocol")) else {
                call.reject(UploadProtocol.refusal)
                return
            }
            record.protocol = chosen.rawValue
        }
        if let headers = call.getObject("headers") {
            for (name, value) in headers {
                if let value = value as? String { record.headers[name] = value }
            }
        }
        TransferManager.shared.enqueue(record) { stored in
            call.resolve(["transfer": stored.js])
        }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let direction = call.getString("direction").flatMap(TransferRecord.Direction.init) else {
            call.reject("id and direction are required")
            return
        }
        TransferManager.shared.cancel(key: TransferRecord.key(direction, id))
        call.resolve()
    }

    @objc func list(_ call: CAPPluginCall) {
        call.resolve(["transfers": TransferManager.shared.list().map(\.js)])
    }

    @objc func forget(_ call: CAPPluginCall) {
        var keys: Set<String>?
        if let ids = call.getArray("ids", JSObject.self) {
            keys = Set(ids.compactMap { o in
                guard let id = o["id"] as? String, let d = (o["direction"] as? String).flatMap(TransferRecord.Direction.init) else { return nil }
                return TransferRecord.key(d, id)
            })
        }
        TransferManager.shared.forget(keys: keys)
        call.resolve()
    }
}
