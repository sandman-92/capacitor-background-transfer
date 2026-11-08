package io.github.sandman92.backgroundtransfer;

import static io.github.sandman92.backgroundtransfer.UploaderTest.expect;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class DownloaderTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private FakeStorage server;
    private File dest;

    @Before
    public void up() throws Exception {
        server = new FakeStorage();
        server.object = Bytes.pattern(1_000_000);
        dest = new File(tmp.getRoot(), "videos/v.mp4");
    }

    @After
    public void down() {
        server.close();
    }

    private Downloader downloader() {
        return new Downloader(3, 1);
    }

    @Test
    public void parsesContentRange() {
        Downloader.Range r = Downloader.parseContentRange("bytes 100-199/1000");
        assertEquals(100, r.start);
        assertEquals(199, r.end);
        assertEquals(1000, r.total);
        r = Downloader.parseContentRange("bytes */1000");
        assertEquals(-1, r.start);
        assertEquals(1000, r.total);
        assertEquals(-1, Downloader.parseContentRange("bytes 0-9/*").total);
        assertNull(Downloader.parseContentRange("items 1-2/3"));
        assertNull(Downloader.parseContentRange(null));
    }

    @Test
    public void downloadsToThePathOnlyWhenComplete() throws Exception {
        Bytes.Recorder p = new Bytes.Recorder();
        assertEquals(1_000_000, downloader().run(server.url("/object"), dest, null, p));
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
        assertFalse(Downloader.partFile(dest).exists());
        assertEquals(1_000_000, p.total);
        assertEquals("range=null auth=false", server.log.get(0).substring(4));
    }

    @Test
    public void resumesFromThePartFileWithARange() throws Exception {
        dest.getParentFile().mkdirs();
        Files.write(Downloader.partFile(dest).toPath(), Arrays.copyOf(server.object, 300_000));
        downloader().run(server.url("/object"), dest, null, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
        assertTrue(server.log.get(0).contains("range=bytes=300000-"));
    }

    @Test
    public void startsAgainWhenTheServerIgnoresTheRange() throws Exception {
        dest.getParentFile().mkdirs();
        Files.write(Downloader.partFile(dest).toPath(), Arrays.copyOf(server.object, 300_000));
        server.ignoreRange = true;
        downloader().run(server.url("/object"), dest, null, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
    }

    @Test
    public void aCompletePartFileIsRenamedOn416() throws Exception {
        dest.getParentFile().mkdirs();
        Files.write(Downloader.partFile(dest).toPath(), server.object);
        downloader().run(server.url("/object"), dest, null, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
        assertFalse(Downloader.partFile(dest).exists());
    }

    @Test
    public void aPartFileLongerThanTheObjectStartsAgain() throws Exception {
        dest.getParentFile().mkdirs();
        Files.write(Downloader.partFile(dest).toPath(), Bytes.pattern(1_200_000));
        downloader().run(server.url("/object"), dest, null, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
    }

    @Test
    public void resumesAfterTheConnectionDrops() throws Exception {
        server.dropCount.set(1);
        downloader().run(server.url("/object"), dest, null, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
        assertTrue("the retry asked for the rest", server.log.get(1).contains("range=bytes="));
    }

    @Test
    public void aNetworkThatStaysDownLeavesOnlyThePart() throws Exception {
        String url = server.url("/object");
        server.close();
        expect(TransferException.Reason.NETWORK, () -> downloader().run(url, dest, null, new Bytes.Recorder()));
        assertFalse(dest.exists());
    }

    @Test
    public void aCancelLeavesNoFinishedFile() {
        Bytes.Recorder p = new Bytes.Recorder();
        p.stopAt = 1;
        expect(TransferException.Reason.CANCELLED, () -> downloader().run(server.url("/object"), dest, null, p));
        assertFalse(dest.exists());
    }

    @Test
    public void aRefusedUrlFails() {
        server.failStatus = 403;
        server.failCount.set(1);
        expect(TransferException.Reason.SESSION_REFUSED, () -> downloader().run(server.url("/object"), dest, null, new Bytes.Recorder()));
        server.failStatus = 404;
        server.failCount.set(1);
        expect(TransferException.Reason.SESSION_EXPIRED, () -> downloader().run(server.url("/object"), dest, null, new Bytes.Recorder()));
        assertFalse(dest.exists());
    }

    @Test
    public void followsARedirectOnTheSameHostWithTheHeaders() throws Exception {
        Map<String, String> headers = Collections.singletonMap("Authorization", "Bearer t");
        downloader().run(server.url("/redirect"), dest, headers, new Bytes.Recorder());
        assertArrayEquals(server.object, Files.readAllBytes(dest.toPath()));
        assertEquals("GET redirect auth=true", server.log.get(0));
        assertEquals("GET range=null auth=true", server.log.get(1));
    }

    @Test
    public void aRedirectToAnotherHostIsRefusedBeforeAnyHeaderReachesIt() throws Exception {
        try (FakeStorage other = new FakeStorage()) {
            other.object = server.object;
            server.redirectTo = other.url("/object");
            Map<String, String> headers = Collections.singletonMap("Authorization", "Bearer t");
            TransferException e = expect(TransferException.Reason.SESSION_REFUSED, () ->
                downloader().run(server.url("/redirect"), dest, headers, new Bytes.Recorder())
            );
            assertEquals(302, e.httpStatus);
            assertTrue(e.getMessage(), e.getMessage().contains("redirected to"));
            assertTrue("the other host saw nothing", other.log.isEmpty());
            assertFalse(dest.exists());
            assertFalse(Downloader.partFile(dest).exists());
        }
    }

    @Test
    public void aRedirectLoopGivesUp() {
        server.redirectTo = "/redirect";
        TransferException e = expect(TransferException.Reason.SESSION_REFUSED, () ->
            downloader().run(server.url("/redirect"), dest, null, new Bytes.Recorder())
        );
        assertTrue(e.getMessage(), e.getMessage().contains("too many redirects"));
        assertEquals(TransferPaths.MAX_REDIRECTS + 1, server.log.size());
    }

    @Test
    public void neverWritesThroughASymbolicLink() throws Exception {
        File elsewhere = tmp.newFile("elsewhere.bin");
        dest.getParentFile().mkdirs();
        Files.createSymbolicLink(dest.toPath(), elsewhere.toPath());
        TransferException e = expect(TransferException.Reason.UNKNOWN, () ->
            downloader().run(server.url("/object"), dest, null, new Bytes.Recorder())
        );
        assertTrue(e.getMessage(), e.getMessage().contains("symbolic link"));
        assertEquals("the link's target is untouched", 0, elsewhere.length());
        assertTrue("the server was never asked", server.log.isEmpty());
    }

    @Test
    public void tellsAFullDiskApart() {
        assertEquals(
            TransferException.Reason.DISK_FULL,
            TransferException.forDisk(new java.io.IOException("write failed: ENOSPC (No space left on device)")).reason
        );
        assertEquals(TransferException.Reason.UNKNOWN, TransferException.forDisk(new java.io.IOException("EIO")).reason);
    }

    @Test
    public void statusesMapToReasons() {
        assertEquals(TransferException.Reason.SESSION_EXPIRED, TransferException.forStatus(410, "x").reason);
        assertEquals(TransferException.Reason.SERVER_ERROR, TransferException.forStatus(503, "x").reason);
        assertEquals(TransferException.Reason.SERVER_ERROR, TransferException.forStatus(429, "x").reason);
        assertEquals(TransferException.Reason.SESSION_REFUSED, TransferException.forStatus(401, "x").reason);
        assertTrue(TransferException.forStatus(500, "x").isResumable());
        assertFalse(TransferException.forStatus(403, "x").isResumable());
    }
}
