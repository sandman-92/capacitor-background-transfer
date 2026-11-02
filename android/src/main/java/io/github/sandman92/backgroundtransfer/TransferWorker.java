package io.github.sandman92.backgroundtransfer;

import android.content.Context;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.work.ForegroundInfo;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

/**
 * Below Android 14: a WorkManager worker promoted to a {@code dataSync}
 * foreground service, working through
 * one direction's queue. It survives the lock screen and removal from
 * Recents, but after a network drop with the app off-screen it can't promote
 * itself again ({@code ForegroundServiceStartNotAllowedException}), so
 * an interrupted transfer is reported as interrupted and the rest of the
 * queue waits for the app's next open. The six-hour daily {@code dataSync}
 * limit applies here only.
 */
public class TransferWorker extends Worker {

    static final String KEY_DIRECTION = "direction";
    private static final String TAG = "BackgroundTransfer";

    public TransferWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    private ForegroundInfo info(String direction, TransferRecord r) {
        Context c = getApplicationContext();
        int id = Notifications.idFor(direction);
        return Build.VERSION.SDK_INT >= 29
            ? new ForegroundInfo(id, Notifications.build(c, direction, r), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            : new ForegroundInfo(id, Notifications.build(c, direction, r));
    }

    @NonNull
    @Override
    public Result doWork() {
        String direction = getInputData().getString(KEY_DIRECTION);
        if (direction == null) return Result.failure();
        TransferStore store = Scheduler.store(getApplicationContext());
        if (!Runner.begin(direction)) return Result.success();
        TransferRecord first = store.nextQueued(direction);
        if (first == null) {
            Runner.end(direction);
            return Result.success();
        }
        try {
            setForegroundAsync(info(direction, first)).get();
        } catch (Exception e) {
            // Refused from the background. Carry on: with the network up it still finishes while the process lives.
            String problem = Scheduler.foregroundServiceProblem(getApplicationContext());
            Log.w(TAG, "could not run as a foreground service: " + (problem != null ? problem : e.toString()));
        }
        Runner.drain(
            store,
            direction,
            new Runner.Host() {
                private long last;

                @Override
                public void onProgress(TransferRecord r) {
                    long now = System.currentTimeMillis();
                    if (now - last < 1000 && !(r.total > 0 && r.bytes >= r.total)) return;
                    last = now;
                    setForegroundAsync(info(direction, r));
                }

                @Override
                public boolean waitsForNetwork() {
                    return false;
                }

                @Override
                public String systemStopReason() {
                    return isStopped() ? TransferException.Reason.STOPPED_BY_SYSTEM : null;
                }
            }
        );
        return Result.success();
    }
}
