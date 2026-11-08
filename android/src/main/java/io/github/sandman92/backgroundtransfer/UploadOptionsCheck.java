package io.github.sandman92.backgroundtransfer;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Checks an upload's protocol options the way {@code checkUploadOptions} in validate.ts does, with
 * the same words, and the part count against the file's size, which only the native side can
 * read. Plain Java, for the tests.
 */
public final class UploadOptionsCheck {

    public static final long MIB = 1024L * 1024L;
    public static final long DEFAULT_PART_SIZE = 8 * MIB;
    public static final long S3_MIN_PART_SIZE = 5 * MIB;
    public static final long S3_MAX_PART_SIZE = 5 * 1024 * MIB;
    public static final int S3_MAX_PARTS = 10_000;
    public static final long AZURE_MAX_BLOCK_SIZE = 4000 * MIB;
    public static final int AZURE_MAX_BLOCKS = 50_000;

    private static final Pattern HTTP_URL = Pattern.compile("^https?://[^/]+.*", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    private UploadOptionsCheck() {}

    /**
     * What is wrong with the options, or null. {@code partSize} and {@code blockSize} are null when
     * not given; a number that isn't whole arrives as NaN-free {@link Double} and is checked here.
     */
    public static String check(String protocol, String url, List<Object> partUrls, Double partSize, Object listPartsUrl, Double blockSize) {
        boolean s3 = UploadAdapters.S3_MULTIPART.equals(protocol);
        boolean azure = UploadAdapters.AZURE_BLOCKS.equals(protocol);
        if (!s3 && (partUrls != null || partSize != null || listPartsUrl != null)) {
            return "partUrls, partSize and listPartsUrl are only for s3-multipart";
        }
        if (!azure && blockSize != null) return "blockSize is only for azure-blocks";
        if (s3) {
            if (partUrls == null || partUrls.isEmpty()) return "partUrls is required for s3-multipart";
            if (partUrls.size() > S3_MAX_PARTS) return "partUrls holds more than " + S3_MAX_PARTS + " parts";
            for (Object u : partUrls) {
                if (!(u instanceof String) || !HTTP_URL.matcher((String) u).matches()) return "partUrls must be http or https URLs";
            }
            double size = partSize != null ? partSize : DEFAULT_PART_SIZE;
            if (!isWhole(size) || size < 1 || size > S3_MAX_PART_SIZE) return "partSize must be a whole number of bytes up to 5 GiB";
            if (partUrls.size() > 1 && size < S3_MIN_PART_SIZE) return "partSize must be at least 5 MiB when there is more than one part";
            if (listPartsUrl != null && (!(listPartsUrl instanceof String) || !HTTP_URL.matcher((String) listPartsUrl).matches())) {
                return "listPartsUrl must be an http or https URL";
            }
        }
        if (azure) {
            if (!isSasUrl(url)) return "url must be a blob SAS URL (with a sig parameter)";
            double size = blockSize != null ? blockSize : DEFAULT_PART_SIZE;
            if (
                !isWhole(size) || size < 1 || size > AZURE_MAX_BLOCK_SIZE
            ) return "blockSize must be a whole number of bytes up to 4000 MiB";
        }
        return null;
    }

    /** What is wrong with the part or block count for a {@code fileSize}-byte file, or null. */
    public static String checkSize(String protocol, int partUrlCount, long partSize, long blockSize, long fileSize) {
        if (UploadAdapters.S3_MULTIPART.equals(protocol)) {
            int needed = Parts.count(fileSize, partSize, true);
            if (needed > S3_MAX_PARTS) return (
                "a " + fileSize + "-byte file in " + partSize + "-byte parts needs more than " + S3_MAX_PARTS + " parts"
            );
            if (needed != partUrlCount) {
                return (
                    "partUrls holds " +
                    partUrlCount +
                    " parts but a " +
                    fileSize +
                    "-byte file in " +
                    partSize +
                    "-byte parts needs " +
                    needed
                );
            }
        }
        if (UploadAdapters.AZURE_BLOCKS.equals(protocol) && Parts.count(fileSize, blockSize, false) > AZURE_MAX_BLOCKS) {
            return "a " + fileSize + "-byte file in " + blockSize + "-byte blocks needs more than " + AZURE_MAX_BLOCKS + " blocks";
        }
        return null;
    }

    private static boolean isWhole(double d) {
        return !Double.isNaN(d) && !Double.isInfinite(d) && Math.floor(d) == d && Math.abs(d) <= 9_007_199_254_740_991d;
    }

    /** A blob URL with a SAS token: a non-empty {@code sig} parameter, and no {@code comp}. */
    static boolean isSasUrl(String url) {
        if (url == null) return false;
        int hash = url.indexOf('#');
        String u = hash >= 0 ? url.substring(0, hash) : url;
        int q = u.indexOf('?');
        if (q < 0) return false;
        boolean sig = false;
        for (String p : u.substring(q + 1).split("&")) {
            String name = p.contains("=") ? p.substring(0, p.indexOf('=')) : p;
            if (name.equals("comp")) return false;
            if (name.equals("sig") && p.length() > "sig=".length()) sig = true;
        }
        return sig;
    }
}
