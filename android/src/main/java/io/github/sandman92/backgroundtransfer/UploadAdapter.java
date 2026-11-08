package io.github.sandman92.backgroundtransfer;

/**
 * Sends a transfer's file in one protocol ({@link UploadAdapters}). An adapter that resumes from
 * its own record keeps that state on the record ({@code parts}, {@code committing}) and saves it
 * with {@link Progress#saveState()} as soon as it changes, so it survives the process.
 */
public interface UploadAdapter {
    /** Uploads {@code r}'s file; returns its size once the server has confirmed the whole object. */
    long run(TransferRecord r, Progress progress) throws TransferException;
}
