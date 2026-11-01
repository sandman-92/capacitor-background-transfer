package io.github.sandman92.backgroundtransfer;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * The upload protocols this version speaks, by the name the JavaScript side passes in
 * {@code protocol}. Another protocol plugs in here: a name, and an {@link UploadAdapter} for it.
 */
public final class UploadAdapters {

    /** A Firebase Storage resumable upload: the {@code X-Goog-Upload-*} protocol. */
    public static final String FIREBASE_RESUMABLE = "firebase-resumable";
    /** The whole file in one {@code PUT}. */
    public static final String PUT = "put";
    /** An S3 multipart upload with every URL presigned up front. */
    public static final String S3_MULTIPART = "s3-multipart";
    /** An Azure block blob through one SAS URL. */
    public static final String AZURE_BLOCKS = "azure-blocks";

    public static final String DEFAULT = FIREBASE_RESUMABLE;

    public static final List<String> KNOWN = Collections.unmodifiableList(Arrays.asList(FIREBASE_RESUMABLE, PUT, S3_MULTIPART, AZURE_BLOCKS));

    private UploadAdapters() {}

    /** The protocol to use for {@code name}: the default when null, or null when unknown. */
    public static String resolve(String name) {
        if (name == null) return DEFAULT;
        return KNOWN.contains(name) ? name : null;
    }

    /** What the plugin says when it refuses an unknown protocol. */
    public static String refusal() {
        return "protocol must be one of " + String.join(", ", KNOWN);
    }

    /** The adapter for a known protocol; throws for an unknown one (a record from a later version). */
    public static UploadAdapter forProtocol(String name, int retries, long backoffMillis) throws TransferException {
        String protocol = resolve(name);
        if (FIREBASE_RESUMABLE.equals(protocol)) return new Uploader(Uploader.CHUNK, retries, backoffMillis);
        if (PUT.equals(protocol)) return new PutUploader(retries, backoffMillis);
        if (S3_MULTIPART.equals(protocol)) return new S3MultipartUploader(retries, backoffMillis);
        if (AZURE_BLOCKS.equals(protocol)) return new AzureBlockUploader(retries, backoffMillis);
        throw new TransferException(TransferException.Reason.UNKNOWN, "unknown upload protocol " + name);
    }

    /** One try at an upload. */
    interface Attempt {
        long run() throws TransferException;
    }

    /** Runs {@code attempt}, trying again after a dropped connection up to {@code retries} times. */
    static long withRetries(int retries, long backoffMillis, Progress progress, Attempt attempt) throws TransferException {
        int tries = 0;
        while (true) {
            try {
                return attempt.run();
            } catch (TransferException e) {
                if (!TransferException.Reason.NETWORK.equals(e.reason) || tries >= retries) throw e;
                tries++;
                Pause.sleep(backoffMillis << (tries - 1), progress);
            }
        }
    }

    /** The file to send, or {@code file-missing}. */
    static java.io.File fileOf(TransferRecord r) throws TransferException {
        java.io.File file = new java.io.File(r.path);
        if (!file.isFile()) throw new TransferException(TransferException.Reason.FILE_MISSING, "no file at " + file);
        return file;
    }

    /** Bytes to report before the server has confirmed the object: never the whole of it. */
    static long pending(long bytes, long total) {
        return total <= 0 ? 0 : Math.min(bytes, total - 1);
    }

    /** The commit was sent in an earlier try and its answer never came. */
    static TransferException commitUnconfirmed(String what) {
        return new TransferException(
            TransferException.Reason.SESSION_CLOSED,
            what + " was sent earlier and its answer never came: check the object before starting a new upload"
        );
    }
}
