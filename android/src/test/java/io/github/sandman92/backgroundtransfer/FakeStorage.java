package io.github.sandman92.backgroundtransfer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.mockwebserver.Dispatcher;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import okhttp3.mockwebserver.SocketPolicy;
import okio.Buffer;

/**
 * A local stand-in for a resumable upload server: one resumable upload session at
 * {@code /upload} speaking the {@code X-Goog-Upload-*} protocol, and one
 * object at {@code /object} that honours {@code Range}. Small files only.
 */
final class FakeStorage implements AutoCloseable {

    final MockWebServer server = new MockWebServer();
    final ByteArrayOutputStream received = new ByteArrayOutputStream();
    volatile boolean finalized;
    volatile byte[] object = new byte[0];
    /** Every request: method, command, offset or range, and whether it carried Authorization. */
    final List<String> log = Collections.synchronizedList(new ArrayList<>());
    /** Answer the next N requests with this status. */
    volatile int failStatus;
    final AtomicInteger failCount = new AtomicInteger();
    /** Drop the connection on the next N upload chunks (keeping half) or downloads (half-way through the body). */
    final AtomicInteger dropCount = new AtomicInteger();
    /** Ignore Range and send the whole object with 200. */
    volatile boolean ignoreRange;
    /** Accept only this many bytes of each non-final upload chunk (as a server that kept part of it). */
    volatile int keepPerChunk = Integer.MAX_VALUE;

    static {
        // The JVM's HttpURLConnection resends a POST once when the connection drops; Android's doesn't. Match Android.
        System.setProperty("sun.net.http.retryPost", "false");
    }

    FakeStorage() throws IOException {
        server.setDispatcher(
            new Dispatcher() {
                @Override
                public MockResponse dispatch(RecordedRequest r) {
                    String path = String.valueOf(r.getPath());
                    if (path.startsWith("/upload")) return upload(r);
                    if (path.startsWith("/object")) return download(r);
                    return new MockResponse().setResponseCode(404);
                }
            }
        );
        server.start();
    }

    String url(String path) {
        return server.url(path).toString();
    }

    @Override
    public void close() {
        try {
            server.shutdown();
        } catch (IOException ignored) {
            // Already gone.
        }
    }

    private boolean takes(AtomicInteger counter) {
        return counter.get() > 0 && counter.getAndDecrement() > 0;
    }

    private synchronized MockResponse upload(RecordedRequest r) {
        String command = String.valueOf(r.getHeader("X-Goog-Upload-Command"));
        String offset = r.getHeader("X-Goog-Upload-Offset");
        log.add(r.getMethod() + " " + command + " " + offset + " auth=" + (r.getHeader("Authorization") != null));
        byte[] data = r.getBody().readByteArray();
        if (takes(failCount)) return new MockResponse().setResponseCode(failStatus);
        if (!command.equals("query")) {
            if (takes(dropCount)) {
                received.write(data, 0, data.length / 2);
                return new MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST);
            }
            if (finalized || offset == null || Long.parseLong(offset) != received.size()) {
                return new MockResponse().setResponseCode(400);
            }
            boolean fin = command.contains("finalize");
            received.write(data, 0, fin ? data.length : Math.min(data.length, keepPerChunk));
            if (fin) finalized = true;
        }
        return new MockResponse()
            .setResponseCode(200)
            .addHeader("X-Goog-Upload-Size-Received", String.valueOf(received.size()))
            .addHeader("X-Goog-Upload-Status", finalized ? "final" : "active");
    }

    private MockResponse download(RecordedRequest r) {
        String range = r.getHeader("Range");
        log.add(r.getMethod() + " range=" + range + " auth=" + (r.getHeader("Authorization") != null));
        if (takes(failCount)) return new MockResponse().setResponseCode(failStatus);
        byte[] obj = object;
        int start = 0;
        MockResponse response = new MockResponse();
        if (range != null && !ignoreRange) {
            start = Integer.parseInt(range.replace("bytes=", "").replace("-", ""));
            if (start >= obj.length) {
                return response.setResponseCode(416).addHeader("Content-Range", "bytes */" + obj.length);
            }
            response.setResponseCode(206).addHeader("Content-Range", "bytes " + start + "-" + (obj.length - 1) + "/" + obj.length);
        } else {
            response.setResponseCode(200);
        }
        response.setBody(new Buffer().write(obj, start, obj.length - start));
        if (takes(dropCount)) response.setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY);
        return response;
    }
}
