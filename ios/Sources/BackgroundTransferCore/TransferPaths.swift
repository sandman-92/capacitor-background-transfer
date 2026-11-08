import Foundation

/// The checks on a transfer's options that the native side repeats, whatever the JavaScript
/// wrapper did: a script in the web view can call the plugin directly and skip `validate.ts`. The
/// refusals use the wrapper's words. Foundation only, so it runs under `swift test` on a Mac.
public enum TransferPaths {
    public static let notHttp = "url must be an http or https URL"
    public static let outside = "path must be inside the app's storage"
    public static let pluginDir = "path must not be inside the plugin's own storage"
    public static let symlink = "path must not be a symbolic link"

    /// What is wrong with `url`, or nil.
    public static func checkUrl(_ url: String) -> String? {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else { return notHttp }
        return nil
    }

    /// What is wrong with the headers (a name or value with a line break or another control
    /// character), or nil.
    public static func checkHeaders(_ headers: [String: String]) -> String? {
        for (name, value) in headers where name.isEmpty || hasControl(name) || hasControl(value) {
            return "header \(name) must be one line"
        }
        return nil
    }

    private static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The wrapper's checks on the path's shape: absolute, naming a file, no `..` segment.
    public static func checkShape(_ path: String) -> String? {
        if path.isEmpty { return "path is required" }
        if !path.hasPrefix("/") { return "path must be absolute or a file:// URI" }
        if path.hasSuffix("/") { return "path must name a file" }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return "path must not contain .." }
        return nil
    }

    /// Refuses a path that isn't under one of `roots` (the app's own directories) once symbolic
    /// links are resolved, or that is inside `refused` (the plugin's own storage, which holds other
    /// transfers' headers). For a download, the destination and its `.part` must not be symbolic
    /// links either, since both are replaced. Returns what is wrong, or nil.
    public static func confine(_ path: String, roots: [URL], refused: URL?, download: Bool) -> String? {
        if let shape = checkShape(path) { return shape }
        let file = URL(fileURLWithPath: path)
        let resolved = canonical(file)
        if let refused = refused, isUnder(resolved, canonical(refused)) { return pluginDir }
        guard roots.contains(where: { isUnder(resolved, canonical($0)) }) else { return outside }
        if download && (isSymbolicLink(file) || isSymbolicLink(Files.partURL(for: file))) { return symlink }
        return nil
    }

    /// `url` with every symbolic link resolved: its deepest existing ancestor is resolved and the
    /// rest appended, so a file not yet written (a download's destination) resolves too. (On a
    /// device the app's directories are under `/var`, a link to `/private/var`; the roots and the
    /// path both come out the same way.)
    public static func canonical(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for name in rest { resolved.appendPathComponent(name) }
        return resolved
    }

    /// Whether `url` is `root` or inside it (both canonical), by path components.
    public static func isUnder(_ url: URL, _ root: URL) -> Bool {
        let a = url.pathComponents
        let b = root.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    public static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// Where a redirect may go: the same origin (scheme, host and port) as the URL the app named, so
/// the app's headers never reach a host it didn't send them to.
public enum Redirects {
    public static func sameOrigin(_ from: URL, _ to: URL) -> Bool {
        guard let a = from.scheme?.lowercased(), let b = to.scheme?.lowercased(), a == b,
              let h = from.host?.lowercased(), let k = to.host?.lowercased(), h == k else { return false }
        return port(from) == port(to)
    }

    private static func port(_ url: URL) -> Int {
        if let p = url.port { return p }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    /// Whether a task that began at `original` ended answering from another origin.
    public static func crossedOrigin(original: URL?, final: URL?) -> Bool {
        guard let original = original, let final = final else { return false }
        return !sameOrigin(original, final)
    }
}
