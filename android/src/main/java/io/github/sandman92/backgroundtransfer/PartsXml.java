package io.github.sandman92.backgroundtransfer;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/** The XML that S3 multipart uploads and Azure block blobs speak, and Azure's block ids. */
final class PartsXml {

    private PartsXml() {}

    /** A part or block the server holds. */
    static final class Held {

        final String tag;
        final long size;

        Held(String tag, long size) {
            this.tag = tag;
            this.size = size;
        }
    }

    /** What {@code ListParts} answered: part number → ETag and size, and whether more pages follow. */
    static final class Listed {

        final Map<Integer, Held> parts = new LinkedHashMap<>();
        boolean truncated;
        int highest;
    }

    static Listed listParts(String xml) throws TransferException {
        Element root = parse(xml, "ListParts");
        Listed out = new Listed();
        out.truncated = "true".equalsIgnoreCase(text(root, "IsTruncated"));
        for (Element part : children(root, "Part")) {
            try {
                int n = Integer.parseInt(text(part, "PartNumber").trim());
                out.parts.put(n, new Held(text(part, "ETag"), Long.parseLong(text(part, "Size").trim())));
                out.highest = Math.max(out.highest, n);
            } catch (NumberFormatException e) {
                throw new TransferException(TransferException.Reason.UNKNOWN, "ListParts answered with a part that has no number or size");
            }
        }
        return out;
    }

    /** The {@code CompleteMultipartUpload} body listing every part. */
    static String completeBody(Map<Integer, String> etags, int count) {
        StringBuilder b = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>");
        for (int n = 1; n <= count; n++) {
            b.append("<Part><PartNumber>").append(n).append("</PartNumber><ETag>").append(escape(etags.get(n))).append("</ETag></Part>");
        }
        return b.append("</CompleteMultipartUpload>").toString();
    }

    /**
     * The error code in an S3 answer, or null when it isn't an {@code <Error>}. S3 can answer
     * {@code CompleteMultipartUpload} with 200 and an error in the body.
     */
    static String errorCode(String xml) {
        if (xml == null || !xml.contains("<Error")) return null;
        try {
            Element root = parse(xml, "answer");
            if (!"Error".equals(root.getTagName())) return null;
            String code = text(root, "Code");
            return code.isEmpty() ? "Error" : code;
        } catch (TransferException e) {
            return "Error";
        }
    }

    /** Whether a 200 answer to {@code CompleteMultipartUpload} is the completed object. */
    static boolean isCompleteResult(String xml) {
        return xml != null && xml.contains("CompleteMultipartUploadResult") && errorCode(xml) == null;
    }

    /** Azure's {@code Get Block List}: block id → size, for the uncommitted blocks. */
    static Map<String, Long> uncommittedBlocks(String xml) throws TransferException {
        Element root = parse(xml, "Get Block List");
        Map<String, Long> out = new LinkedHashMap<>();
        for (Element section : children(root, "UncommittedBlocks")) {
            for (Element block : children(section, "Block")) {
                try {
                    out.put(text(block, "Name"), Long.parseLong(text(block, "Size").trim()));
                } catch (NumberFormatException e) {
                    throw new TransferException(TransferException.Reason.UNKNOWN, "Get Block List answered with a block that has no size");
                }
            }
        }
        return out;
    }

    /** The {@code Put Block List} body committing {@code ids} in order. */
    static String blockListBody(List<String> ids) {
        StringBuilder b = new StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>");
        for (String id : ids) b.append("<Latest>").append(escape(id)).append("</Latest>");
        return b.append("</BlockList>").toString();
    }

    /**
     * Block {@code n}'s id: the same for the same transfer, file size and block size, so a resumed
     * upload finds its blocks, and different for a different file. Every id of a blob has the same
     * length, as Azure requires. iOS makes the same ids.
     */
    static String blockId(String transferId, long size, long blockSize, int n) {
        String prefix;
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(
                (transferId + "|" + size + "|" + blockSize).getBytes(StandardCharsets.UTF_8)
            );
            StringBuilder hex = new StringBuilder();
            for (int i = 0; i < 8; i++) hex.append(String.format("%02x", hash[i]));
            prefix = hex.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        String raw = prefix + "-" + String.format(java.util.Locale.ROOT, "%06d", n);
        return base64(raw.getBytes(StandardCharsets.US_ASCII));
    }

    private static final char[] B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    /** Standard Base64 with padding (java.util.Base64 needs Android 8). */
    static String base64(byte[] in) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < in.length; i += 3) {
            int n = (in[i] & 0xff) << 16;
            if (i + 1 < in.length) n |= (in[i + 1] & 0xff) << 8;
            if (i + 2 < in.length) n |= in[i + 2] & 0xff;
            b.append(B64[(n >> 18) & 63]).append(B64[(n >> 12) & 63]);
            b.append(i + 1 < in.length ? B64[(n >> 6) & 63] : '=');
            b.append(i + 2 < in.length ? B64[n & 63] : '=');
        }
        return b.toString();
    }

    static List<String> blockIds(String transferId, long size, long blockSize, int count) {
        List<String> ids = new ArrayList<>();
        for (int n = 1; n <= count; n++) ids.add(blockId(transferId, size, blockSize, n));
        return ids;
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

    private static Element parse(String xml, String what) throws TransferException {
        try {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setNamespaceAware(false);
            f.setExpandEntityReferences(false);
            try {
                f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            } catch (Exception ignored) {
                // Not every parser knows the feature; the answers carry no DOCTYPE anyway.
            }
            Document d = f.newDocumentBuilder().parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)));
            return d.getDocumentElement();
        } catch (Exception e) {
            throw new TransferException(TransferException.Reason.UNKNOWN, what + " answered with XML that couldn't be read", 0, e);
        }
    }

    private static List<Element> children(Element parent, String tag) {
        List<Element> out = new ArrayList<>();
        NodeList nodes = parent.getChildNodes();
        for (int i = 0; i < nodes.getLength(); i++) {
            Node n = nodes.item(i);
            if (n instanceof Element && localName((Element) n).equals(tag)) out.add((Element) n);
        }
        return out;
    }

    private static String localName(Element e) {
        String name = e.getTagName();
        int colon = name.indexOf(':');
        return colon >= 0 ? name.substring(colon + 1) : name;
    }

    private static String text(Element parent, String tag) {
        List<Element> found = children(parent, tag);
        return found.isEmpty() ? "" : found.get(0).getTextContent();
    }
}
