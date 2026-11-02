package io.github.sandman92.backgroundtransfer;

import android.app.job.JobParameters;
import android.app.job.JobService;
import android.os.Build;
import androidx.annotation.RequiresApi;

/**
 * Android 14+: a user-initiated data transfer job, one per direction, that
 * works through that direction's queue. It keeps running with the device
 * locked, in Doze and after the app is removed from Recents, and when the
 * network goes the system stops it and starts it again once the network is
 * back. Only force-stop, or the user stopping it from the
 * Task Manager, ends it for good; the next open reports those transfers as
 * interrupted.
 */
@RequiresApi(34)
public class TransferJobService extends JobService {

    private final JobRuns runs = new JobRuns();

    /** How long a new run waits for the previous run's thread (stopped by the system, still closing its connection). */
    private static final long WAIT_FOR_PREVIOUS_MS = 60_000;

    @Override
    public boolean onStartJob(JobParameters params) {
        int jobId = params.getJobId();
        String direction = Scheduler.directionOfJob(jobId);
        if (direction == null) return false;
        JobRuns.Run run = runs.start(jobId);
        TransferStore store = Scheduler.store(this);
        // A user-initiated job must post its notification as soon as it starts.
        setNotification(
            params,
            Notifications.idFor(direction),
            Notifications.build(this, direction, store.nextQueued(direction)),
            JOB_END_NOTIFICATION_POLICY_REMOVE
        );
        new Thread(() -> {
            // The previous run may still be in its last request after onStopJob: let it end first.
            long until = System.currentTimeMillis() + WAIT_FOR_PREVIOUS_MS;
            while (!Runner.begin(direction)) {
                if (run.stopReason != null) {
                    runs.end(jobId, run);
                    return;
                }
                if (System.currentTimeMillis() > until) {
                    runs.end(jobId, run);
                    jobFinished(params, true);
                    return;
                }
                try {
                    Thread.sleep(250);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
            Runner.Outcome outcome = Runner.drain(
                store,
                direction,
                new Runner.Host() {
                    @Override
                    public void onProgress(TransferRecord r) {
                        if (run.stopReason != null) return;
                        setNotification(
                            params,
                            Notifications.idFor(direction),
                            Notifications.build(TransferJobService.this, direction, r),
                            JOB_END_NOTIFICATION_POLICY_REMOVE
                        );
                        if (TransferRecord.UPLOAD.equals(direction)) updateTransferredNetworkBytes(params, 0, r.bytes);
                        else updateTransferredNetworkBytes(params, r.bytes, 0);
                    }

                    @Override
                    public boolean waitsForNetwork() {
                        return !run.byUser;
                    }

                    @Override
                    public String systemStopReason() {
                        return run.stopReason;
                    }
                }
            );
            runs.end(jobId, run);
            // After onStopJob the system has already decided; jobFinished must not be called.
            if (run.stopReason == null) jobFinished(params, outcome == Runner.Outcome.RESCHEDULE);
        }, "BackgroundTransferJob-" + direction).start();
        return true;
    }

    @Override
    public void onNetworkChanged(JobParameters params) {
        // Each request opens its own connection on the default network; nothing to move.
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        boolean byUser = Build.VERSION.SDK_INT >= 34 && params.getStopReason() == JobParameters.STOP_REASON_USER;
        boolean known = runs.stop(params.getJobId(), byUser);
        android.util.Log.i(
            "BackgroundTransfer",
            "job " +
                params.getJobId() +
                " stopped by the system, reason " +
                (Build.VERSION.SDK_INT >= 31 ? params.getStopReason() : -1) +
                (byUser ? " (the user)" : "") +
                (known ? "" : ", no run known")
        );
        // Network lost, quota, the device state: the system runs it again later. Stopped by the user: it doesn't.
        return !byUser;
    }
}
