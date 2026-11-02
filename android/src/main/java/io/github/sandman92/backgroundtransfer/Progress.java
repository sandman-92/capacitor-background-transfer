package io.github.sandman92.backgroundtransfer;

/** What an {@link Uploader} or {@link Downloader} reports, and how it is told to stop. */
public interface Progress {
    /** Bytes the server holds (upload) or that are on disk (download), and the total (-1 if unknown). */
    void onBytes(long bytes, long total);

    /** Checked between chunks and reads: non-null stops the transfer with that reason. */
    String stopReason();

    /** Saves the record now: an adapter has changed what it resumes from (a part sent, the commit sent). */
    default void saveState() {}
}
