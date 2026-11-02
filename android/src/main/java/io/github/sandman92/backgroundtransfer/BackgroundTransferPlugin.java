package io.github.sandman92.backgroundtransfer;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The JavaScript side's handle on background transfers: queue an upload or a
 * download, cancel one, list what ran while the app was away, and hear
 * progress and state changes while it is open. The work itself is done by
 * {@link TransferJobService} (Android 14+) or {@link TransferWorker} (below),
 * through {@link Runner}.
 */
@CapacitorPlugin(name = "BackgroundTransfer")
public class BackgroundTransferPlugin extends Plugin implements Runner.Events {

    private TransferStore store;

    @Override
    public void load() {
        store = Scheduler.store(getContext());
        Runner.setEvents(this);
        // The app has just opened, so it is visible and a host may be scheduled.
        getBridge().execute(() -> {
            for (String direction : new String[] { TransferRecord.UPLOAD, TransferRecord.DOWNLOAD }) {
                try {
                    if (Runner.reconcile(store, direction, Scheduler.hostScheduled(getContext(), direction))) {
                        Scheduler.schedule(getContext(), direction);
                    }
                } catch (RuntimeException e) {
                    android.util.Log.w("BackgroundTransfer", "could not resume the " + direction + " queue: " + e);
                }
            }
        });
    }

    @Override
    protected void handleOnDestroy() {
        if (Runner.events() == this) Runner.setEvents(null);
    }

    @Override
    public void onEvent(String name, TransferRecord r) {
        try {
            notifyListeners(name, event(r));
        } catch (JSONException ignored) {
            // A record always serialises; nothing to tell.
        }
    }

    private static JSObject event(TransferRecord r) throws JSONException {
        JSObject o = new JSObject();
        o.put("transfer", r.toJson(true));
        return o;
    }

    @PluginMethod
    public void isAvailable(PluginCall call) {
        JSObject o = new JSObject();
        o.put("available", true);
        o.put("mechanism", Scheduler.usesJob() ? "job" : "worker");
        String problem = Scheduler.foregroundServiceProblem(getContext());
        if (problem != null) o.put("warning", problem);
        call.resolve(o);
    }

    @PluginMethod
    public void upload(PluginCall call) {
        start(call, TransferRecord.UPLOAD);
    }

    @PluginMethod
    public void download(PluginCall call) {
        start(call, TransferRecord.DOWNLOAD);
    }

    private void start(PluginCall call, String direction) {
        String id = call.getString("id");
        String url = call.getString("url");
        String path = call.getString("path");
        if (id == null || id.isEmpty() || url == null || path == null || !path.startsWith("/")) {
            call.reject("id, url and an absolute path are required");
            return;
        }
        TransferRecord r = new TransferRecord();
        if (TransferRecord.UPLOAD.equals(direction)) {
            String protocol = UploadAdapters.resolve(call.getString("protocol"));
            if (protocol == null) {
                call.reject(UploadAdapters.refusal());
                return;
            }
            r.protocol = protocol;
        }
        r.id = id;
        r.direction = direction;
        r.url = url;
        r.path = path;
        JSObject headers = call.getObject("headers");
        if (headers != null) {
            Iterator<String> names = headers.keys();
            while (names.hasNext()) {
                String name = names.next();
                String value = headers.getString(name);
                if (value != null) r.headers.put(name, value);
            }
        }
        JSObject n = call.getObject("notification");
        if (n != null) {
            r.channelId = n.getString("channelId");
            r.channelName = n.getString("channelName");
            r.title = n.getString("title");
            r.text = n.getString("text");
        }
        getBridge().execute(() -> {
            try {
                Runner.Enqueued queued = Runner.enqueue(store, r);
                // No run in this process: schedule afresh, replacing any job the system is holding back
                // (after a quota or other system stop it can wait minutes). The app is visible now.
                if (queued.needsHost) Scheduler.schedule(getContext(), direction);
                call.resolve(event(queued.record));
            } catch (Exception e) {
                call.reject("could not start the " + direction + ": " + e.getMessage(), e);
            }
        });
    }

    @PluginMethod
    public void cancel(PluginCall call) {
        String id = call.getString("id");
        String direction = call.getString("direction");
        if (id == null || !(TransferRecord.UPLOAD.equals(direction) || TransferRecord.DOWNLOAD.equals(direction))) {
            call.reject("id and direction are required");
            return;
        }
        getBridge().execute(() -> {
            Runner.cancel(store, direction, id);
            call.resolve();
        });
    }

    @PluginMethod
    public void list(PluginCall call) {
        getBridge().execute(() -> {
            try {
                JSArray list = new JSArray();
                for (TransferRecord r : store.all()) list.put(r.toJson(true));
                JSObject o = new JSObject();
                o.put("transfers", list);
                call.resolve(o);
            } catch (JSONException e) {
                call.reject("could not list transfers", e);
            }
        });
    }

    @PluginMethod
    public void forget(PluginCall call) {
        JSArray ids = call.getArray("ids");
        getBridge().execute(() -> {
            Set<String> only = null;
            if (ids != null) {
                only = new HashSet<>();
                JSONArray list = ids;
                for (int i = 0; i < list.length(); i++) {
                    JSONObject o = list.optJSONObject(i);
                    if (o != null) only.add(TransferRecord.keyOf(o.optString("direction"), o.optString("id")));
                }
            }
            for (TransferRecord r : store.all()) {
                if (r.isActive() || TransferRecord.INTERRUPTED.equals(r.state)) continue;
                if (only != null && !only.contains(r.key())) continue;
                store.remove(r.direction, r.id);
            }
            call.resolve();
        });
    }
}
