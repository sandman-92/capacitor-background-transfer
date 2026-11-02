package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Every transfer's record, kept in one small JSON file so the state survives
 * the app's process (the job or worker may run, finish or fail with the app
 * closed). Records handed out are copies; change one with {@link #put}.
 */
public final class TransferStore {

    private static final Map<String, TransferStore> stores = new LinkedHashMap<>();

    private final File file;
    private final Map<String, TransferRecord> records = new LinkedHashMap<>();

    /** The store kept in {@code dir} (one per directory per process). */
    public static synchronized TransferStore in(File dir) {
        String key = dir.getAbsolutePath();
        TransferStore s = stores.get(key);
        if (s == null) {
            s = new TransferStore(new File(dir, "transfers.json"));
            stores.put(key, s);
        }
        return s;
    }

    TransferStore(File file) {
        this.file = file;
        load();
    }

    private void load() {
        if (!file.isFile()) return;
        try {
            JSONArray list = new JSONArray(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
            for (int i = 0; i < list.length(); i++) {
                TransferRecord r = TransferRecord.fromJson(list.getJSONObject(i));
                records.put(r.key(), r);
            }
        } catch (IOException | JSONException e) {
            // A damaged file loses the history, never the transfers' files.
            records.clear();
        }
    }

    private void save() {
        File dir = file.getParentFile();
        if (dir != null && !dir.isDirectory()) dir.mkdirs();
        File tmp = new File(file.getPath() + ".tmp");
        try {
            JSONArray list = new JSONArray();
            for (TransferRecord r : records.values()) list.put(r.toJson(false));
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(list.toString().getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            if (!tmp.renameTo(file)) throw new IOException("rename failed");
        } catch (IOException | JSONException e) {
            tmp.delete();
        }
    }

    private static TransferRecord copy(TransferRecord r) {
        if (r == null) return null;
        try {
            return TransferRecord.fromJson(r.toJson(false));
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    public synchronized TransferRecord get(String direction, String id) {
        return copy(records.get(TransferRecord.keyOf(direction, id)));
    }

    public synchronized List<TransferRecord> all() {
        List<TransferRecord> out = new ArrayList<>();
        for (TransferRecord r : records.values()) out.add(copy(r));
        return out;
    }

    /** Stores {@code r} (stamping {@code updatedAt}) and returns a copy of what was stored. */
    public synchronized TransferRecord put(TransferRecord r) {
        r.updatedAt = System.currentTimeMillis();
        records.put(r.key(), copy(r));
        save();
        return copy(r);
    }

    public synchronized void remove(String direction, String id) {
        if (records.remove(TransferRecord.keyOf(direction, id)) != null) save();
    }

    /** The oldest queued transfer in {@code direction}, or null. */
    public synchronized TransferRecord nextQueued(String direction) {
        TransferRecord next = null;
        for (TransferRecord r : records.values()) {
            if (!direction.equals(r.direction) || !TransferRecord.QUEUED.equals(r.state)) continue;
            if (next == null || r.queuedAt < next.queuedAt) next = r;
        }
        return copy(next);
    }
}
