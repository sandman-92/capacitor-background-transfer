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

    public static final String DEFAULT = FIREBASE_RESUMABLE;

    public static final List<String> KNOWN = Collections.unmodifiableList(Arrays.asList(FIREBASE_RESUMABLE));

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
        throw new TransferException(TransferException.Reason.UNKNOWN, "unknown upload protocol " + name);
    }
}
