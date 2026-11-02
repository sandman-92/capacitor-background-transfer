package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;

final class Bytes {

    private Bytes() {}

    static byte[] pattern(int n) {
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte) ((i * 7 + 13) % 251);
        return b;
    }

    static File write(File dir, String name, byte[] data) throws IOException {
        File f = new File(dir, name);
        Files.write(f.toPath(), data);
        return f;
    }

    static final class Recorder implements Progress {

        long bytes = -1;
        long total = -2;
        int calls;
        volatile String stop;
        /** Stop once this many bytes are reported. */
        long stopAt = Long.MAX_VALUE;
        String stopWith = TransferException.Reason.CANCELLED;

        @Override
        public void onBytes(long bytes, long total) {
            this.bytes = bytes;
            this.total = total;
            calls++;
            if (bytes >= stopAt) stop = stopWith;
        }

        @Override
        public String stopReason() {
            return stop;
        }
    }
}
