package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.TreeMap;
import org.junit.Test;

public class PartsXmlTest {

    @Test
    public void readsListPartsWithItsEntitiesAndPaging() throws Exception {
        String xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListPartsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" +
            "<Bucket>b</Bucket><IsTruncated>true</IsTruncated>" +
            "<Part><PartNumber>1</PartNumber><ETag>&#34;aa&#34;</ETag><Size>5242880</Size></Part>" +
            "<Part><PartNumber>3</PartNumber><ETag>&quot;cc&quot;</ETag><Size>100</Size></Part></ListPartsResult>";
        PartsXml.Listed l = PartsXml.listParts(xml);
        assertTrue(l.truncated);
        assertEquals(3, l.highest);
        assertEquals("\"aa\"", l.parts.get(1).tag);
        assertEquals(5242880, l.parts.get(1).size);
        assertEquals("\"cc\"", l.parts.get(3).tag);
        assertNull(l.parts.get(2));
    }

    @Test(expected = TransferException.class)
    public void refusesXmlItCannotRead() throws Exception {
        PartsXml.listParts("<ListPartsResult><Part>");
    }

    @Test
    public void listsEveryPartInTheCompletion() {
        Map<Integer, String> etags = new TreeMap<>();
        etags.put(2, "\"b\"");
        etags.put(1, "\"a&\"");
        assertEquals(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>" +
            "<Part><PartNumber>1</PartNumber><ETag>&quot;a&amp;&quot;</ETag></Part>" +
            "<Part><PartNumber>2</PartNumber><ETag>&quot;b&quot;</ETag></Part></CompleteMultipartUpload>",
            PartsXml.completeBody(etags, 2)
        );
    }

    @Test
    public void tellsACompletedObjectFromAnErrorAnsweredWith200() {
        assertTrue(PartsXml.isCompleteResult("<CompleteMultipartUploadResult><ETag>x</ETag></CompleteMultipartUploadResult>"));
        String error = "<?xml version=\"1.0\"?>\n<Error><Code>InternalError</Code><Message>m</Message></Error>";
        assertFalse(PartsXml.isCompleteResult(error));
        assertEquals("InternalError", PartsXml.errorCode(error));
        assertFalse(PartsXml.isCompleteResult(""));
        assertNull(PartsXml.errorCode("<CompleteMultipartUploadResult/>"));
    }

    @Test
    public void readsTheUncommittedBlocks() throws Exception {
        String xml =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><CommittedBlocks><Block><Name>Yw==</Name><Size>1</Size></Block></CommittedBlocks>" +
            "<UncommittedBlocks><Block><Name>QQ==</Name><Size>5</Size></Block><Block><Name>Qg==</Name><Size>6</Size></Block></UncommittedBlocks></BlockList>";
        Map<String, Long> blocks = PartsXml.uncommittedBlocks(xml);
        assertEquals(2, blocks.size());
        assertEquals(Long.valueOf(5), blocks.get("QQ=="));
        assertEquals(Long.valueOf(6), blocks.get("Qg=="));
        assertTrue(PartsXml.uncommittedBlocks("<BlockList><UncommittedBlocks /></BlockList>").isEmpty());
    }

    @Test
    public void blockIdsAreStableTheSameLengthAndAsIosMakesThem() {
        String id = PartsXml.blockId("clip-42", 12 * UploadOptionsCheck.MIB, 5 * UploadOptionsCheck.MIB, 3);
        // The same value is asserted in the iOS core's tests.
        assertEquals("MTE4NGE1YmM0YjAxOGU3OC0wMDAwMDM=", id);
        assertEquals(id, PartsXml.blockId("clip-42", 12 * UploadOptionsCheck.MIB, 5 * UploadOptionsCheck.MIB, 3));
        assertFalse(id.equals(PartsXml.blockId("clip-43", 12 * UploadOptionsCheck.MIB, 5 * UploadOptionsCheck.MIB, 3)));
        assertEquals(id.length(), PartsXml.blockId("clip-42", 1, 1, 999_999).length());
        assertEquals(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>QQ==</Latest><Latest>Qg==</Latest></BlockList>",
            PartsXml.blockListBody(Arrays.asList("QQ==", "Qg=="))
        );
    }

    @Test
    public void base64MatchesTheJdks() {
        for (String s : new String[] { "", "a", "ab", "abc", "abcd", "0123456789abcdef-000001" }) {
            byte[] b = s.getBytes(StandardCharsets.US_ASCII);
            assertEquals(Base64.getEncoder().encodeToString(b), PartsXml.base64(b));
        }
    }
}
