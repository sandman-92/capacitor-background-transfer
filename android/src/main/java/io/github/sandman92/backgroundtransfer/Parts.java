package io.github.sandman92.backgroundtransfer;

/** How a file divides into parts (S3) or blocks (Azure), numbered from 1. */
final class Parts {

    private Parts() {}

    /**
     * How many {@code partSize}-byte parts a {@code size}-byte file takes. An empty file is one
     * (empty) part when {@code atLeastOne} (S3 needs a part to complete), and none otherwise.
     */
    static int count(long size, long partSize, boolean atLeastOne) {
        if (size <= 0) return atLeastOne ? 1 : 0;
        long n = (size + partSize - 1) / partSize;
        return n > Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) n;
    }

    static long offset(int n, long partSize) {
        return (n - 1) * partSize;
    }

    static long length(int n, long size, long partSize) {
        return Math.max(0, Math.min(partSize, size - offset(n, partSize)));
    }
}
