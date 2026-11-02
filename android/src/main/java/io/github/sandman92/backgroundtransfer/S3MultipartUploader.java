package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.util.Map;
import java.util.TreeMap;

/**
 * An S3 multipart upload the app has created, with every part URL, the completion URL and
 * optionally a ListParts URL presigned up front. Sends the parts one at a time from the file in
 * place, keeps each {@code ETag} on the record, skips the parts already stored when it resumes
 * (asking ListParts when it has the URL, trusting its record otherwise), then completes the upload
 * listing every part. Finished only when S3 answers the completion with the completed object.
 */
final class S3MultipartUploader implements UploadAdapter {

    private final int retries;
    private final long backoffMillis;

    S3MultipartUploader(int retries, long backoffMillis) {
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
        if (r.committing) throw UploadAdapters.commitUnconfirmed("the completion");
        long partSize = r.partSize > 0 ? r.partSize : UploadOptionsCheck.DEFAULT_PART_SIZE;
        int count = Parts.count(total, partSize, true);
        String bad = UploadOptionsCheck.checkSize(UploadAdapters.S3_MULTIPART, r.partUrls.size(), partSize, 0, total);
        if (bad != null) throw new TransferException(TransferException.Reason.SIZE_MISMATCH, bad);
        if (r.listPartsUrl != null) {
            r.parts = held(r, progress, total, partSize, count);
            progress.saveState();
        }
        long stored = 0;
        for (int n : r.parts.keySet()) if (n <= count) stored += Parts.length(n, total, partSize);
        progress.onBytes(UploadAdapters.pending(stored, total), total);
        for (int n = 1; n <= count; n++) {
            if (r.parts.containsKey(n)) continue;
            Pause.check(progress);
            final long base = stored;
            long length = Parts.length(n, total, partSize);
            String what = "part " + n + " of " + count;
            Http.Answer a = Http.send(
                "PUT",
                r.partUrls.get(n - 1),
                r.headers,
                "application/octet-stream",
                file,
                Parts.offset(n, partSize),
                length,
                null,
                progress,
                (w) -> progress.onBytes(UploadAdapters.pending(base + w, total), total),
                null,
                what
            );
            if (a.status != 200) throw TransferException.forStatus(a.status, what);
            if (a.etag == null || a.etag.isEmpty()) {
                throw new TransferException(TransferException.Reason.UNKNOWN, what + " answered without an ETag", a.status, null);
            }
            r.parts.put(n, a.etag);
            stored += length;
            progress.saveState();
            progress.onBytes(UploadAdapters.pending(stored, total), total);
        }
        Pause.check(progress);
        byte[] body = PartsXml.completeBody(r.parts, count).getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Http.Answer a = Http.send(
            "POST",
            r.url,
            r.headers,
            "application/xml",
            null,
            0,
            0,
            body,
            progress,
            null,
            () -> {
                // From here a lost answer can't be told from a completed upload.
                r.committing = true;
                progress.saveState();
            },
            "complete"
        );
        if (a.status == 200 && PartsXml.isCompleteResult(a.body)) {
            progress.onBytes(total, total);
            return total;
        }
        // An answer came, so the completion wasn't lost: it can be tried again.
        r.committing = false;
        progress.saveState();
        if (a.status == 404) {
            // NoSuchUpload: completed (perhaps by a completion whose answer was lost) or aborted.
            throw new TransferException(
                TransferException.Reason.SESSION_CLOSED,
                "complete HTTP 404: the upload is no longer open (completed or aborted): check the object",
                404,
                null
            );
        }
        if (a.status != 200) throw TransferException.forStatus(a.status, "complete");
        String code = PartsXml.errorCode(a.body);
        if (code == null) throw new TransferException(
            TransferException.Reason.UNKNOWN,
            "complete answered 200 without the completed object",
            200,
            null
        );
        boolean busy = code.equals("InternalError") || code.equals("SlowDown") || code.equals("ServiceUnavailable");
        throw new TransferException(
            busy ? TransferException.Reason.SERVER_ERROR : TransferException.Reason.SESSION_REFUSED,
            "complete answered 200 with " + code,
            200,
            null
        );
    }

    /** The parts S3 holds at their full size, by number; past a truncated list, the record's. */
    private static Map<Integer, String> held(TransferRecord r, Progress progress, long total, long partSize, int count)
        throws TransferException {
        Http.Answer a = Http.send("GET", r.listPartsUrl, r.headers, null, null, 0, 0, null, progress, null, null, "ListParts");
        if (a.status != 200) throw TransferException.forStatus(a.status, "ListParts");
        PartsXml.Listed listed = PartsXml.listParts(a.body);
        Map<Integer, String> kept = new TreeMap<>();
        for (int n = 1; n <= count; n++) {
            PartsXml.Held h = listed.parts.get(n);
            if (h != null) {
                if (h.size == Parts.length(n, total, partSize)) kept.put(n, h.tag);
            } else if (listed.truncated && n > listed.highest && r.parts.containsKey(n)) {
                kept.put(n, r.parts.get(n));
            }
        }
        return kept;
    }
}
