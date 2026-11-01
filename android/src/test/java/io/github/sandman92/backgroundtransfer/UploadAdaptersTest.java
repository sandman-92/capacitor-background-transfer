package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

public class UploadAdaptersTest {

    @Test
    public void noProtocolMeansFirebaseResumable() throws Exception {
        assertEquals(UploadAdapters.FIREBASE_RESUMABLE, UploadAdapters.resolve(null));
        assertTrue(UploadAdapters.forProtocol(null, 1, 1) instanceof Uploader);
        assertTrue(UploadAdapters.forProtocol("firebase-resumable", 1, 1) instanceof Uploader);
    }

    @Test
    public void eachProtocolHasItsAdapter() throws Exception {
        assertTrue(UploadAdapters.forProtocol("put", 1, 1) instanceof PutUploader);
        assertTrue(UploadAdapters.forProtocol("s3-multipart", 1, 1) instanceof S3MultipartUploader);
        assertTrue(UploadAdapters.forProtocol("azure-blocks", 1, 1) instanceof AzureBlockUploader);
    }

    @Test
    public void anUnknownProtocolIsRefused() {
        assertNull(UploadAdapters.resolve("gcs-resumable"));
        assertEquals("protocol must be one of firebase-resumable, put, s3-multipart, azure-blocks", UploadAdapters.refusal());
        try {
            UploadAdapters.forProtocol("gcs-resumable", 1, 1);
            fail("expected a refusal");
        } catch (TransferException e) {
            assertEquals(TransferException.Reason.UNKNOWN, e.reason);
        }
    }

    @Test
    public void aStoredRecordKeepsItsPartsAndCommitAcrossTheStore() throws Exception {
        TransferRecord r = new TransferRecord();
        r.id = "a";
        r.direction = TransferRecord.UPLOAD;
        r.state = TransferRecord.RUNNING;
        r.url = "http://x/complete";
        r.path = "/a";
        r.protocol = UploadAdapters.S3_MULTIPART;
        r.partUrls.add("http://x/1");
        r.partUrls.add("http://x/2");
        r.partSize = 5 * UploadOptionsCheck.MIB;
        r.listPartsUrl = "http://x/list";
        r.parts.put(1, "\"e1\"");
        r.committing = true;
        TransferRecord back = TransferRecord.fromJson(r.toJson(false));
        assertEquals(r.partUrls, back.partUrls);
        assertEquals(r.partSize, back.partSize);
        assertEquals("http://x/list", back.listPartsUrl);
        assertEquals("\"e1\"", back.parts.get(1));
        assertTrue(back.committing);
        // JavaScript sees none of it.
        assertFalse(r.toJson(true).has("partUrls"));
        assertFalse(r.toJson(true).has("parts"));
    }

    @Test
    public void aStoredRecordKeepsItsProtocolAndAnOldOneGetsTheDefault() throws Exception {
        TransferRecord r = new TransferRecord();
        r.id = "a";
        r.direction = TransferRecord.UPLOAD;
        r.state = TransferRecord.QUEUED;
        r.url = "http://x/u";
        r.path = "/a";
        org.json.JSONObject json = r.toJson(false);
        assertEquals("firebase-resumable", TransferRecord.fromJson(json).protocol);
        json.remove("protocol");
        assertEquals(UploadAdapters.DEFAULT, TransferRecord.fromJson(json).protocol);
        assertEquals("firebase-resumable", r.toJson(true).getString("protocol"));
    }

    private static TransferRecord inParts(String protocol, long partSize, long total) {
        TransferRecord r = new TransferRecord();
        r.id = "a";
        r.direction = TransferRecord.UPLOAD;
        r.url = "http://x/complete";
        r.path = "/a";
        r.protocol = protocol;
        if (protocol.equals(UploadAdapters.AZURE_BLOCKS)) r.blockSize = partSize;
        else r.partSize = partSize;
        r.total = total;
        return r;
    }

    @Test
    public void partsCarryOverOnlyForTheSameRanges() {
        long m = UploadOptionsCheck.MIB;
        TransferRecord existing = inParts(UploadAdapters.S3_MULTIPART, 5 * m, 11 * m);
        assertTrue(Runner.carriesOver(existing, inParts(UploadAdapters.S3_MULTIPART, 5 * m, -1), 11 * m));
        assertFalse(
            "another part size covers other ranges",
            Runner.carriesOver(existing, inParts(UploadAdapters.S3_MULTIPART, 6 * m, -1), 11 * m)
        );
        assertFalse("the file changed", Runner.carriesOver(existing, inParts(UploadAdapters.S3_MULTIPART, 5 * m, -1), 12 * m));
        assertFalse(Runner.carriesOver(null, inParts(UploadAdapters.S3_MULTIPART, 5 * m, -1), 11 * m));
        TransferRecord other = inParts(UploadAdapters.S3_MULTIPART, 5 * m, -1);
        other.url = "http://x/other";
        assertFalse(Runner.carriesOver(existing, other, 11 * m));
        TransferRecord blob = inParts(UploadAdapters.AZURE_BLOCKS, 5 * m, 11 * m);
        assertFalse(Runner.carriesOver(blob, inParts(UploadAdapters.AZURE_BLOCKS, 4 * m, -1), 11 * m));
        assertTrue(Runner.carriesOver(blob, inParts(UploadAdapters.AZURE_BLOCKS, 5 * m, -1), 11 * m));
        // The resumable protocol keeps carrying over on the URL alone.
        TransferRecord session = inParts(UploadAdapters.FIREBASE_RESUMABLE, 0, 100);
        assertTrue(Runner.carriesOver(session, inParts(UploadAdapters.FIREBASE_RESUMABLE, 0, -1), 5));
    }

    @Test
    public void theBlobsPropertiesGoOnlyWithTheCommit() {
        java.util.Map<String, String> headers = new java.util.LinkedHashMap<>();
        headers.put("x-ms-blob-content-type", "video/mp4");
        headers.put("X-MS-Blob-Cache-Control", "no-cache");
        headers.put("X-Custom", "1");
        assertEquals(java.util.Collections.singletonMap("X-Custom", "1"), AzureBlockUploader.blockHeaders(headers));
    }
}
