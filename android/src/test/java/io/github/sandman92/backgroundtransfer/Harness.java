package io.github.sandman92.backgroundtransfer;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * The test servers' control API (test-servers/harness.mjs): sets uploads up on MinIO and
 * Azurite, checks what they stored, and injects faults in front of them. Its address is
 * {@code BT_HARNESS} (e.g. {@code http://localhost:8790}); without it the tests that need the
 * servers are skipped.
 */
final class Harness {

    static final String BASE = System.getenv("BT_HARNESS");

    private Harness() {}

    static boolean configured() {
        return BASE != null && !BASE.isEmpty();
    }

    static JSONObject post(String path, JSONObject body) throws Exception {
        return call("POST", path, body.toString());
    }

    static JSONObject get(String path) throws Exception {
        return call("GET", path, null);
    }

    static JSONArray requests(String target) throws Exception {
        return get("/requests?target=" + target).getJSONArray("requests");
    }

    private static JSONObject call(String method, String path, String body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(BASE + path).openConnection();
        c.setRequestMethod(method);
        c.setConnectTimeout(10_000);
        c.setReadTimeout(60_000);
        if (body != null) {
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/json");
            try (OutputStream out = c.getOutputStream()) {
                out.write(body.getBytes(StandardCharsets.UTF_8));
            }
        }
        int status = c.getResponseCode();
        try (InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream()) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            if (in != null) in.transferTo(b);
            String text = b.toString(StandardCharsets.UTF_8);
            if (status >= 300) throw new IllegalStateException(method + " " + path + ": HTTP " + status + " " + text);
            return text.isEmpty() ? new JSONObject() : new JSONObject(text);
        } finally {
            c.disconnect();
        }
    }
}
