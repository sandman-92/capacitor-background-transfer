package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Works through one direction's queue, one transfer at a time, oldest first,
 * for whichever host is running it: the user-initiated job (Android 14+) or
 * the WorkManager worker (below 14). Keeps every record in the
 * {@link TransferStore} and tells the plugin (if the app is open) what
 * changed.
 *
 * Plain Java apart from what the {@link Host} does, so the queue rules run
 * under JUnit.
 */
public final class Runner {

    /** What a drain ended with. */
    public enum Outcome {
        /** The queue is empty. */
        DONE,
        /** The host should be rescheduled by the system (the job, after the network went or the system stopped it). */
        RESCHEDULE,
        /** A transfer was interrupted and the host can't wait for the network (the worker): the rest waits for the next open. */
        INTERRUPTED
    }

    /** The job or the worker. */
    public interface Host {
        /** Shows the transfer's progress (the notification, the job's byte counts). */
        void onProgress(TransferRecord r);

        /** Whether the system restarts this host when the network comes back (the job: yes). */
        boolean waitsForNetwork();

        /** Non-null once the system has told the host to stop. */
        String systemStopReason();
    }

    /** The plugin, while the app is open. */
    public interface Events {
        void onEvent(String name, TransferRecord r);
    }

    /** A job that has failed this many runs in a row without moving a byte is reported as interrupted. */
    static final int MAX_IDLE_RUNS = 8;

    /** Retries within one run before a network error ends it; lowered by the tests. */
    static int retries = 3;
    static long backoffMillis = 2000;

    private static final long PROGRESS_EVERY_MS = 250;
    private static final long SAVE_EVERY_MS = 2000;
    private static final long NOTIFY_EVERY_MS = 1000;

    private static final Map<String, Object> locks = new ConcurrentHashMap<>();
    private static final Map<String, Boolean> active = new ConcurrentHashMap<>();
    private static final Map<String, String> current = new ConcurrentHashMap<>();
    private static final Map<String, String> stopRequests = new ConcurrentHashMap<>();
    private static volatile Events events;
    private static long lastQueuedAt;

    private Runner() {}

    public static void setEvents(Events e) {
        events = e;
    }

    public static Events events() {
        return events;
    }

    static Object lock(String direction) {
        return locks.computeIfAbsent(direction, (d) -> new Object());
    }

    /** Whether a host in this process is working through {@code direction}'s queue. */
    public static boolean isActive(String direction) {
        return Boolean.TRUE.equals(active.get(direction));
    }

    /** Claims the queue for a host; false if another host in this process already has it. */
    public static boolean begin(String direction) {
        synchronized (lock(direction)) {
            if (isActive(direction)) return false;
            active.put(direction, true);
            return true;
        }
    }

    /** Lets go of the queue (a host that stopped early). */
    public static void end(String direction) {
        synchronized (lock(direction)) {
            active.put(direction, false);
        }
    }

    private static synchronized long nextQueuedAt() {
        lastQueuedAt = Math.max(System.currentTimeMillis(), lastQueuedAt + 1);
        return lastQueuedAt;
    }

    /** The result of {@link #enqueue}. */
    public static final class Enqueued {

        public final TransferRecord record;
        /** True when no host is working through the queue, so the caller must schedule one. */
        public final boolean needsHost;

        Enqueued(TransferRecord record, boolean needsHost) {
            this.record = record;
            this.needsHost = needsHost;
        }
    }

    /**
     * Queues {@code wanted}. A transfer with the same id that is already
     * queued or running is left alone and returned; one that is finished,
     * interrupted, failed or cancelled is replaced and starts again (from the
     * server's offset or the {@code .part} file).
     */
    public static Enqueued enqueue(TransferStore store, TransferRecord wanted) {
        synchronized (lock(wanted.direction)) {
            TransferRecord existing = store.get(wanted.direction, wanted.id);
            if (existing != null && existing.isActive()) {
                return new Enqueued(existing, !isActive(wanted.direction));
            }
            wanted.state = TransferRecord.QUEUED;
            wanted.reason = null;
            wanted.message = null;
            wanted.httpStatus = 0;
            wanted.idleRuns = 0;
            wanted.queuedAt = nextQueuedAt();
            if (TransferRecord.DOWNLOAD.equals(wanted.direction)) {
                File part = Downloader.partFile(new File(wanted.path));
                wanted.bytes = part.isFile() ? part.length() : 0;
            } else if (UploadAdapters.PUT.equals(wanted.protocol)) {
                // A PUT starts from the first byte every time.
                wanted.bytes = 0;
            } else if (carriesOver(existing, wanted, new File(wanted.path).length())) {
                wanted.bytes = existing.bytes;
                wanted.total = existing.total;
                // The same upload: what it sent, and whether its commit went, carry over.
                wanted.parts = existing.parts;
                wanted.committing = existing.committing;
            }
            TransferRecord stored = store.put(wanted);
            emit("stateChange", stored);
            return new Enqueued(stored, !isActive(wanted.direction));
        }
    }

    /**
     * Whether a restarted upload is the same one as {@code existing}, so what that one sent carries
     * over: the same URL and protocol, and for one in parts the same part or block size and file
     * size too (parts recorded for other ranges would otherwise be skipped as stored).
     */
    static boolean carriesOver(TransferRecord existing, TransferRecord wanted, long fileSize) {
        if (existing == null || !existing.url.equals(wanted.url) || !existing.protocol.equals(wanted.protocol)) return false;
        if (UploadAdapters.S3_MULTIPART.equals(wanted.protocol) || UploadAdapters.AZURE_BLOCKS.equals(wanted.protocol)) {
            return existing.partSize == wanted.partSize && existing.blockSize == wanted.blockSize && existing.total == fileSize;
        }
        return true;
    }

    /**
     * Cancels a transfer. A running one is stopped by its host, which then
     * cleans up; any other active or interrupted one is cancelled here.
     */
    public static void cancel(TransferStore store, String direction, String id) {
        synchronized (lock(direction)) {
            TransferRecord r = store.get(direction, id);
            if (r == null) return;
            if (r.key().equals(current.get(direction))) {
                stopRequests.put(r.key(), TransferException.Reason.CANCELLED);
                return;
            }
            if (r.isActive() || TransferRecord.INTERRUPTED.equals(r.state)) {
                cleanUp(r);
                r.state = TransferRecord.CANCELLED;
                r.reason = TransferException.Reason.CANCELLED;
                r.message = "cancelled";
                emit("stateChange", store.put(r));
            }
        }
    }

    /**
     * After the app opens: a record left {@code running} by a process that
     * died is queued again if a host is still scheduled for it, and otherwise
     * reported as interrupted. Returns true if there is queued work and no host
     * is running it in this process, so the caller should schedule one: a job
     * the system still holds (after a quota or other system stop it may hold it
     * for a long time) is replaced by a fresh one while the app is visible.
     */
    public static boolean reconcile(TransferStore store, String direction, boolean hostScheduled) {
        synchronized (lock(direction)) {
            if (isActive(direction)) return false;
            boolean queued = false;
            for (TransferRecord r : store.all()) {
                if (!direction.equals(r.direction)) continue;
                if (TransferRecord.RUNNING.equals(r.state)) {
                    if (hostScheduled) {
                        r.state = TransferRecord.QUEUED;
                    } else {
                        r.state = TransferRecord.INTERRUPTED;
                        r.reason = TransferException.Reason.STOPPED_BY_SYSTEM;
                        r.message = "the app was stopped while this was running";
                    }
                    emit("stateChange", store.put(r));
                }
                if (TransferRecord.QUEUED.equals(r.state)) queued = true;
            }
            return queued;
        }
    }

    /**
     * Works through the queue until it is empty, the host is stopped, or a
     * transfer is interrupted and the host can't wait for the network.
     * The caller must have called {@link #begin}; this always lets go.
     */
    public static Outcome drain(TransferStore store, String direction, Host host) {
        try {
            synchronized (lock(direction)) {
                // A record left running by a process that died (killed, or stopped mid-run) is this
                // host's to carry on: nothing else in this process is running the queue.
                for (TransferRecord r : store.all()) {
                    if (direction.equals(r.direction) && TransferRecord.RUNNING.equals(r.state)) {
                        r.state = TransferRecord.QUEUED;
                        store.put(r);
                    }
                }
            }
            while (true) {
                TransferRecord r;
                synchronized (lock(direction)) {
                    if (host.systemStopReason() != null) return Outcome.RESCHEDULE;
                    r = store.nextQueued(direction);
                    if (r == null) {
                        active.put(direction, false);
                        return Outcome.DONE;
                    }
                    r.state = TransferRecord.RUNNING;
                    r.reason = null;
                    r.message = null;
                    r.httpStatus = 0;
                    // A cancel that landed after an earlier run of this id ended isn't for this run.
                    stopRequests.remove(r.key());
                    current.put(direction, r.key());
                    r = store.put(r);
                }
                emit("stateChange", r);
                host.onProgress(r);
                Outcome outcome = runOne(store, r, host);
                if (outcome != null) return outcome;
            }
        } finally {
            synchronized (lock(direction)) {
                active.put(direction, false);
                current.remove(direction);
            }
        }
    }

    /** Runs one transfer to its end; returns non-null if the drain should stop. */
    private static Outcome runOne(TransferStore store, TransferRecord r, Host host) {
        final long startBytes = r.bytes;
        final long[] stamps = { 0, System.currentTimeMillis(), 0 }; // progress, save, notify
        Progress progress = new Progress() {
            @Override
            public void onBytes(long bytes, long total) {
                r.bytes = bytes;
                r.total = total;
                long now = System.currentTimeMillis();
                boolean done = total >= 0 && bytes >= total;
                if (done || now - stamps[0] >= PROGRESS_EVERY_MS) {
                    stamps[0] = now;
                    emit("progress", r);
                }
                if (done || now - stamps[1] >= SAVE_EVERY_MS) {
                    stamps[1] = now;
                    store.put(r);
                }
                if (done || now - stamps[2] >= NOTIFY_EVERY_MS) {
                    stamps[2] = now;
                    host.onProgress(r);
                }
            }

            @Override
            public String stopReason() {
                String asked = stopRequests.get(r.key());
                return asked != null ? asked : host.systemStopReason();
            }

            @Override
            public void saveState() {
                stamps[1] = System.currentTimeMillis();
                store.put(r);
            }
        };
        try {
            long total = TransferRecord.UPLOAD.equals(r.direction)
                ? UploadAdapters.forProtocol(r.protocol, retries, backoffMillis).run(r, progress)
                : new Downloader(retries, backoffMillis).run(r.url, new File(r.path), r.headers, progress);
            r.state = TransferRecord.FINISHED;
            r.bytes = total;
            r.total = total;
            r.idleRuns = 0;
            emit("stateChange", store.put(r));
            return null;
        } catch (TransferException e) {
            return stopped(store, r, host, e, r.bytes > startBytes);
        } catch (RuntimeException e) {
            return stopped(store, r, host, new TransferException(TransferException.Reason.UNKNOWN, String.valueOf(e), 0, e), false);
        } finally {
            synchronized (lock(r.direction)) {
                // No longer running: a cancel from here on finds the record's final state instead.
                current.remove(r.direction);
                stopRequests.remove(r.key());
            }
        }
    }

    private static Outcome stopped(TransferStore store, TransferRecord r, Host host, TransferException e, boolean moved) {
        r.reason = e.reason;
        r.message = e.getMessage();
        r.httpStatus = e.httpStatus;
        if (TransferException.Reason.CANCELLED.equals(e.reason)) {
            cleanUp(r);
            r.state = TransferRecord.CANCELLED;
            emit("stateChange", store.put(r));
            return null;
        }
        if (e.isResumable()) {
            r.idleRuns = moved ? 0 : r.idleRuns + 1;
            boolean systemStop = host.systemStopReason() != null;
            if (host.waitsForNetwork() && (systemStop || r.idleRuns < MAX_IDLE_RUNS)) {
                // The job: back in the queue, first in line; the system starts the job again when it can.
                r.state = TransferRecord.QUEUED;
                emit("stateChange", store.put(r));
                return Outcome.RESCHEDULE;
            }
            r.state = TransferRecord.INTERRUPTED;
            emit("stateChange", store.put(r));
            // The worker can't come back by itself: leave the rest queued for the next open.
            return host.waitsForNetwork() ? null : Outcome.INTERRUPTED;
        }
        cleanUp(r);
        r.state = TransferRecord.FAILED;
        emit("stateChange", store.put(r));
        return null;
    }

    /** Removes a transfer's temporary files: a download's {@code .part}. An upload has none on Android (parts are read in place). */
    static void cleanUp(TransferRecord r) {
        if (TransferRecord.DOWNLOAD.equals(r.direction)) {
            Downloader.deleteQuietly(Downloader.partFile(new File(r.path)));
            r.bytes = 0;
        }
    }

    private static void emit(String name, TransferRecord r) {
        Events e = events;
        if (e != null) e.onEvent(name, r);
    }
}
