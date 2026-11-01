package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.UnsupportedEncodingException;
import java.net.URLEncoder;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * An Azure block blob through one SAS URL: sends the blocks one at a time from the file in place
 * with stable ids ({@code Put Block}), skips the ones in the blob's uncommitted block list when it
 * resumes (or, when the SAS can't read the list, the ones its record holds), then commits them
 * ({@code Put Block List}). Finished only when Azure answers the commit with 201.
 */
final class AzureBlockUploader implements UploadAdapter {

    private final int retries;
    private final long backoffMillis;

    AzureBlockUploader(int retries, long backoffMillis) {
        this.retries = retries;
        this.backoffMillis = backoffMillis;
    }

    @Override
    public long run(TransferRecord r, Progress progress) throws TransferException {
        return UploadAdapters.withRetries(retries, backoffMillis, progress, () -> attempt(r, progress));
    }

    private static long attempt(TransferRecord r, Progress progress) throws TransferException {
        File file = UploadAdapters.fileOf(r);
        long total = file.length();
        if (r.committing) throw UploadAdapters.commitUnconfirmed("the block list");
        long blockSize = r.blockSize > 0 ? r.blockSize : UploadOptionsCheck.DEFAULT_PART_SIZE;
        String bad = UploadOptionsCheck.checkSize(UploadAdapters.AZURE_BLOCKS, 0, 0, blockSize, total);
        if (bad != null) throw new TransferException(TransferException.Reason.SIZE_MISMATCH, bad);
        int count = Parts.count(total, blockSize, false);
        List<String> ids = PartsXml.blockIds(r.id, total, blockSize, count);
        Http.Answer list = Http.send(
            "GET",
            Http.withQuery(r.url, "comp=blocklist&blocklisttype=uncommitted"),
            r.headers,
            null,
            null,
            0,
            0,
            null,
            progress,
            null,
            null,
            "Get Block List"
        );
        if (list.status == 200) {
            Map<String, Long> held = PartsXml.uncommittedBlocks(list.body);
            Map<Integer, String> kept = new TreeMap<>();
            for (int n = 1; n <= count; n++) {
                Long size = held.get(ids.get(n - 1));
                if (size != null && size == Parts.length(n, total, blockSize)) kept.put(n, ids.get(n - 1));
            }
            r.parts = kept;
        } else if (list.status == 404) {
            // No blob and no blocks yet (or they expired): everything goes.
            r.parts = new TreeMap<>();
        } else if (list.status != 403) {
            // 403: the SAS can't read the list (no `r`); trust the record. An expired SAS fails on the first block.
            throw TransferException.forStatus(list.status, "Get Block List");
        }
        r.parts.keySet().removeIf((n) -> n > count || !ids.get(n - 1).equals(r.parts.get(n)));
        progress.saveState();
        long stored = 0;
        for (int n : r.parts.keySet()) stored += Parts.length(n, total, blockSize);
        progress.onBytes(UploadAdapters.pending(stored, total), total);
        for (int n = 1; n <= count; n++) {
            if (r.parts.containsKey(n)) continue;
            Pause.check(progress);
            final long base = stored;
            long length = Parts.length(n, total, blockSize);
            String what = "block " + n + " of " + count;
            Http.Answer a = Http.send(
                "PUT",
                Http.withQuery(r.url, "comp=block&blockid=" + encode(ids.get(n - 1))),
                blockHeaders(r.headers),
                "application/octet-stream",
                file,
                Parts.offset(n, blockSize),
                length,
                null,
                progress,
                (w) -> progress.onBytes(UploadAdapters.pending(base + w, total), total),
                null,
                what
            );
            if (a.status != 201) throw TransferException.forStatus(a.status, what);
            r.parts.put(n, ids.get(n - 1));
            stored += length;
            progress.saveState();
            progress.onBytes(UploadAdapters.pending(stored, total), total);
        }
        Pause.check(progress);
        byte[] body = PartsXml.blockListBody(ids).getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Http.Answer a = Http.send(
            "PUT",
            Http.withQuery(r.url, "comp=blocklist"),
            r.headers,
            "application/xml",
            null,
            0,
            0,
            body,
            progress,
            null,
            () -> {
                r.committing = true;
                progress.saveState();
            },
            "commit (Put Block List)"
        );
        if (a.status == 201) {
            progress.onBytes(total, total);
            return total;
        }
        r.committing = false;
        progress.saveState();
        throw TransferException.forStatus(a.status, "commit (Put Block List)");
    }

    /**
     * The headers for a block: all but the blob's properties ({@code x-ms-blob-content-type} and
     * the other {@code x-ms-blob-*} ones), which belong to the commit that creates the blob.
     */
    static Map<String, String> blockHeaders(Map<String, String> headers) {
        Map<String, String> out = new java.util.LinkedHashMap<>();
        if (headers == null) return out;
        for (Map.Entry<String, String> h : headers.entrySet()) {
            if (!h.getKey().toLowerCase(java.util.Locale.ROOT).startsWith("x-ms-blob-")) out.put(h.getKey(), h.getValue());
        }
        return out;
    }

    private static String encode(String id) {
        try {
            return URLEncoder.encode(id, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
    }
}
