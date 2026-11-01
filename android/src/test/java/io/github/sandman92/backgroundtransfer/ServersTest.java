package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.net.URLEncoder;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.Random;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Assume;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;

/**
 * Each upload protocol against real servers: MinIO for S3, Azurite for Azure, both behind the
 * harness's recording proxy (test-servers/). Runs the uploads through {@link Runner} as the
 * pre-Android-14 worker does, so an interruption ends the run and starting again resumes it.
 * Skipped unless {@code BT_HARNESS} is set ({@code npm run test:servers} sets it).
 */
@RunWith(Parameterized.class)
public class ServersTest {

    private static final long MIB = UploadOptionsCheck.MIB;
    /** Three parts or blocks: 5 MiB, 5 MiB, 1 MiB. */
    private static final int SIZE = (int) (11 * MIB);
    private static final long PART = 5 * MIB;

    @Parameterized.Parameters(name = "{0}")
    public static Collection<Object[]> protocols() {
        return Arrays.asList(new Object[][] { { UploadAdapters.PUT }, { UploadAdapters.S3_MULTIPART }, { UploadAdapters.AZURE_BLOCKS } });
    }

    @Parameterized.Parameter
    public String protocol;

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private TransferStore store;
    private final List<String> events = new ArrayList<>();
    private final List<Long> progress = new ArrayList<>();
    private byte[] data;
    private File file;
    /** The object on the server: the S3 key or the Azure blob name. */
    private String object;

    @Before
    public void up() throws Exception {
        Assume.assumeTrue("BT_HARNESS is not set", Harness.configured());
        Harness.post("/reset", new JSONObject());
        Runner.retries = 0;
        Runner.backoffMillis = 1;
        store = new TransferStore(new File(tmp.getRoot(), "store/transfers.json"));
        data = new byte[SIZE];
        new Random(42).nextBytes(data);
        file = new File(tmp.getRoot(), "upload.bin");
        Files.write(file.toPath(), data);
        Runner.setEvents((name, r) -> {
            synchronized (events) {
                if (name.equals("progress")) progress.add(r.bytes);
                else events.add(r.state + (r.reason != null ? " " + r.reason : ""));
            }
        });
    }

    @After
    public void down() throws Exception {
        Runner.setEvents(null);
        Runner.end(TransferRecord.UPLOAD);
        Runner.retries = 3;
        Runner.backoffMillis = 2000;
        if (Harness.configured()) Harness.post("/reset", new JSONObject());
    }

    // ---- Setting up an upload as an app would ----

    private TransferRecord upload(JSONObject options) throws Exception {
        TransferRecord r = new TransferRecord();
        r.id = "t-" + protocol;
        r.direction = TransferRecord.UPLOAD;
        r.path = file.getPath();
        r.protocol = protocol;
        switch (protocol) {
            case UploadAdapters.PUT: {
                JSONObject put = Harness.post("/s3/put", options);
                object = put.getString("key");
                r.url = put.getString("url");
                break;
            }
            case UploadAdapters.S3_MULTIPART: {
                JSONObject m = Harness.post("/s3/multipart", options.put("size", SIZE).put("partSize", PART));
                object = m.getString("key");
                r.url = m.getString("url");
                JSONArray parts = m.getJSONArray("partUrls");
                for (int i = 0; i < parts.length(); i++) r.partUrls.add(parts.getString(i));
                r.partSize = PART;
                if (!options.optBoolean("noListParts")) r.listPartsUrl = m.getString("listPartsUrl");
                break;
            }
            default: {
                JSONObject blob = Harness.post("/azure/blob", options);
                object = blob.getString("name");
                r.url = blob.getString("url");
                r.blockSize = PART;
            }
        }
        return r;
    }

    /** The same upload asked for again, as an app does after an interruption. */
    private static TransferRecord restart(TransferRecord r) {
        TransferRecord again = new TransferRecord();
        again.id = r.id;
        again.direction = r.direction;
        again.path = r.path;
        again.protocol = r.protocol;
        again.url = r.url;
        again.partUrls = new ArrayList<>(r.partUrls);
        again.partSize = r.partSize;
        again.listPartsUrl = r.listPartsUrl;
        again.blockSize = r.blockSize;
        return again;
    }

    private TransferRecord upload() throws Exception {
        return upload(new JSONObject());
    }

    /** Queues {@code r} (as the plugin's upload() does) and runs the queue as the worker. */
    private TransferRecord run(TransferRecord r) {
        String refused = UploadOptionsCheck.checkSize(r.protocol, r.partUrls.size(), r.partSize > 0 ? r.partSize : PART, PART, SIZE);
        assertEquals(null, refused);
        Runner.enqueue(store, r);
        assertTrue(Runner.begin(TransferRecord.UPLOAD));
        Runner.drain(store, TransferRecord.UPLOAD, new RunnerTest.Host(false));
        return store.get(TransferRecord.UPLOAD, r.id);
    }

    private JSONObject stored() throws Exception {
        String path = protocol.equals(UploadAdapters.AZURE_BLOCKS) ? "/azure/blob?name=" : "/s3/object?key=";
        return Harness.get(path + URLEncoder.encode(object, "UTF-8"));
    }

    private void assertStoredWhole() throws Exception {
        JSONObject o = stored();
        assertTrue("the object is on the server", o.getBoolean("exists"));
        assertEquals(SIZE, o.getLong("size"));
        assertEquals(sha256(data), o.getString("sha256"));
    }

    /** The proxy's log of requests that carried part or block {@code n}'s bytes. */
    private List<JSONObject> sendsOf(int n) throws Exception {
        List<JSONObject> out = new ArrayList<>();
        JSONArray all = Harness.requests(protocol.equals(UploadAdapters.AZURE_BLOCKS) ? "azure" : "s3");
        String blockId = PartsXml.blockId("t-" + protocol, SIZE, PART, n);
        for (int i = 0; i < all.length(); i++) {
            JSONObject q = all.getJSONObject(i);
            if (!q.getString("method").equals("PUT")) continue;
            boolean match = switch (protocol) {
                case UploadAdapters.S3_MULTIPART -> q.optInt("partNumber") == n;
                case UploadAdapters.AZURE_BLOCKS -> blockId.equals(q.optString("blockid"));
                default -> true;
            };
            if (match) out.add(q);
        }
        return out;
    }

    /** A fault on the request that commits the object (for put, the PUT itself). */
    private JSONObject onCommit(JSONObject fault) throws Exception {
        switch (protocol) {
            case UploadAdapters.S3_MULTIPART:
                return fault.put("target", "s3").put("method", "POST");
            case UploadAdapters.AZURE_BLOCKS:
                return fault.put("target", "azure").put("method", "PUT").put("query", "comp=blocklist");
            default:
                return fault.put("target", "s3").put("method", "PUT");
        }
    }

    /** A fault on the request carrying the second part or block (for put, the PUT). */
    private JSONObject onSecondPart(JSONObject fault) throws Exception {
        switch (protocol) {
            case UploadAdapters.S3_MULTIPART:
                return fault.put("target", "s3").put("method", "PUT").put("query", "partNumber=2&");
            case UploadAdapters.AZURE_BLOCKS:
                return fault.put("target", "azure").put("method", "PUT").put("query", "comp=block&");
            default:
                return fault.put("target", "s3").put("method", "PUT");
        }
    }

    // ---- The criteria ----

    @Test
    public void storesTheWholeObjectAndReportsLikeAnyUpload() throws Exception {
        TransferRecord r = run(upload());
        assertEquals(r.message, TransferRecord.FINISHED, r.state);
        assertEquals(SIZE, r.bytes);
        assertEquals(SIZE, r.total);
        assertStoredWhole();
        assertEquals(Arrays.asList("queued", "running", "finished"), events);
        // Progress: bytes so far, never back, never the whole object before it is confirmed, and the end.
        assertFalse(progress.isEmpty());
        for (int i = 1; i < progress.size(); i++) assertTrue(progress.get(i) >= progress.get(i - 1));
        assertEquals(Long.valueOf(SIZE), progress.get(progress.size() - 1));
        if (!protocol.equals(UploadAdapters.PUT)) {
            for (int n = 1; n <= 3; n++) assertEquals(1, sendsOf(n).size());
        }
    }

    @Test
    public void anInterruptedUploadResumesWithoutResendingWhatIsStored() throws Exception {
        TransferRecord r = upload();
        // Every Azure block matches the fault's query: let the first one through.
        if (protocol.equals(UploadAdapters.AZURE_BLOCKS)) {
            Harness.post("/faults", onSecondPart(new JSONObject()).put("action", "cut").put("after", MIB).put("skip", 1));
        } else {
            Harness.post(
                "/faults",
                onSecondPart(new JSONObject())
                    .put("action", "cut")
                    .put("after", 3 * MIB)
            );
        }
        TransferRecord first = run(r);
        assertEquals(TransferRecord.INTERRUPTED, first.state);
        assertEquals(TransferException.Reason.NETWORK, first.reason);
        assertFalse(stored().getBoolean("exists"));

        TransferRecord second = run(restart(r));
        assertEquals(second.message, TransferRecord.FINISHED, second.state);
        assertStoredWhole();
        if (protocol.equals(UploadAdapters.PUT)) {
            List<JSONObject> puts = sendsOf(1);
            assertEquals(2, puts.size());
            assertEquals(SIZE, puts.get(1).getLong("bytes"));
        } else {
            assertEquals("part 1 is not sent again", 1, sendsOf(1).size());
            assertEquals(2, sendsOf(2).size());
            assertEquals(1, sendsOf(3).size());
        }
    }

    @Test
    public void anExpiredUrlFailsAndSaysWhichRequest() throws Exception {
        // Without a ListParts URL, so the first request S3 refuses is a part's.
        TransferRecord r = upload(
            new JSONObject().put("expires", protocol.equals(UploadAdapters.AZURE_BLOCKS) ? -60 : 1).put("noListParts", true)
        );
        Thread.sleep(2100);
        TransferRecord done = run(r);
        assertEquals(TransferRecord.FAILED, done.state);
        assertEquals(TransferException.Reason.SESSION_REFUSED, done.reason);
        assertEquals(403, done.httpStatus);
        String which = switch (protocol) {
            case UploadAdapters.S3_MULTIPART -> "part 1 of 3";
            case UploadAdapters.AZURE_BLOCKS -> "block 1 of 3";
            default -> "PUT";
        };
        assertTrue(done.message, done.message.contains(which));
        assertFalse(events.contains("finished"));
        assertFalse(stored().getBoolean("exists"));
    }

    @Test
    public void aRefusedCommitFailsAndSaysSo() throws Exception {
        Harness.post("/faults", onCommit(new JSONObject()).put("action", "status").put("status", 403));
        TransferRecord done = run(upload());
        assertEquals(done.message, TransferRecord.FAILED, done.state);
        assertEquals(TransferException.Reason.SESSION_REFUSED, done.reason);
        assertEquals(403, done.httpStatus);
        String which = switch (protocol) {
            case UploadAdapters.S3_MULTIPART -> "complete";
            case UploadAdapters.AZURE_BLOCKS -> "commit";
            default -> "PUT";
        };
        assertTrue(done.message, done.message.contains(which));
        assertFalse(done.committing);
        assertFalse(stored().getBoolean("exists"));
    }

    @Test
    public void aLostCommitAnswerIsNeverTakenAsFinished() throws Exception {
        Harness.post("/faults", onCommit(new JSONObject()).put("action", "drop-answer"));
        TransferRecord r = upload();
        TransferRecord first = run(r);
        assertEquals(TransferRecord.INTERRUPTED, first.state);
        assertEquals(TransferException.Reason.NETWORK, first.reason);
        // The server did the work; only its answer was lost.
        assertStoredWhole();
        int before = Harness.requests(protocol.equals(UploadAdapters.AZURE_BLOCKS) ? "azure" : "s3").length();

        TransferRecord second = run(restart(r));
        if (protocol.equals(UploadAdapters.PUT)) {
            // Nothing to confirm but the PUT itself: it is sent again and answered.
            assertEquals(TransferRecord.FINISHED, second.state);
        } else {
            assertEquals(TransferRecord.FAILED, second.state);
            assertEquals(TransferException.Reason.SESSION_CLOSED, second.reason);
            assertTrue(second.message, second.message.contains("answer never came"));
            assertEquals(
                "nothing more is sent",
                before,
                Harness.requests(protocol.equals(UploadAdapters.AZURE_BLOCKS) ? "azure" : "s3").length()
            );
        }
        assertStoredWhole();
    }

    @Test
    public void s3ResumesFromItsOwnRecordWithoutAListPartsUrl() throws Exception {
        Assume.assumeTrue(protocol.equals(UploadAdapters.S3_MULTIPART));
        TransferRecord r = upload(new JSONObject().put("noListParts", true));
        Harness.post("/faults", onSecondPart(new JSONObject()).put("action", "cut").put("after", MIB));
        assertEquals(TransferRecord.INTERRUPTED, run(r).state);
        assertEquals(TransferRecord.FINISHED, run(restart(r)).state);
        assertStoredWhole();
        assertEquals(1, sendsOf(1).size());
    }

    @Test
    public void s3TakesA200WithAnErrorAsNotCompleted() throws Exception {
        Assume.assumeTrue(protocol.equals(UploadAdapters.S3_MULTIPART));
        Harness.post("/faults", onCommit(new JSONObject()).put("action", "status").put("status", 200));
        TransferRecord r = run(upload());
        assertEquals(TransferRecord.INTERRUPTED, r.state);
        assertEquals(TransferException.Reason.SERVER_ERROR, r.reason);
        assertFalse(r.committing);
        assertFalse(stored().getBoolean("exists"));
    }

    @Test
    public void azureWithoutReadPermissionResumesFromItsRecordAndRefusesAReadOnlySas() throws Exception {
        Assume.assumeTrue(protocol.equals(UploadAdapters.AZURE_BLOCKS));
        TransferRecord r = upload(new JSONObject().put("permissions", "cw"));
        Harness.post("/faults", onSecondPart(new JSONObject()).put("action", "cut").put("after", MIB).put("skip", 1));
        assertEquals(TransferRecord.INTERRUPTED, run(r).state);
        assertEquals(TransferRecord.FINISHED, run(restart(r)).state);
        assertStoredWhole();
        assertEquals(1, sendsOf(1).size());

        TransferRecord readOnly = upload(new JSONObject().put("permissions", "r"));
        readOnly.id = "t-read-only";
        TransferRecord refused = run(readOnly);
        assertEquals(TransferRecord.FAILED, refused.state);
        assertEquals(TransferException.Reason.SESSION_REFUSED, refused.reason);
        assertTrue(refused.message, refused.message.contains("block 1 of 3"));
    }

    @Test
    public void azureGivesTheBlobItsPropertiesWithTheCommitOnly() throws Exception {
        Assume.assumeTrue(protocol.equals(UploadAdapters.AZURE_BLOCKS));
        TransferRecord r = upload();
        r.headers.put("x-ms-blob-content-type", "video/mp4");
        assertEquals(TransferRecord.FINISHED, run(r).state);
        assertStoredWhole();
        assertEquals("video/mp4", stored().getString("contentType"));
    }

    private static String sha256(byte[] data) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder b = new StringBuilder();
        for (byte x : d) b.append(String.format("%02x", x));
        return b.toString();
    }
}
