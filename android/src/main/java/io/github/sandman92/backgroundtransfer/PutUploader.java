package io.github.sandman92.backgroundtransfer;

import java.io.File;

/**
 * Sends the whole file in one {@code PUT} (an S3 presigned URL, an Azure SAS URL with
 * {@code x-ms-blob-type: BlockBlob}, or any server that takes one). Nothing to resume from: an
 * interrupted upload sends the file again from the first byte. Finished only on a 2xx.
 */
final class PutUploader implements UploadAdapter {

    private final int retries;
    private final long backoffMillis;

    PutUploader(int retries, long backoffMillis) {
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
        progress.onBytes(0, total);
        Http.Answer a = Http.send(
            "PUT",
            r.url,
            r.headers,
            "application/octet-stream",
            file,
            0,
            total,
            null,
            progress,
            (w) -> progress.onBytes(UploadAdapters.pending(w, total), total),
            null,
            "PUT"
        );
        if (a.status / 100 != 2) throw TransferException.forStatus(a.status, "PUT");
        progress.onBytes(total, total);
        return total;
    }
}
