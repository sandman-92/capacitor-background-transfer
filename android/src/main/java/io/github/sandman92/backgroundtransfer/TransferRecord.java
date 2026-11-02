package io.github.sandman92.backgroundtransfer;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** One transfer, as stored and as reported to JavaScript ({@code TransferRecord} in definitions.ts). */
public final class TransferRecord {

    public static final String UPLOAD = "upload";
    public static final String DOWNLOAD = "download";

    public static final String QUEUED = "queued";
    public static final String RUNNING = "running";
    public static final String INTERRUPTED = "interrupted";
    public static final String FINISHED = "finished";
    public static final String FAILED = "failed";
    public static final String CANCELLED = "cancelled";

    public String id;
    public String direction;
    public String state;
    public String url;
    public String path;
    /** Uploads: the protocol the session speaks ({@link UploadAdapters}). */
    public String protocol = UploadAdapters.DEFAULT;
    public long bytes;
    public long total = -1;
    public String reason;
    public String message;
    public int httpStatus;
    public long updatedAt;
    /** When it was queued, for first-in first-out. */
    public long queuedAt;
    /** Runs in a row that ended without moving a byte; caps the job's retries. */
    public int idleRuns;
    public Map<String, String> headers = new LinkedHashMap<>();
    /** {@code s3-multipart}: the presigned part URLs, part 1 first. */
    public List<String> partUrls = new ArrayList<>();
    /** {@code s3-multipart}: bytes per part, or 0 for the default. */
    public long partSize;
    /** {@code s3-multipart}: the presigned ListParts URL, or null. */
    public String listPartsUrl;
    /** {@code azure-blocks}: bytes per block, or 0 for the default. */
    public long blockSize;
    /** Parts or blocks the server holds, by number: the S3 {@code ETag} or the Azure block id. */
    public Map<Integer, String> parts = new TreeMap<>();
    /** The commit (S3 completion, Azure block list) has been sent: a lost answer isn't taken as success. */
    public boolean committing;
    public String channelId;
    public String channelName;
    public String title;
    public String text;

    public String key() {
        return keyOf(direction, id);
    }

    public static String keyOf(String direction, String id) {
        return direction + ":" + id;
    }

    /** Still to run or running: not to be forgotten or started twice. */
    public boolean isActive() {
        return QUEUED.equals(state) || RUNNING.equals(state);
    }

    /** Can be started again with the same id. */
    public boolean isRestartable() {
        return INTERRUPTED.equals(state) || FAILED.equals(state) || CANCELLED.equals(state);
    }

    public JSONObject toJson(boolean forJs) throws JSONException {
        JSONObject o = new JSONObject();
        o.put("id", id);
        o.put("direction", direction);
        o.put("state", state);
        o.put("url", url);
        o.put("path", path);
        if (UPLOAD.equals(direction)) o.put("protocol", protocol);
        o.put("bytes", bytes);
        o.put("total", total);
        if (reason != null) o.put("reason", reason);
        if (message != null) o.put("message", message);
        if (httpStatus != 0) o.put("httpStatus", httpStatus);
        o.put("updatedAt", updatedAt);
        if (!forJs) {
            o.put("queuedAt", queuedAt);
            o.put("idleRuns", idleRuns);
            o.put("headers", new JSONObject(headers));
            putOpt(o, "channelId", channelId);
            putOpt(o, "channelName", channelName);
            putOpt(o, "title", title);
            putOpt(o, "text", text);
            if (!partUrls.isEmpty()) o.put("partUrls", new JSONArray(partUrls));
            if (partSize > 0) o.put("partSize", partSize);
            putOpt(o, "listPartsUrl", listPartsUrl);
            if (blockSize > 0) o.put("blockSize", blockSize);
            if (!parts.isEmpty()) {
                JSONObject p = new JSONObject();
                for (Map.Entry<Integer, String> e : parts.entrySet()) p.put(String.valueOf(e.getKey()), e.getValue());
                o.put("parts", p);
            }
            if (committing) o.put("committing", true);
        }
        return o;
    }

    private static void putOpt(JSONObject o, String k, String v) throws JSONException {
        if (v != null) o.put(k, v);
    }

    public static TransferRecord fromJson(JSONObject o) throws JSONException {
        TransferRecord r = new TransferRecord();
        r.id = o.getString("id");
        r.direction = o.getString("direction");
        r.state = o.getString("state");
        r.url = o.getString("url");
        r.path = o.getString("path");
        r.protocol = o.optString("protocol", UploadAdapters.DEFAULT);
        r.bytes = o.optLong("bytes", 0);
        r.total = o.optLong("total", -1);
        r.reason = o.has("reason") ? o.getString("reason") : null;
        r.message = o.has("message") ? o.getString("message") : null;
        r.httpStatus = o.optInt("httpStatus", 0);
        r.updatedAt = o.optLong("updatedAt", 0);
        r.queuedAt = o.optLong("queuedAt", 0);
        r.idleRuns = o.optInt("idleRuns", 0);
        JSONObject h = o.optJSONObject("headers");
        if (h != null) {
            java.util.Iterator<String> names = h.keys();
            while (names.hasNext()) {
                String name = names.next();
                r.headers.put(name, h.getString(name));
            }
        }
        r.channelId = o.has("channelId") ? o.getString("channelId") : null;
        r.channelName = o.has("channelName") ? o.getString("channelName") : null;
        r.title = o.has("title") ? o.getString("title") : null;
        r.text = o.has("text") ? o.getString("text") : null;
        JSONArray urls = o.optJSONArray("partUrls");
        if (urls != null) for (int i = 0; i < urls.length(); i++) r.partUrls.add(urls.getString(i));
        r.partSize = o.optLong("partSize", 0);
        r.listPartsUrl = o.has("listPartsUrl") ? o.getString("listPartsUrl") : null;
        r.blockSize = o.optLong("blockSize", 0);
        JSONObject p = o.optJSONObject("parts");
        if (p != null) {
            Iterator<String> numbers = p.keys();
            while (numbers.hasNext()) {
                String n = numbers.next();
                r.parts.put(Integer.parseInt(n), p.getString(n));
            }
        }
        r.committing = o.optBoolean("committing", false);
        return r;
    }
}
