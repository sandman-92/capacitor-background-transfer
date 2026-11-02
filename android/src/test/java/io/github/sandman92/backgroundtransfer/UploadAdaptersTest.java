package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
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
    public void anUnknownProtocolIsRefused() {
        assertNull(UploadAdapters.resolve("s3-multipart"));
        assertEquals("protocol must be one of firebase-resumable", UploadAdapters.refusal());
        try {
            UploadAdapters.forProtocol("s3-multipart", 1, 1);
            fail("expected a refusal");
        } catch (TransferException e) {
            assertEquals(TransferException.Reason.UNKNOWN, e.reason);
        }
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
