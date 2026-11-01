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
}
