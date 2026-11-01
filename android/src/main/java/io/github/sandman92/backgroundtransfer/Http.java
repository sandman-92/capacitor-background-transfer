package io.github.sandman92.backgroundtransfer;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** One request of an upload in parts, with its body read from the file in place or from memory. */
final class Http {

    /** Bytes written per piece, between progress reports and stop checks. */
    static final int PIECE = 256 * 1024;
    private static final int MAX_BODY = 64 * 1024;
    /** A body write that makes no headway this long ends the request (as a dropped connection). */
    static long STALL_MILLIS = 60_000;
    private static final java.util.concurrent.ScheduledExecutorService WATCHDOG =
        java.util.concurrent.Executors.newSingleThreadScheduledExecutor((r) -> {
            Thread t = new Thread(r, "BackgroundTransfer write watchdog");
            t.setDaemon(true);
            return t;
        });
    private static final boolean ON_ANDROID = String.valueOf(System.getProperty("java.vm.vendor")).contains("Android");

    private Http() {}

    /** The answer: status, the headers asked for, and up to 64 KiB of body. */
    static final class Answer {

        final int status;
        final String etag;
        final String body;

        Answer(int status, String etag, String body) {
            this.status = status;
            this.etag = etag;
            this.body = body;
        }
    }

    /** Told after the connection is open and before the body is written (the commit marks itself sent). */
    interface Sending {
        void now() throws TransferException;
    }

    /** Reports body bytes written as they go: {@code written} of this request. */
    interface Written {
        void bytes(long written);
    }

    /**
     * Sends {@code method url} with {@code length} bytes of {@code file} from {@code offset} (or
     * {@code body} when it isn't null), checking {@code progress} for a stop between pieces. An I/O
     * error is {@code network}, with {@code what} in the message.
     */
    static Answer send(
        String method,
        String url,
        Map<String, String> headers,
        String contentType,
        File file,
        long offset,
        long length,
        byte[] body,
        Progress progress,
        Written written,
        Sending sending,
        String what
    ) throws TransferException {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setRequestMethod(method);
            c.setUseCaches(false);
            c.setConnectTimeout(30_000);
            c.setReadTimeout(120_000);
            boolean hasType = false;
            if (headers != null) {
                for (Map.Entry<String, String> h : headers.entrySet()) {
                    c.setRequestProperty(h.getKey(), h.getValue());
                    if (h.getKey().equalsIgnoreCase("Content-Type")) hasType = true;
                }
            }
            long size = body != null ? body.length : length;
            boolean sendsBody = body != null || file != null;
            if (sendsBody) {
                c.setDoOutput(true);
                if (!hasType && contentType != null) c.setRequestProperty("Content-Type", contentType);
                c.setFixedLengthStreamingMode(size);
                // A server that will refuse the request (an expired URL) says so before the body goes.
                // The JDK's client needs this to read such an answer; Android's reads it anyway (earlyAnswer).
                if (file != null && length > 0 && !ON_ANDROID) c.setRequestProperty("Expect", "100-continue");
            }
            c.connect();
            if (sending != null) sending.now();
            if (sendsBody) {
                // A write has no timeout of its own: one that makes no headway is ended from outside.
                final HttpURLConnection conn = c;
                final long[] lastWrite = { System.currentTimeMillis() };
                java.util.concurrent.ScheduledFuture<?> watch = WATCHDOG.scheduleWithFixedDelay(
                    () -> {
                        if (System.currentTimeMillis() - lastWrite[0] > STALL_MILLIS) conn.disconnect();
                    },
                    5,
                    5,
                    java.util.concurrent.TimeUnit.SECONDS
                );
                Written seen = (w) -> {
                    lastWrite[0] = System.currentTimeMillis();
                    if (written != null) written.bytes(w);
                };
                try (OutputStream out = c.getOutputStream()) {
                    if (body != null) {
                        out.write(body);
                    } else {
                        writeRange(file, offset, length, out, progress, seen);
                    }
                } catch (IOException e) {
                    // A server that refuses a request (an expired URL, a bad signature) may answer
                    // before the body is in and close the connection: read that answer if it came.
                    Answer early = earlyAnswer(c);
                    if (early != null) return early;
                    throw e;
                } finally {
                    watch.cancel(false);
                }
            }
            int status = c.getResponseCode();
            return new Answer(status, c.getHeaderField("ETag"), readBody(c, status));
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.NETWORK, what + ": " + e, 0, e);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static void writeRange(File file, long offset, long length, OutputStream out, Progress progress, Written written)
        throws IOException, TransferException {
        byte[] buffer = new byte[(int) Math.min(PIECE, Math.max(length, 1))];
        RandomAccessFile in;
        try {
            in = new RandomAccessFile(file, "r");
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.FILE_MISSING, "opening the file: " + e.getMessage(), 0, e);
        }
        try {
            in.seek(offset);
            long sent = 0;
            while (sent < length) {
                Pause.check(progress);
                int n = (int) Math.min(buffer.length, length - sent);
                try {
                    in.readFully(buffer, 0, n);
                } catch (IOException e) {
                    throw new TransferException(
                        file.isFile() ? TransferException.Reason.UNKNOWN : TransferException.Reason.FILE_MISSING,
                        "reading the file: " + e.getMessage(),
                        0,
                        e
                    );
                }
                out.write(buffer, 0, n);
                sent += n;
                if (written != null) written.bytes(sent);
            }
        } finally {
            try {
                in.close();
            } catch (IOException ignored) {
                // Read only.
            }
        }
    }

    /** A refusal (4xx) the server sent while the body was still going, or null. */
    private static Answer earlyAnswer(HttpURLConnection c) {
        try {
            int status = c.getResponseCode();
            if (status < 400 || status >= 500) return null;
            String body;
            try {
                body = readBody(c, status);
            } catch (IOException e) {
                body = "";
            }
            return new Answer(status, null, body);
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    /** The body; an answer cut off part-way is an I/O error, as a lost answer. */
    private static String readBody(HttpURLConnection c, int status) throws IOException {
        try (InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream()) {
            if (in == null) return "";
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                if (b.size() < MAX_BODY) b.write(buf, 0, n);
            }
            return new String(b.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    /** {@code url} with {@code extra} added to its query. */
    static String withQuery(String url, String extra) {
        int hash = url.indexOf('#');
        String base = hash >= 0 ? url.substring(0, hash) : url;
        return base + (base.contains("?") ? "&" : "?") + extra;
    }
}
