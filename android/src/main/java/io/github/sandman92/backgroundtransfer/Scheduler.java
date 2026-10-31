package io.github.sandman92.backgroundtransfer;

import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.content.ComponentName;
import android.content.Context;
import android.os.Build;
import androidx.work.Data;
import androidx.work.ExistingWorkPolicy;
import androidx.work.OneTimeWorkRequest;
import androidx.work.OutOfQuotaPolicy;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import java.io.File;
import java.util.List;

/** Starts the host for a direction: the user-initiated job on Android 14+, the worker below. */
final class Scheduler {

    static final int UPLOAD_JOB = 0x0B7A0001;
    static final int DOWNLOAD_JOB = 0x0B7A0002;

    private Scheduler() {}

    static boolean usesJob() {
        return Build.VERSION.SDK_INT >= 34;
    }

    /**
     * Below Android 14 the worker runs as WorkManager's foreground service with the {@code dataSync}
     * type, which the app's manifest must declare (the plugin doesn't, so it can't clash with an
     * app that declares other types too). Returns what is wrong, or null.
     */
    static String foregroundServiceProblem(Context context) {
        if (usesJob() || Build.VERSION.SDK_INT < 29) return null;
        try {
            android.content.pm.ServiceInfo info = context
                .getPackageManager()
                .getServiceInfo(new ComponentName(context, "androidx.work.impl.foreground.SystemForegroundService"), 0);
            if ((info.getForegroundServiceType() & android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) == 0) {
                return (
                    "androidx.work.impl.foreground.SystemForegroundService is not declared with foregroundServiceType dataSync: " +
                    "transfers stop when the app leaves the screen"
                );
            }
            return null;
        } catch (android.content.pm.PackageManager.NameNotFoundException e) {
            return "androidx.work.impl.foreground.SystemForegroundService is not in the manifest";
        }
    }

    static TransferStore store(Context context) {
        return TransferStore.in(new File(context.getApplicationContext().getFilesDir(), "background-transfer"));
    }

    static int jobIdFor(String direction) {
        return TransferRecord.UPLOAD.equals(direction) ? UPLOAD_JOB : DOWNLOAD_JOB;
    }

    static String directionOfJob(int jobId) {
        if (jobId == UPLOAD_JOB) return TransferRecord.UPLOAD;
        if (jobId == DOWNLOAD_JOB) return TransferRecord.DOWNLOAD;
        return null;
    }

    private static String workName(String direction) {
        return "background-transfer-" + direction;
    }

    /** Whether the system still holds a host for {@code direction} (a pending or running job, or unfinished work). */
    static boolean hostScheduled(Context context, String direction) {
        if (usesJob()) {
            JobScheduler js = context.getSystemService(JobScheduler.class);
            return js != null && js.getPendingJob(jobIdFor(direction)) != null;
        }
        try {
            List<WorkInfo> infos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(workName(direction)).get();
            for (WorkInfo info : infos) if (!info.getState().isFinished()) return true;
        } catch (Exception ignored) {
            // Unknown: say no, and the caller schedules one, which is harmless.
        }
        return false;
    }

    /**
     * Schedules the host. On Android 14+ this must happen while the app is
     * visible, which is when the plugin's methods and its load run. Throws
     * when the system refuses.
     */
    static void schedule(Context context, String direction) {
        if (usesJob()) {
            scheduleJob(context, direction);
            return;
        }
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(TransferWorker.class)
            .setInputData(new Data.Builder().putString(TransferWorker.KEY_DIRECTION, direction).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag("background-transfer")
            .build();
        // Appended: a worker already draining finishes, then this one finds the queue empty or carries on.
        WorkManager.getInstance(context).enqueueUniqueWork(workName(direction), ExistingWorkPolicy.APPEND_OR_REPLACE, request);
    }

    private static void scheduleJob(Context context, String direction) {
        if (Build.VERSION.SDK_INT < 34) return;
        long bytes = 0;
        for (TransferRecord r : store(context).all()) {
            if (!direction.equals(r.direction) || !TransferRecord.QUEUED.equals(r.state)) continue;
            if (TransferRecord.UPLOAD.equals(direction)) {
                long size = new File(r.path).length();
                bytes += Math.max(0, size - Math.max(0, r.bytes));
            } else if (r.total > 0) {
                bytes += Math.max(0, r.total - r.bytes);
            }
        }
        long estimate = bytes > 0 ? bytes : JobInfo.NETWORK_BYTES_UNKNOWN;
        boolean upload = TransferRecord.UPLOAD.equals(direction);
        JobInfo job = new JobInfo.Builder(jobIdFor(direction), new ComponentName(context, TransferJobService.class))
            .setUserInitiated(true)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setEstimatedNetworkBytes(upload ? JobInfo.NETWORK_BYTES_UNKNOWN : estimate, upload ? estimate : JobInfo.NETWORK_BYTES_UNKNOWN)
            .setPersisted(true)
            .build();
        JobScheduler js = context.getSystemService(JobScheduler.class);
        if (js == null || js.schedule(job) != JobScheduler.RESULT_SUCCESS) {
            throw new IllegalStateException("the system refused to schedule the transfer job");
        }
    }
}
