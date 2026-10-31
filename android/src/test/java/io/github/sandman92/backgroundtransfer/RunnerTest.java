package io.github.sandman92.backgroundtransfer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class RunnerTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private FakeStorage server;
    private TransferStore store;
    private final List<String> events = new ArrayList<>();

    static final class Host implements Runner.Host {

        final boolean waits;
        volatile String stop;

        Host(boolean waits) {
            this.waits = waits;
        }

        @Override
        public void onProgress(TransferRecord r) {}

        @Override
        public boolean waitsForNetwork() {
            return waits;
        }

        @Override
        public String systemStopReason() {
            return stop;
        }
    }

    @Before
    public void up() throws Exception {
        server = new FakeStorage();
        server.object = Bytes.pattern(50_000);
        Runner.retries = 1;
        Runner.backoffMillis = 1;
        store = new TransferStore(new File(tmp.getRoot(), "store/transfers.json"));
        Runner.setEvents((name, r) -> {
            synchronized (events) {
                events.add(name + " " + r.id + " " + r.state);
            }
        });
    }

    @After
    public void down() {
        Runner.setEvents(null);
        Runner.end(TransferRecord.UPLOAD);
        Runner.end(TransferRecord.DOWNLOAD);
        server.close();
    }

    private TransferRecord download(String id, String url) {
        TransferRecord r = new TransferRecord();
        r.id = id;
        r.direction = TransferRecord.DOWNLOAD;
        r.url = url;
        r.path = new File(tmp.getRoot(), id + ".mp4").getPath();
        return r;
    }

    private TransferRecord upload(String id, byte[] data) throws Exception {
        TransferRecord r = new TransferRecord();
        r.id = id;
        r.direction = TransferRecord.UPLOAD;
        r.url = server.url("/upload");
        r.path = Bytes.write(tmp.getRoot(), id + ".bin", data).getPath();
        return r;
    }

    private Runner.Outcome drain(String direction, Host host) {
        assertTrue(Runner.begin(direction));
        return Runner.drain(store, direction, host);
    }

    @Test
    public void runsTheQueueInOrderAndReportsEachState() {
        Runner.enqueue(store, download("a", server.url("/object")));
        Runner.enqueue(store, download("b", server.url("/object")));
        assertEquals(Runner.Outcome.DONE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "a").state);
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "b").state);
        List<String> states = new ArrayList<>();
        for (String e : events) if (e.startsWith("stateChange")) states.add(e);
        assertEquals(
            Arrays.asList(
                "stateChange a queued",
                "stateChange b queued",
                "stateChange a running",
                "stateChange a finished",
                "stateChange b running",
                "stateChange b finished"
            ),
            states
        );
        assertFalse(Runner.isActive(TransferRecord.DOWNLOAD));
    }

    @Test
    public void startingAnActiveTransferAgainChangesNothing() {
        Runner.Enqueued first = Runner.enqueue(store, download("a", server.url("/object")));
        Runner.Enqueued again = Runner.enqueue(store, download("a", "http://elsewhere/x"));
        assertEquals(first.record.queuedAt, again.record.queuedAt);
        assertEquals(server.url("/object"), store.get(TransferRecord.DOWNLOAD, "a").url);
        assertTrue(again.needsHost);
    }

    @Test
    public void theJobPutsANetworkFailureBackInTheQueueToBeRescheduled() {
        String url = server.url("/object");
        server.close();
        Runner.enqueue(store, download("a", url));
        assertEquals(Runner.Outcome.RESCHEDULE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        TransferRecord a = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(TransferRecord.QUEUED, a.state);
        assertEquals(TransferException.Reason.NETWORK, a.reason);
        assertEquals(1, a.idleRuns);
    }

    @Test
    public void theJobGivesUpAfterManyRunsWithoutProgress() {
        String url = server.url("/object");
        server.close();
        Runner.enqueue(store, download("a", url));
        for (int i = 0; i < Runner.MAX_IDLE_RUNS - 1; i++) drain(TransferRecord.DOWNLOAD, new Host(true));
        assertEquals(Runner.Outcome.DONE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        assertEquals(TransferRecord.INTERRUPTED, store.get(TransferRecord.DOWNLOAD, "a").state);
    }

    @Test
    public void theWorkerReportsInterruptedAndLeavesTheRestQueued() throws Exception {
        String url = server.url("/object");
        server.close();
        Runner.enqueue(store, download("a", url));
        Runner.enqueue(store, download("b", url));
        assertEquals(Runner.Outcome.INTERRUPTED, drain(TransferRecord.DOWNLOAD, new Host(false)));
        TransferRecord a = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(TransferRecord.INTERRUPTED, a.state);
        assertEquals(TransferException.Reason.NETWORK, a.reason);
        assertEquals(TransferRecord.QUEUED, store.get(TransferRecord.DOWNLOAD, "b").state);
    }

    @Test
    public void anInterruptedDownloadKeepsItsPartAndResumesWhenStartedAgain() throws Exception {
        TransferRecord a = download("a", server.url("/object"));
        File part = Downloader.partFile(new File(a.path));
        Files.write(part.toPath(), Arrays.copyOf(server.object, 20_000));
        Runner.Enqueued q = Runner.enqueue(store, a);
        assertEquals("bytes start from the part file", 20_000, q.record.bytes);
        drain(TransferRecord.DOWNLOAD, new Host(false));
        assertTrue(server.log.get(0).contains("range=bytes=20000-"));
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "a").state);
    }

    @Test
    public void aFailureRemovesThePartAndMovesOn() throws Exception {
        TransferRecord a = download("a", server.url("/object"));
        File part = Downloader.partFile(new File(a.path));
        Files.write(part.toPath(), new byte[10]);
        Runner.enqueue(store, a);
        Runner.enqueue(store, download("b", server.url("/object")));
        server.failStatus = 403;
        server.failCount.set(1);
        assertEquals(Runner.Outcome.DONE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        TransferRecord failed = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(TransferRecord.FAILED, failed.state);
        assertEquals(TransferException.Reason.SESSION_REFUSED, failed.reason);
        assertEquals(403, failed.httpStatus);
        assertFalse(part.exists());
        assertFalse(new File(a.path).exists());
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "b").state);
    }

    @Test
    public void cancellingAQueuedDownloadRemovesItsPart() throws Exception {
        TransferRecord a = download("a", server.url("/object"));
        File part = Downloader.partFile(new File(a.path));
        Files.write(part.toPath(), new byte[10]);
        Runner.enqueue(store, a);
        Runner.cancel(store, TransferRecord.DOWNLOAD, "a");
        TransferRecord r = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(TransferRecord.CANCELLED, r.state);
        assertEquals(TransferException.Reason.CANCELLED, r.reason);
        assertFalse(part.exists());
        assertEquals(Runner.Outcome.DONE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        assertTrue("nothing was fetched", server.log.isEmpty());
    }

    @Test
    public void cancellingARunningUploadStopsIt() throws Exception {
        Runner.enqueue(store, upload("u", Bytes.pattern((64 * 1024 * 1024) / 16)));
        Thread canceller = new Thread(() -> {
            while (!TransferRecord.RUNNING.equals(store.get(TransferRecord.UPLOAD, "u").state)) Thread.yield();
            Runner.cancel(store, TransferRecord.UPLOAD, "u");
        });
        canceller.start();
        drain(TransferRecord.UPLOAD, new Host(true));
        canceller.join();
        TransferRecord r = store.get(TransferRecord.UPLOAD, "u");
        // Either it was stopped part-way, or it was quick enough to finish first.
        assertTrue(r.state, TransferRecord.CANCELLED.equals(r.state) || TransferRecord.FINISHED.equals(r.state));
        if (TransferRecord.CANCELLED.equals(r.state)) assertFalse(server.finalized);
    }

    @Test
    public void aSystemStopPutsTheJobsTransferBackInTheQueue() throws Exception {
        Host host = new Host(true);
        host.stop = TransferException.Reason.STOPPED_BY_SYSTEM;
        Runner.enqueue(store, upload("u", Bytes.pattern(1000)));
        assertEquals(Runner.Outcome.RESCHEDULE, drain(TransferRecord.UPLOAD, host));
        assertEquals(TransferRecord.QUEUED, store.get(TransferRecord.UPLOAD, "u").state);
    }

    @Test
    public void reconcileReportsARunningTransferWithNoHostAsInterrupted() {
        TransferRecord a = download("a", server.url("/object"));
        Runner.enqueue(store, a);
        TransferRecord r = store.get(TransferRecord.DOWNLOAD, "a");
        r.state = TransferRecord.RUNNING; // the process died mid-transfer
        store.put(r);
        Runner.enqueue(store, download("b", server.url("/object")));
        assertTrue("b is still queued and needs a host", Runner.reconcile(store, TransferRecord.DOWNLOAD, false));
        TransferRecord after = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(TransferRecord.INTERRUPTED, after.state);
        assertEquals(TransferException.Reason.STOPPED_BY_SYSTEM, after.reason);
    }

    @Test
    public void reconcileQueuesARunningTransferAgainWhenItsHostIsStillScheduled() {
        Runner.enqueue(store, download("a", server.url("/object")));
        TransferRecord r = store.get(TransferRecord.DOWNLOAD, "a");
        r.state = TransferRecord.RUNNING;
        store.put(r);
        assertTrue("queued work is scheduled afresh while the app is visible", Runner.reconcile(store, TransferRecord.DOWNLOAD, true));
        assertEquals(TransferRecord.QUEUED, store.get(TransferRecord.DOWNLOAD, "a").state);
    }

    @Test
    public void theNextHostCarriesOnATransferLeftRunningByADeadProcess() throws Exception {
        TransferRecord a = download("a", server.url("/object"));
        Runner.enqueue(store, a);
        TransferRecord r = store.get(TransferRecord.DOWNLOAD, "a");
        r.state = TransferRecord.RUNNING; // the process was killed mid-transfer; the system restarts the job
        store.put(r);
        File part = Downloader.partFile(new File(a.path));
        Files.write(part.toPath(), Arrays.copyOf(server.object, 10_000));
        assertEquals(Runner.Outcome.DONE, drain(TransferRecord.DOWNLOAD, new Host(true)));
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "a").state);
        assertTrue(server.log.get(0).contains("range=bytes=10000-"));
    }

    @Test
    public void aCancelLandingAsARunEndsDoesNotStopTheNextRunOfTheSameId() throws Exception {
        Runner.enqueue(store, download("a", server.url("/object")));
        Runner.enqueue(store, download("b", server.url("/object")));
        // Cancel a in the instant it finishes, while it is still the running transfer, and again after.
        Runner.setEvents((name, r) -> {
            if (name.equals("stateChange") && r.id.equals("a") && TransferRecord.FINISHED.equals(r.state)) {
                Runner.cancel(store, TransferRecord.DOWNLOAD, "a");
            }
            if (name.equals("stateChange") && r.id.equals("b") && TransferRecord.RUNNING.equals(r.state)) {
                Runner.cancel(store, TransferRecord.DOWNLOAD, "a");
            }
        });
        drain(TransferRecord.DOWNLOAD, new Host(true));
        assertEquals(TransferRecord.FINISHED, store.get(TransferRecord.DOWNLOAD, "a").state);
        // Started again: nothing left over from those cancels stops it.
        Runner.enqueue(store, download("a", server.url("/object")));
        drain(TransferRecord.DOWNLOAD, new Host(true));
        TransferRecord again = store.get(TransferRecord.DOWNLOAD, "a");
        assertEquals(again.reason, TransferRecord.FINISHED, again.state);
    }

    @Test
    public void reconcileLeavesTheQueueAloneWhileAHostIsRunningIt() {
        Runner.enqueue(store, download("a", server.url("/object")));
        assertTrue(Runner.begin(TransferRecord.DOWNLOAD));
        assertFalse(Runner.reconcile(store, TransferRecord.DOWNLOAD, true));
        Runner.end(TransferRecord.DOWNLOAD);
        assertFalse(
            "nothing queued, nothing to schedule",
            Runner.reconcile(new TransferStore(new File(tmp.getRoot(), "empty/t.json")), TransferRecord.DOWNLOAD, false)
        );
    }

    @Test
    public void theStoreSurvivesAReload() {
        TransferRecord a = download("a", server.url("/object"));
        a.headers.put("X-A", "1");
        a.title = "T";
        Runner.enqueue(store, a);
        TransferStore again = new TransferStore(new File(tmp.getRoot(), "store/transfers.json"));
        TransferRecord r = again.get(TransferRecord.DOWNLOAD, "a");
        assertEquals("1", r.headers.get("X-A"));
        assertEquals("T", r.title);
        assertEquals(TransferRecord.QUEUED, r.state);
        assertNull(again.get(TransferRecord.UPLOAD, "a"));
    }
}
