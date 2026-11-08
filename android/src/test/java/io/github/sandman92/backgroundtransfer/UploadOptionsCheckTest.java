package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

/** The same refusals, in the same words, as validate.test.ts. */
public class UploadOptionsCheckTest {

    private static final long MIB = UploadOptionsCheck.MIB;
    private static final String S3 = UploadAdapters.S3_MULTIPART;
    private static final String AZURE = UploadAdapters.AZURE_BLOCKS;
    private static final String SAS = "https://acct.blob.core.windows.net/c/blob.bin?sv=2021-08-06&sr=b&sp=cw&sig=abc%3D";
    private static final List<Object> TWO = Arrays.asList("https://s3/b/k?partNumber=1", "https://s3/b/k?partNumber=2");

    private static String check(String protocol, String url, List<Object> parts, Double partSize, Object list, Double blockSize) {
        return UploadOptionsCheck.check(protocol, url, parts, partSize, list, blockSize);
    }

    @Test
    public void acceptsWellFormedOptions() {
        assertNull(check(UploadAdapters.PUT, "https://x/put", null, null, null, null));
        assertNull(check(S3, "https://s3/b/k?uploadId=x", TWO, null, null, null));
        assertNull(check(S3, "https://s3/b/k?uploadId=x", TWO, (double) (5 * MIB), "https://s3/b/k?uploadId=x", null));
        assertNull(check(S3, "https://s3/b/k?uploadId=x", Collections.singletonList("https://s3/1"), 1000d, null, null));
        assertNull(check(AZURE, SAS, null, null, null, 1024d));
    }

    @Test
    public void refusesWhatTheWebRefuses() {
        String complete = "https://s3/b/k?uploadId=x";
        assertEquals("partUrls is required for s3-multipart", check(S3, complete, null, null, null, null));
        assertEquals("partUrls is required for s3-multipart", check(S3, complete, new ArrayList<>(), null, null, null));
        assertEquals(
            "partUrls must be http or https URLs",
            check(S3, complete, Arrays.asList("https://s3/1", "ftp://x/2"), null, null, null)
        );
        assertEquals("partUrls must be http or https URLs", check(S3, complete, Arrays.asList("https://s3/1", 7), null, null, null));
        assertEquals(
            "partUrls holds more than 10000 parts",
            check(S3, complete, new ArrayList<>(Collections.nCopies(10001, "https://s3/1")), null, null, null)
        );
        assertEquals(
            "partSize must be at least 5 MiB when there is more than one part",
            check(S3, complete, TWO, (double) (5 * MIB - 1), null, null)
        );
        assertEquals("partSize must be a whole number of bytes up to 5 GiB", check(S3, complete, TWO, 0d, null, null));
        assertEquals("partSize must be a whole number of bytes up to 5 GiB", check(S3, complete, TWO, 5.5 * MIB + 0.5, null, null));
        assertEquals(
            "partSize must be a whole number of bytes up to 5 GiB",
            check(S3, complete, TWO, (double) (5 * 1024 * MIB + 1), null, null)
        );
        assertEquals("partSize must be a whole number of bytes up to 5 GiB", check(S3, complete, TWO, Double.NaN, null, null));
        assertEquals("listPartsUrl must be an http or https URL", check(S3, complete, TWO, null, "list", null));
        assertEquals(
            "partUrls, partSize and listPartsUrl are only for s3-multipart",
            check(UploadAdapters.PUT, "https://x/put", TWO, null, null, null)
        );
        assertEquals("partUrls, partSize and listPartsUrl are only for s3-multipart", check(AZURE, SAS, null, 8d * MIB, null, null));
        assertEquals("blockSize is only for azure-blocks", check(S3, complete, TWO, null, null, 8d * MIB));
        assertEquals("blockSize is only for azure-blocks", check(UploadAdapters.FIREBASE_RESUMABLE, "https://x/u", null, null, null, 1d));
        assertEquals("url must be a blob SAS URL (with a sig parameter)", check(AZURE, "https://acct/c/blob", null, null, null, null));
        assertEquals(
            "url must be a blob SAS URL (with a sig parameter)",
            check(AZURE, "https://acct/c/blob?sv=1&sig=", null, null, null, null)
        );
        assertEquals("url must be a blob SAS URL (with a sig parameter)", check(AZURE, SAS + "&comp=block", null, null, null, null));
        assertEquals("blockSize must be a whole number of bytes up to 4000 MiB", check(AZURE, SAS, null, null, null, 4000d * MIB + 1));
        assertEquals("blockSize must be a whole number of bytes up to 4000 MiB", check(AZURE, SAS, null, null, null, -1d));
    }

    @Test
    public void thePartCountMustFitTheFile() {
        assertNull(UploadOptionsCheck.checkSize(S3, 3, 5 * MIB, 0, 11 * MIB));
        assertNull(UploadOptionsCheck.checkSize(S3, 2, 5 * MIB, 0, 10 * MIB));
        assertNull(UploadOptionsCheck.checkSize(S3, 1, 5 * MIB, 0, 0));
        assertEquals(
            "partUrls holds 2 parts but a 11534336-byte file in 5242880-byte parts needs 3",
            UploadOptionsCheck.checkSize(S3, 2, 5 * MIB, 0, 11 * MIB)
        );
        assertEquals(
            "a 53687091201-byte file in 5242880-byte parts needs more than 10000 parts",
            UploadOptionsCheck.checkSize(S3, 10000, 5 * MIB, 0, 51200L * MIB + 1)
        );
        assertNull(UploadOptionsCheck.checkSize(AZURE, 0, 0, MIB, 50_000 * MIB));
        assertEquals(
            "a 52428800001-byte file in 1048576-byte blocks needs more than 50000 blocks",
            UploadOptionsCheck.checkSize(AZURE, 0, 0, MIB, 50_000 * MIB + 1)
        );
    }

    @Test
    public void partsCoverTheFile() {
        assertEquals(3, Parts.count(11 * MIB, 5 * MIB, true));
        assertEquals(1, Parts.count(0, 5 * MIB, true));
        assertEquals(0, Parts.count(0, 5 * MIB, false));
        assertEquals(10 * MIB, Parts.offset(3, 5 * MIB));
        assertEquals(MIB, Parts.length(3, 11 * MIB, 5 * MIB));
        assertEquals(5 * MIB, Parts.length(2, 11 * MIB, 5 * MIB));
    }
}
