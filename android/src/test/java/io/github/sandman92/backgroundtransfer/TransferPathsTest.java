package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class TransferPathsTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private File files;
    private File cache;
    private File outside;
    private File pluginDir;
    private List<File> roots;

    @Before
    public void up() throws Exception {
        files = tmp.newFolder("app", "files");
        cache = tmp.newFolder("app", "cache");
        outside = tmp.newFolder("elsewhere");
        pluginDir = new File(files, "background-transfer");
        pluginDir.mkdirs();
        roots = Arrays.asList(files, cache, null);
    }

    private String upload(String path) {
        return TransferPaths.confine(path, roots, pluginDir, false);
    }

    private String download(String path) {
        return TransferPaths.confine(path, roots, pluginDir, true);
    }

    @Test
    public void onlyHttpUrlsPass() {
        assertNull(TransferPaths.checkUrl("https://h.example/upload?x=1"));
        assertNull(TransferPaths.checkUrl("HTTP://10.0.2.2:9199/o"));
        assertEquals(TransferPaths.NOT_HTTP, TransferPaths.checkUrl("ftp://h.example/x"));
        assertEquals(TransferPaths.NOT_HTTP, TransferPaths.checkUrl("file:///etc/passwd"));
        assertEquals(TransferPaths.NOT_HTTP, TransferPaths.checkUrl("https:///nohost"));
        assertEquals(TransferPaths.NOT_HTTP, TransferPaths.checkUrl("/relative"));
        assertEquals(TransferPaths.NOT_HTTP, TransferPaths.checkUrl(null));
    }

    @Test
    public void headersMustBeOneLine() {
        Map<String, String> ok = new LinkedHashMap<>();
        ok.put("Authorization", "Bearer t");
        ok.put("X-Goog-Meta-Name", "héllo wörld");
        assertNull(TransferPaths.checkHeaders(ok));
        assertNull(TransferPaths.checkHeaders(null));
        assertEquals("header X-Bad must be one line", TransferPaths.checkHeaders(Collections.singletonMap("X-Bad", "a\r\nInjected: 1")));
        assertEquals("header X-Bad must be one line", TransferPaths.checkHeaders(Collections.singletonMap("X-Bad", "a\nb")));
        assertEquals("header X-Bad must be one line", TransferPaths.checkHeaders(Collections.singletonMap("X-Bad", "a\u0000b")));
        assertEquals("header X-Bad\r must be one line", TransferPaths.checkHeaders(Collections.singletonMap("X-Bad\r", "v")));
        assertEquals("header  must be one line", TransferPaths.checkHeaders(Collections.singletonMap("", "v")));
    }

    @Test
    public void theWrappersShapeChecksAreRepeated() {
        assertEquals("path is required", TransferPaths.checkShape(""));
        assertEquals("path must be absolute or a file:// URI", TransferPaths.checkShape("videos/v.mp4"));
        assertEquals("path must name a file", TransferPaths.checkShape("/data/videos/"));
        assertEquals("path must not contain ..", TransferPaths.checkShape("/data/../etc/passwd"));
        assertEquals("path must not contain ..", upload(new File(files, "../../elsewhere/x").getPath()));
        assertNull(TransferPaths.checkShape("/data/videos/v..mp4"));
    }

    @Test
    public void filesUnderTheAppsDirectoriesPass() throws Exception {
        File existing = new File(files, "videos/v.mp4");
        existing.getParentFile().mkdirs();
        Files.write(existing.toPath(), new byte[] { 1 });
        assertNull(upload(existing.getPath()));
        assertNull("a download's destination needn't exist yet", download(new File(cache, "new/dir/d.mp4").getPath()));
        assertNull("nor its directory", download(new File(files, "d.mp4").getPath()));
    }

    @Test
    public void filesElsewhereAreRefused() {
        assertEquals(TransferPaths.OUTSIDE, upload(new File(outside, "x.bin").getPath()));
        assertEquals(TransferPaths.OUTSIDE, upload("/etc/passwd"));
        assertEquals(TransferPaths.OUTSIDE, download(tmp.getRoot().getPath() + "/app/x.bin"));
        assertEquals("a sibling whose name starts with the root's", TransferPaths.OUTSIDE, download(files.getPath() + "2/x.bin"));
        assertEquals(
            "no roots at all",
            TransferPaths.OUTSIDE,
            TransferPaths.confine(new File(files, "x").getPath(), Collections.emptyList(), null, false)
        );
    }

    @Test
    public void thePluginsOwnStorageIsRefused() {
        assertEquals(TransferPaths.PLUGIN_DIR, upload(new File(pluginDir, "transfers.json").getPath()));
        assertEquals(TransferPaths.PLUGIN_DIR, download(new File(pluginDir, "transfers.json").getPath()));
        assertEquals(TransferPaths.PLUGIN_DIR, download(pluginDir.getPath()));
    }

    @Test
    public void symbolicLinksAreResolvedBeforeTheCheck() throws Exception {
        File secret = new File(outside, "secret.db");
        Files.write(secret.toPath(), new byte[] { 1 });
        File link = new File(files, "innocent.mp4");
        Files.createSymbolicLink(link.toPath(), secret.toPath());
        assertEquals("a link out of the sandbox reads what it points at", TransferPaths.OUTSIDE, upload(link.getPath()));
        File linkedDir = new File(files, "linked");
        Files.createSymbolicLink(linkedDir.toPath(), outside.toPath());
        assertEquals("through a linked directory too", TransferPaths.OUTSIDE, download(new File(linkedDir, "d.mp4").getPath()));
        assertEquals("even to a file that doesn't exist yet", TransferPaths.OUTSIDE, download(new File(linkedDir, "new/d.mp4").getPath()));
    }

    @Test
    public void anAliasOfARootIsStillTheRoot() throws Exception {
        // As /data/data/<pkg> is for /data/user/0/<pkg>: the app may name either.
        File alias = new File(tmp.getRoot(), "alias");
        Files.createSymbolicLink(alias.toPath(), files.toPath());
        assertNull(upload(new File(alias, "v.mp4").getPath()));
        assertNull(download(new File(alias, "new/v.mp4").getPath()));
        List<File> aliasedRoots = Collections.singletonList(alias);
        assertNull(
            "and a root given as an alias admits the real path",
            TransferPaths.confine(new File(files, "v.mp4").getPath(), aliasedRoots, null, false)
        );
    }

    @Test
    public void aDownloadNeverTargetsASymbolicLink() throws Exception {
        File inside = new File(files, "real.mp4");
        Files.write(inside.toPath(), new byte[] { 1 });
        File link = new File(files, "link.mp4");
        Files.createSymbolicLink(link.toPath(), inside.toPath());
        assertEquals(TransferPaths.SYMLINK, download(link.getPath()));
        assertNull("an upload may read through a link that stays inside", upload(link.getPath()));
        File dest = new File(files, "d.mp4");
        Files.createSymbolicLink(Downloader.partFile(dest).toPath(), inside.toPath());
        assertEquals("nor is its .part a link", TransferPaths.SYMLINK, download(dest.getPath()));
    }

    @Test
    public void canonicalResolvesWhatExistsAndKeepsTheRest() throws Exception {
        File alias = new File(tmp.getRoot(), "alias");
        Files.createSymbolicLink(alias.toPath(), files.toPath());
        File wanted = new File(alias, "a/b/c.mp4");
        assertEquals(new File(files.getCanonicalFile(), "a/b/c.mp4"), TransferPaths.canonical(wanted));
        assertTrue(TransferPaths.isUnder(new File("/a/b"), new File("/a")));
        assertTrue(TransferPaths.isUnder(new File("/a"), new File("/a")));
        assertFalse(TransferPaths.isUnder(new File("/a/bc"), new File("/a/b")));
        assertFalse(TransferPaths.isUnder(new File("/a"), new File("/a/b")));
    }
}
