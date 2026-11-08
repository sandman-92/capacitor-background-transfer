package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.File;
import java.util.Collections;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class UploaderTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private FakeStorage server;
    private static final int CHUNK = 256 * 1024;

    @Before
    public void up() throws Exception {
        server = new FakeStorage();
    }

    @After
    public void down() {
        server.close();
    }

    private Uploader uploader() {
        return new Uploader(CHUNK, 3, 1);
    }

    @Test
    public void chunksCoverTheFileAndOnlyTheLastFinalizes() {
        long total = 3L * CHUNK + 10;
        Uploader.Chunk c = Uploader.nextChunk(0, total, CHUNK);
        assertEquals(CHUNK, c.length);
        assertFalse(c.last);
        c = Uploader.nextChunk(3L * CHUNK, total, CHUNK);
        assertEquals(10, c.length);
        assertTrue(c.last);
        c = Uploader.nextChunk(2L * CHUNK + 10, 3L * CHUNK + 10, CHUNK);
        assertEquals(CHUNK, c.length);
        assertTrue("a chunk that ends at the file's end finalizes", c.last);
    }

    @Test
    public void anEmptyRemainderStillFinalizes() {
        Uploader.Chunk c = Uploader.nextChunk(100, 100, CHUNK);
        assertEquals(0, c.length);
        assertTrue(c.last);
    }

    @Test(expected = IllegalArgumentException.class)
    public void anOffsetPastTheEndIsRefused() {
        Uploader.nextChunk(101, 100, CHUNK);
    }

    @Test
    public void sendsTheWholeFileInChunksWithNoAuthorization() throws Exception {
        byte[] data = Bytes.pattern(3 * CHUNK + 1234);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        Bytes.Recorder p = new Bytes.Recorder();
        assertEquals(data.length, uploader().run(server.url("/upload"), f, Collections.emptyMap(), p));
        assertArrayEquals(data, server.received.toByteArray());
        assertTrue(server.finalized);
        assertEquals(data.length, p.bytes);
        assertEquals(data.length, p.total);
        // query, then four chunks; the last finalizes; none carried Authorization
        assertEquals(5, server.log.size());
        assertTrue(server.log.get(0).startsWith("POST query"));
        assertTrue(server.log.get(4).startsWith("POST upload, finalize " + 3 * CHUNK));
        for (String line : server.log) assertTrue(line, line.endsWith("auth=false"));
    }

    @Test
    public void startsFromTheServersOffset() throws Exception {
        byte[] data = Bytes.pattern(2 * CHUNK + 99);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        server.received.write(data, 0, CHUNK); // the server already holds the first chunk
        uploader().run(server.url("/upload"), f, null, new Bytes.Recorder());
        assertArrayEquals(data, server.received.toByteArray());
        assertTrue(server.log.get(1).startsWith("POST upload " + CHUNK));
        assertEquals("query, then only the two chunks left", 3, server.log.size());
    }

    @Test
    public void carriesOnFromWhatTheServerSaysItKept() throws Exception {
        byte[] data = Bytes.pattern(2 * CHUNK + 5);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        server.keepPerChunk = CHUNK / 2;
        uploader().run(server.url("/upload"), f, null, new Bytes.Recorder());
        assertArrayEquals(data, server.received.toByteArray());
    }

    @Test
    public void aSessionAlreadyClosedIsNotTakenAsAccepted() throws Exception {
        // A server may close a session even when it refuses the finalize (the Firebase Storage emulator does): only the object's metadata can say.
        byte[] data = Bytes.pattern(1000);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        server.received.write(data);
        server.finalized = true;
        TransferException e = expect(TransferException.Reason.SESSION_CLOSED, () ->
            uploader().run(server.url("/upload"), f, null, new Bytes.Recorder())
        );
        assertFalse(e.isResumable());
        assertEquals("only the query was sent", 1, server.log.size());
    }

    @Test
    public void passesTheCallersHeaders() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(10));
        Map<String, String> h = Collections.singletonMap("Authorization", "Bearer t");
        uploader().run(server.url("/upload"), f, h, new Bytes.Recorder());
        for (String line : server.log) assertTrue(line, line.endsWith("auth=true"));
    }

    @Test
    public void resumesAfterADroppedConnection() throws Exception {
        byte[] data = Bytes.pattern(3 * CHUNK);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        server.dropCount.set(1);
        try {
            uploader().run(server.url("/upload"), f, null, new Bytes.Recorder());
        } catch (TransferException e) {
            throw new AssertionError(server.log.toString(), e);
        }
        assertArrayEquals(data, server.received.toByteArray());
    }

    @Test
    public void aMissingFileFails() {
        expect(TransferException.Reason.FILE_MISSING, () ->
            uploader().run(server.url("/upload"), new File(tmp.getRoot(), "gone.mp4"), null, new Bytes.Recorder())
        );
    }

    @Test
    public void anExpiredSessionFails() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(10));
        server.failStatus = 404;
        server.failCount.set(1);
        TransferException e = expect(TransferException.Reason.SESSION_EXPIRED, () ->
            uploader().run(server.url("/upload"), f, null, new Bytes.Recorder())
        );
        assertEquals(404, e.httpStatus);
    }

    @Test
    public void aRefusedFinalizeFails() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(10));
        server.failStatus = 403;
        server.failCount.set(1);
        expect(TransferException.Reason.SESSION_REFUSED, () -> uploader().run(server.url("/upload"), f, null, new Bytes.Recorder()));
    }

    @Test
    public void aServerThatHoldsMoreThanTheFileFails() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(10));
        server.received.write(Bytes.pattern(20));
        expect(TransferException.Reason.SIZE_MISMATCH, () -> uploader().run(server.url("/upload"), f, null, new Bytes.Recorder()));
    }

    @Test
    public void aNetworkThatStaysDownGivesUpAsNetwork() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(10));
        String url = server.url("/upload");
        server.close();
        expect(TransferException.Reason.NETWORK, () -> uploader().run(url, f, null, new Bytes.Recorder()));
    }

    @Test
    public void stopsWhenCancelled() throws Exception {
        byte[] data = Bytes.pattern(4 * CHUNK);
        File f = Bytes.write(tmp.getRoot(), "v.mp4", data);
        Bytes.Recorder p = new Bytes.Recorder();
        p.stopAt = CHUNK;
        expect(TransferException.Reason.CANCELLED, () -> uploader().run(server.url("/upload"), f, null, p));
        assertFalse(server.finalized);
        assertEquals(CHUNK, server.received.size());
    }

    interface Call {
        void run() throws Exception;
    }

    @Test
    public void aRedirectIsNotFollowed() throws Exception {
        File f = Bytes.write(tmp.getRoot(), "v.mp4", Bytes.pattern(CHUNK));
        server.failStatus = 307;
        server.failCount.set(1);
        TransferException e = expect(TransferException.Reason.SESSION_REFUSED, () ->
            uploader().run(server.url("/upload"), f, Collections.singletonMap("Authorization", "Bearer t"), new Bytes.Recorder())
        );
        assertEquals(307, e.httpStatus);
        assertTrue(e.getMessage(), e.getMessage().contains("redirect"));
        assertEquals("one request, nothing after the redirect", 1, server.log.size());
    }

    static TransferException expect(String reason, Call call) {
        try {
            call.run();
        } catch (TransferException e) {
            assertEquals(e.getMessage(), reason, e.reason);
            return e;
        } catch (Exception e) {
            throw new AssertionError("expected a TransferException, got " + e, e);
        }
        fail("expected " + reason);
        return null;
    }
}
