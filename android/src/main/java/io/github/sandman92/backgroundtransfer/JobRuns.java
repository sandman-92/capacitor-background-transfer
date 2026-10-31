package io.github.sandman92.backgroundtransfer;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Each job's current run, by job id. The system hands onStopJob a JobParameters instance of its
 * own, not the one onStartJob got (and they don't compare equal), so the id is the only key both
 * share. A run that ends removes only itself, never a newer run of the same job.
 */
final class JobRuns {

    /** What the system told one run. */
    static final class Run {

        volatile String stopReason;
        volatile boolean byUser;
    }

    private final Map<Integer, Run> runs = new ConcurrentHashMap<>();

    Run start(int jobId) {
        Run run = new Run();
        runs.put(jobId, run);
        return run;
    }

    /** Tells the job's current run to stop; returns false if no run of it is known. */
    boolean stop(int jobId, boolean byUser) {
        Run run = runs.get(jobId);
        if (run == null) return false;
        run.byUser = byUser;
        run.stopReason = TransferException.Reason.STOPPED_BY_SYSTEM;
        return true;
    }

    void end(int jobId, Run run) {
        runs.remove(jobId, run);
    }
}
