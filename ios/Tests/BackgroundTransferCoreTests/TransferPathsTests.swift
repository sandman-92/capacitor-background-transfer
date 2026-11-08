import XCTest
@testable import BackgroundTransferCore

final class TransferPathsTests: XCTestCase {
    var dir: URL!
    var files: URL!
    var cache: URL!
    var outside: URL!
    var pluginDir: URL!
    var roots: [URL]!

    override func setUpWithError() throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("bt-paths-\(UUID().uuidString)")
        files = dir.appendingPathComponent("app/Documents")
        cache = dir.appendingPathComponent("app/Library/Caches")
        outside = dir.appendingPathComponent("elsewhere")
        pluginDir = dir.appendingPathComponent("app/Library/Application Support/BackgroundTransfer")
        for d in [files, cache, outside, pluginDir] { try fm.createDirectory(at: d!, withIntermediateDirectories: true) }
        roots = [files, cache]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func upload(_ path: String) -> String? {
        TransferPaths.confine(path, roots: roots, refused: pluginDir, download: false)
    }

    private func download(_ path: String) -> String? {
        TransferPaths.confine(path, roots: roots, refused: pluginDir, download: true)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    func testOnlyHttpUrlsPass() {
        XCTAssertNil(TransferPaths.checkUrl("https://h.example/upload?x=1"))
        XCTAssertNil(TransferPaths.checkUrl("HTTP://10.0.2.2:9199/o"))
        XCTAssertEqual(TransferPaths.checkUrl("ftp://h.example/x"), TransferPaths.notHttp)
        XCTAssertEqual(TransferPaths.checkUrl("file:///etc/passwd"), TransferPaths.notHttp)
        XCTAssertEqual(TransferPaths.checkUrl("https:///nohost"), TransferPaths.notHttp)
        XCTAssertEqual(TransferPaths.checkUrl("/relative"), TransferPaths.notHttp)
        XCTAssertEqual(TransferPaths.checkUrl("not a url"), TransferPaths.notHttp)
    }

    func testHeadersMustBeOneLine() {
        XCTAssertNil(TransferPaths.checkHeaders(["Authorization": "Bearer t", "X-Goog-Meta-Name": "héllo wörld"]))
        XCTAssertNil(TransferPaths.checkHeaders([:]))
        XCTAssertEqual(TransferPaths.checkHeaders(["X-Bad": "a\r\nInjected: 1"]), "header X-Bad must be one line")
        XCTAssertEqual(TransferPaths.checkHeaders(["X-Bad": "a\nb"]), "header X-Bad must be one line")
        XCTAssertEqual(TransferPaths.checkHeaders(["X-Bad": "a\u{0}b"]), "header X-Bad must be one line")
        XCTAssertEqual(TransferPaths.checkHeaders(["X-Bad\r": "v"]), "header X-Bad\r must be one line")
        XCTAssertEqual(TransferPaths.checkHeaders(["": "v"]), "header  must be one line")
    }

    func testTheWrappersShapeChecksAreRepeated() {
        XCTAssertEqual(TransferPaths.checkShape(""), "path is required")
        XCTAssertEqual(TransferPaths.checkShape("videos/v.mp4"), "path must be absolute or a file:// URI")
        XCTAssertEqual(TransferPaths.checkShape("/data/videos/"), "path must name a file")
        XCTAssertEqual(TransferPaths.checkShape("/data/../etc/passwd"), "path must not contain ..")
        XCTAssertEqual(upload(files.appendingPathComponent("../../elsewhere/x").path), "path must not contain ..")
        XCTAssertNil(TransferPaths.checkShape("/data/videos/v..mp4"))
    }

    func testFilesUnderTheAppsDirectoriesPass() throws {
        let existing = files.appendingPathComponent("videos/v.mp4")
        try touch(existing)
        XCTAssertNil(upload(existing.path))
        XCTAssertNil(download(cache.appendingPathComponent("new/dir/d.mp4").path), "a download's destination needn't exist yet")
        XCTAssertNil(download(files.appendingPathComponent("d.mp4").path), "nor its directory")
    }

    func testFilesElsewhereAreRefused() {
        XCTAssertEqual(upload(outside.appendingPathComponent("x.bin").path), TransferPaths.outside)
        XCTAssertEqual(upload("/etc/passwd"), TransferPaths.outside)
        XCTAssertEqual(download(dir.appendingPathComponent("app/x.bin").path), TransferPaths.outside)
        XCTAssertEqual(download(files.path + "2/x.bin"), TransferPaths.outside, "a sibling whose name starts with the root's")
        XCTAssertEqual(TransferPaths.confine(files.appendingPathComponent("x").path, roots: [], refused: nil, download: false),
                       TransferPaths.outside, "no roots at all")
    }

    func testThePluginsOwnStorageIsRefused() {
        // Under Library, which is a root, and refused all the same.
        roots = [files, dir.appendingPathComponent("app/Library")]
        XCTAssertEqual(upload(pluginDir.appendingPathComponent("transfers.json").path), TransferPaths.pluginDir)
        XCTAssertEqual(download(pluginDir.appendingPathComponent("resume/x.data").path), TransferPaths.pluginDir)
        XCTAssertEqual(download(pluginDir.path), TransferPaths.pluginDir)
        XCTAssertNil(download(dir.appendingPathComponent("app/Library/Caches/ok.mp4").path))
    }

    func testSymbolicLinksAreResolvedBeforeTheCheck() throws {
        let fm = FileManager.default
        let secret = outside.appendingPathComponent("secret.db")
        try touch(secret)
        let link = files.appendingPathComponent("innocent.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertEqual(upload(link.path), TransferPaths.outside, "a link out of the sandbox reads what it points at")
        let linkedDir = files.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedDir, withDestinationURL: outside)
        XCTAssertEqual(download(linkedDir.appendingPathComponent("d.mp4").path), TransferPaths.outside, "through a linked directory too")
        XCTAssertEqual(download(linkedDir.appendingPathComponent("new/d.mp4").path), TransferPaths.outside,
                       "even to a file that doesn't exist yet")
    }

    func testAnAliasOfARootIsStillTheRoot() throws {
        // As /var is for /private/var on a device: the app may name either.
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files)
        XCTAssertNil(upload(alias.appendingPathComponent("v.mp4").path))
        XCTAssertNil(download(alias.appendingPathComponent("new/v.mp4").path))
        XCTAssertNil(TransferPaths.confine(files.appendingPathComponent("v.mp4").path, roots: [alias], refused: nil, download: false),
                     "and a root given as an alias admits the real path")
    }

    func testADownloadNeverTargetsASymbolicLink() throws {
        let fm = FileManager.default
        let inside = files.appendingPathComponent("real.mp4")
        try touch(inside)
        let link = files.appendingPathComponent("link.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: inside)
        XCTAssertEqual(download(link.path), TransferPaths.symlink)
        XCTAssertNil(upload(link.path), "an upload may read through a link that stays inside")
        let dest = files.appendingPathComponent("d.mp4")
        try fm.createSymbolicLink(at: Files.partURL(for: dest), withDestinationURL: inside)
        XCTAssertEqual(download(dest.path), TransferPaths.symlink, "nor is its .part a link")
    }

    func testCanonicalResolvesWhatExistsAndKeepsTheRest() throws {
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files)
        let wanted = alias.appendingPathComponent("a/b/c.mp4")
        XCTAssertEqual(TransferPaths.canonical(wanted).path, files.resolvingSymlinksInPath().appendingPathComponent("a/b/c.mp4").path)
        XCTAssertTrue(TransferPaths.isUnder(URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a")))
        XCTAssertTrue(TransferPaths.isUnder(URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a")))
        XCTAssertFalse(TransferPaths.isUnder(URL(fileURLWithPath: "/a/bc"), URL(fileURLWithPath: "/a/b")))
        XCTAssertFalse(TransferPaths.isUnder(URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a/b")))
    }

    func testRedirectsStayOnTheirOrigin() {
        let u = { URL(string: $0)! }
        XCTAssertTrue(Redirects.sameOrigin(u("https://h.example/a"), u("HTTPS://H.EXAMPLE:443/b?x=1")))
        XCTAssertTrue(Redirects.sameOrigin(u("http://10.0.2.2:9199/a"), u("http://10.0.2.2:9199/b")))
        XCTAssertFalse(Redirects.sameOrigin(u("https://h.example/a"), u("https://cdn.example/a")), "another host")
        XCTAssertFalse(Redirects.sameOrigin(u("https://h.example/a"), u("http://h.example/a")), "another scheme")
        XCTAssertFalse(Redirects.sameOrigin(u("https://h.example/a"), u("https://h.example:8443/a")), "another port")
        XCTAssertTrue(Redirects.crossedOrigin(original: u("https://h.example/a"), final: u("https://cdn.example/a")))
        XCTAssertFalse(Redirects.crossedOrigin(original: u("https://h.example/a"), final: u("https://h.example/b")))
        XCTAssertFalse(Redirects.crossedOrigin(original: nil, final: u("https://h.example/b")), "nothing to compare with")
    }

    func testTheStoreDropsHeadersOnceATransferStops() throws {
        let file = dir.appendingPathComponent("store/transfers.json")
        let store = TransferStore(file: file)
        var r = TransferRecord(id: "a", direction: .upload, url: "https://x/u", path: "/a")
        r.headers = ["Authorization": "Bearer t"]
        XCTAssertEqual(store.put(r).headers, ["Authorization": "Bearer t"], "kept while queued")
        r.state = .running
        XCTAssertEqual(store.put(r).headers, ["Authorization": "Bearer t"], "and while running")
        for state in [TransferRecord.State.finished, .failed, .cancelled, .interrupted] {
            r.state = state
            XCTAssertEqual(store.put(r).headers, [:], "gone once \(state)")
            XCTAssertEqual(store.get(key: r.key)?.headers, [:])
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("Bearer t"), "and not on the disk either")
    }

    func testTheDirectoryCanBeKeptOutOfBackups() throws {
        XCTAssertFalse(Files.isExcludedFromBackup(pluginDir))
        try Files.excludeFromBackup(pluginDir)
        XCTAssertTrue(Files.isExcludedFromBackup(pluginDir))
    }
}
