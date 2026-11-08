package io.github.sandman92.backgroundtransfer;

/**
 * Why a transfer stopped. {@link #reason} is one of the {@code Reason}
 * strings, which are the TypeScript {@code TransferFailureReason} values.
 */
public class TransferException extends Exception {

    public static final class Reason {

        public static final String FILE_MISSING = "file-missing";
        public static final String DISK_FULL = "disk-full";
        public static final String SESSION_REFUSED = "session-refused";
        public static final String SESSION_EXPIRED = "session-expired";
        /** The session was already closed: whether the object was accepted only its metadata can say. */
        public static final String SESSION_CLOSED = "session-closed";
        public static final String SIZE_MISMATCH = "size-mismatch";
        public static final String NETWORK = "network";
        public static final String STOPPED_BY_SYSTEM = "stopped-by-system";
        public static final String CANCELLED = "cancelled";
        public static final String SERVER_ERROR = "server-error";
        public static final String UNKNOWN = "unknown";

        private Reason() {}
    }

    public final String reason;
    /** The HTTP status that stopped it, or 0. */
    public final int httpStatus;

    public TransferException(String reason, String message) {
        this(reason, message, 0, null);
    }

    public TransferException(String reason, String message, int httpStatus, Throwable cause) {
        super(message, cause);
        this.reason = reason;
        this.httpStatus = httpStatus;
    }

    /** Worth trying again later from where it stopped (the network, the system, a 5xx). */
    public boolean isResumable() {
        return Reason.NETWORK.equals(reason) || Reason.STOPPED_BY_SYSTEM.equals(reason) || Reason.SERVER_ERROR.equals(reason);
    }

    /** The reason for an HTTP status that isn't a success. */
    public static TransferException forStatus(int status, String what) {
        String reason;
        if (status == 404 || status == 410) reason = Reason.SESSION_EXPIRED;
        else if (status == 408 || status == 429 || status >= 500) reason = Reason.SERVER_ERROR;
        else reason = Reason.SESSION_REFUSED;
        String message = what + " HTTP " + status;
        if (status >= 300 && status < 400) message += " (a redirect, which an upload never follows)";
        return new TransferException(reason, message, status, null);
    }

    /** An I/O error while writing to local disk: full, or something else. */
    public static TransferException forDisk(java.io.IOException e) {
        String m = String.valueOf(e.getMessage());
        if (m.contains("ENOSPC") || m.toLowerCase(java.util.Locale.ROOT).contains("no space")) {
            return new TransferException(Reason.DISK_FULL, "no space left on the device", 0, e);
        }
        return new TransferException(Reason.UNKNOWN, "disk: " + m, 0, e);
    }
}
