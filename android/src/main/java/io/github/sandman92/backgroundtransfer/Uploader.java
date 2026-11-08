package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Map;

/**
 * Sends a file to a resumable upload session that the app has already
 * started (Firebase Storage's {@code X-Goog-Upload-*} protocol): asks the
 * server how many bytes it holds, sends the rest in {@link #CHUNK} pieces read
 * from the file in place, and finalizes with the last one. Memory is one chunk
 * buffer whatever the file's size. No {@code Authorization} header is sent
 * unless the caller passes one in {@code headers}.
 *
 * Plain Java (no Android types), so it runs under JUnit against a local
 * server.
 */
public final class Uploader implements UploadAdapter {

    /** A multiple of 256 KiB, as the protocol requires for every chunk but the last. */
    public static final int CHUNK = 4 * 1024 * 1024;

    private final int chunk;
    private final int retries;
    private final long backoffMillis;

    public Uploader() {
        this(CHUNK, 3, 2000);
    }

    /** For tests: a smaller chunk and quicker retries. */
    public Uploader(int chunk, int retries, long backoffMillis) {
        this.chunk = chunk;
        this.retries = retries;
        this.backoffMillis = backoffMillis;
    }

    /** What the server holds. */
    public static final class Status {

        public final long received;
        public final boolean isFinal;

        Status(long received, boolean isFinal) {
            this.received = received;
            this.isFinal = isFinal;
        }
    }

    /** One chunk: where it starts, how long it is, and whether it finalizes. */
    public static final class Chunk {

        public final long offset;
        public final int length;
        public final boolean last;

        Chunk(long offset, int length, boolean last) {
            this.offset = offset;
            this.length = length;
            this.last = last;
        }
    }

    /** The next chunk to send from {@code offset} of a {@code total}-byte file. */
    public static Chunk nextChunk(long offset, long total, int chunk) {
        if (offset < 0 || offset > total) throw new IllegalArgumentException("offset " + offset + " outside 0.." + total);
        int length = (int) Math.min(chunk, total - offset);
        return new Chunk(offset, length, offset + length >= total);
    }

    /**
     * Uploads {@code file} to {@code url}. Returns the file's size once the
     * server has finalized it. Network errors are retried {@code retries}
     * times from the server's offset before giving up with {@code network}.
     */
    @Override
    public long run(TransferRecord r, Progress progress) throws TransferException {
        return run(r.url, new File(r.path), r.headers, progress);
    }

    public long run(String url, File file, Map<String, String> headers, Progress progress) throws TransferException {
        int attempt = 0;
        while (true) {
            try {
                return attempt(url, file, headers, progress);
            } catch (TransferException e) {
                if (!TransferException.Reason.NETWORK.equals(e.reason) || attempt >= retries) throw e;
                attempt++;
                Pause.sleep(backoffMillis << (attempt - 1), progress);
            }
        }
    }

    private long attempt(String url, File file, Map<String, String> headers, Progress progress) throws TransferException {
        if (!file.isFile()) throw new TransferException(TransferException.Reason.FILE_MISSING, "no file at " + file);
        long total = file.length();
        Status status = query(url, headers);
        if (status.received > total) {
            throw new TransferException(
                TransferException.Reason.SIZE_MISMATCH,
                "server holds " + status.received + " of a " + total + "-byte file"
            );
        }
        if (status.isFinal) {
            // A closed session isn't proof the object was accepted: the Firebase Storage emulator, for
            // one, closes it even when security rules refuse the finalize. The app checks the object's metadata with its token.
            throw new TransferException(
                TransferException.Reason.SESSION_CLOSED,
                "the session was already closed at " + status.received + " of " + total + " bytes"
            );
        }
        long offset = status.received;
        progress.onBytes(offset, total);
        byte[] buffer = new byte[(int) Math.min(chunk, Math.max(total - offset, 0))];
        try (RandomAccessFile in = new RandomAccessFile(file, "r")) {
            do {
                Pause.check(progress);
                Chunk next = nextChunk(offset, total, chunk);
                try {
                    in.seek(next.offset);
                    in.readFully(buffer, 0, next.length);
                } catch (IOException e) {
                    throw new TransferException(
                        file.isFile() ? TransferException.Reason.UNKNOWN : TransferException.Reason.FILE_MISSING,
                        "reading the file: " + e.getMessage(),
                        0,
                        e
                    );
                }
                Status after = send(url, headers, buffer, next);
                if (next.last) {
                    if (!after.isFinal && after.received >= 0) {
                        throw new TransferException(
                            TransferException.Reason.SIZE_MISMATCH,
                            "finalize left the session active at " + after.received
                        );
                    }
                    offset = total;
                } else {
                    // The server says what it kept; carry on from there.
                    offset = after.received >= 0 ? after.received : next.offset + next.length;
                }
                progress.onBytes(offset, total);
            } while (offset < total);
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.FILE_MISSING, "opening the file: " + e.getMessage(), 0, e);
        }
        return total;
    }

    /** Asks the session how many bytes it holds. */
    public static Status query(String url, Map<String, String> headers) throws TransferException {
        HttpURLConnection c = null;
        try {
            c = open(url, headers);
            c.setRequestProperty("X-Goog-Upload-Command", "query");
            c.setFixedLengthStreamingMode(0);
            c.getOutputStream().close();
            int code = c.getResponseCode();
            if (code != 200) throw TransferException.forStatus(code, "query");
            Status s = statusOf(c);
            if (s.received < 0) throw new TransferException(
                TransferException.Reason.UNKNOWN,
                "query answered without X-Goog-Upload-Size-Received"
            );
            return s;
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.NETWORK, "query: " + e, 0, e);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static Status send(String url, Map<String, String> headers, byte[] buffer, Chunk chunk) throws TransferException {
        HttpURLConnection c = null;
        try {
            c = open(url, headers);
            c.setRequestProperty("X-Goog-Upload-Command", chunk.last ? "upload, finalize" : "upload");
            c.setRequestProperty("X-Goog-Upload-Offset", String.valueOf(chunk.offset));
            c.setRequestProperty("Content-Type", "application/octet-stream");
            c.setFixedLengthStreamingMode(chunk.length);
            try (OutputStream out = c.getOutputStream()) {
                out.write(buffer, 0, chunk.length);
            }
            int code = c.getResponseCode();
            if (code != 200) throw TransferException.forStatus(code, chunk.last ? "finalize" : "upload");
            return statusOf(c);
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.NETWORK, "upload at " + chunk.offset + ": " + e, 0, e);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static Status statusOf(HttpURLConnection c) {
        String received = c.getHeaderField("X-Goog-Upload-Size-Received");
        long n = -1;
        if (received != null) {
            try {
                n = Long.parseLong(received.trim());
            } catch (NumberFormatException ignored) {
                n = -1;
            }
        }
        return new Status(n, "final".equalsIgnoreCase(c.getHeaderField("X-Goog-Upload-Status")));
    }

    static HttpURLConnection open(String url, Map<String, String> headers) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setRequestMethod("POST");
        c.setInstanceFollowRedirects(false);
        c.setDoOutput(true);
        c.setUseCaches(false);
        c.setConnectTimeout(30_000);
        c.setReadTimeout(120_000);
        if (headers != null) {
            for (Map.Entry<String, String> h : headers.entrySet()) c.setRequestProperty(h.getKey(), h.getValue());
        }
        return c;
    }
}
