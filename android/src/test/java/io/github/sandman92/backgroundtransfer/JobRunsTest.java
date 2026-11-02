package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class JobRunsTest {

    @Test
    public void aStopReachesTheRunByJobIdWhateverParametersItCameWith() {
        JobRuns runs = new JobRuns();
        JobRuns.Run run = runs.start(7);
        assertTrue(runs.stop(7, true));
        assertEquals(TransferException.Reason.STOPPED_BY_SYSTEM, run.stopReason);
        assertTrue(run.byUser);
    }

    @Test
    public void aStopForAnotherJobLeavesTheRunAlone() {
        JobRuns runs = new JobRuns();
        JobRuns.Run run = runs.start(7);
        assertFalse(runs.stop(8, false));
        assertNull(run.stopReason);
    }

    @Test
    public void anOldRunEndingDoesNotForgetTheNewOne() {
        JobRuns runs = new JobRuns();
        JobRuns.Run old = runs.start(7);
        JobRuns.Run next = runs.start(7); // the system restarted the job while the old thread was ending
        runs.end(7, old);
        assertTrue(runs.stop(7, false));
        assertEquals(TransferException.Reason.STOPPED_BY_SYSTEM, next.stopReason);
        assertNull("the old run is not told", old.stopReason);
        runs.end(7, next);
        assertFalse(runs.stop(7, false));
    }
}
