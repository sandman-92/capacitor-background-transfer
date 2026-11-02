package io.github.sandman92.backgroundtransfer;

/** Waiting between retries without missing a cancel. */
final class Pause {

    private Pause() {}

    /** Throws if the transfer has been told to stop. */
    static void check(Progress progress) throws TransferException {
        String reason = progress.stopReason();
        if (reason != null) throw new TransferException(reason, "stopped: " + reason);
    }

    /** Sleeps up to {@code millis}, checking for a stop every quarter second. */
    static void sleep(long millis, Progress progress) throws TransferException {
        long until = System.currentTimeMillis() + millis;
        while (System.currentTimeMillis() < until) {
            check(progress);
            try {
                Thread.sleep(Math.min(250, Math.max(1, until - System.currentTimeMillis())));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new TransferException(TransferException.Reason.STOPPED_BY_SYSTEM, "interrupted");
            }
        }
        check(progress);
    }
}
