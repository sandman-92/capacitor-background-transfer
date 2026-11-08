package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Fetches a URL into {@code <dest>.part}, resuming from that file's size with
 * a {@code Range} request, and renames it to {@code dest} only once every
 * byte has landed. A half-finished file never sits at {@code dest}.
 *
 * Plain Java (no Android types), so it runs under JUnit against a local
 * server.
 */
public final class Downloader {

    private static final int BUFFER = 256 * 1024;
    private static final Pattern CONTENT_RANGE = Pattern.compile("bytes\\s+(?:(\\d+)-(\\d+)|\\*)/(\\d+|\\*)");

    private final int retries;
    private final long backoffMillis;

    public Downloader() {
        this(3, 2000);
    }

    /** For tests: quicker retries. */
    public Downloader(int retries, long backoffMillis) {
        this.retries = retries;
        this.backoffMillis = backoffMillis;
    }

    /** A parsed {@code Content-Range}: {@code start} is -1 for {@code bytes *}, {@code total} -1 for {@code /*}. */
    public static final class Range {

        public final long start;
        public final long end;
        public final long total;

        Range(long start, long end, long total) {
            this.start = start;
            this.end = end;
            this.total = total;
        }
    }

    /** Parses {@code bytes 100-199/1000} or {@code bytes *}{@code /1000}; null when it isn't one. */
    public static Range parseContentRange(String header) {
        if (header == null) return null;
        Matcher m = CONTENT_RANGE.matcher(header.trim());
        if (!m.matches()) return null;
        long start = m.group(1) == null ? -1 : Long.parseLong(m.group(1));
        long end = m.group(2) == null ? -1 : Long.parseLong(m.group(2));
        long total = "*".equals(m.group(3)) ? -1 : Long.parseLong(m.group(3));
        return new Range(start, end, total);
    }

    /** Where the bytes go until they have all landed. */
    public static File partFile(File dest) {
        return new File(dest.getPath() + ".part");
    }

    /** Downloads {@code url} to {@code dest}; returns its size. */
    public long run(String url, File dest, Map<String, String> headers, Progress progress) throws TransferException {
        int attempt = 0;
        while (true) {
            try {
                return attempt(url, dest, headers, progress, true);
            } catch (TransferException e) {
                if (!TransferException.Reason.NETWORK.equals(e.reason) || attempt >= retries) throw e;
                attempt++;
                Pause.sleep(backoffMillis << (attempt - 1), progress);
            }
        }
    }

    private long attempt(String url, File dest, Map<String, String> headers, Progress progress, boolean mayRestart)
        throws TransferException {
        File part = partFile(dest);
        File dir = dest.getAbsoluteFile().getParentFile();
        if (dir != null && !dir.isDirectory() && !dir.mkdirs()) {
            throw new TransferException(TransferException.Reason.UNKNOWN, "can't make " + dir);
        }
        long have = part.isFile() ? part.length() : 0;
        if (Files.isSymbolicLink(part.toPath()) || Files.isSymbolicLink(dest.toPath())) {
            throw new TransferException(TransferException.Reason.UNKNOWN, "refusing to write through a symbolic link at " + dest);
        }
        Pause.check(progress);
        HttpURLConnection c = null;
        try {
            URL target = new URL(url);
            int code;
            int hops = 0;
            while (true) {
                c = (HttpURLConnection) target.openConnection();
                c.setInstanceFollowRedirects(false);
                c.setUseCaches(false);
                c.setConnectTimeout(30_000);
                c.setReadTimeout(120_000);
                // The byte count must be the file's, not a compressed stream's.
                c.setRequestProperty("Accept-Encoding", "identity");
                if (headers != null) {
                    for (Map.Entry<String, String> h : headers.entrySet()) c.setRequestProperty(h.getKey(), h.getValue());
                }
                if (have > 0) c.setRequestProperty("Range", "bytes=" + have + "-");
                code = c.getResponseCode();
                if (!Http.isRedirect(code)) break;
                // Followed on the same origin only, so the headers never reach a host the app didn't name.
                String location = c.getHeaderField("Location");
                URL next = location == null ? null : new URL(target, location);
                c.disconnect();
                c = null;
                if (next == null || !Http.sameOrigin(target, next)) {
                    throw new TransferException(
                        TransferException.Reason.SESSION_REFUSED,
                        "download HTTP " + code + ": redirected to " + (next == null ? "nowhere" : next.getHost()) + ", not followed",
                        code,
                        null
                    );
                }
                if (++hops > TransferPaths.MAX_REDIRECTS) {
                    throw new TransferException(TransferException.Reason.SESSION_REFUSED, "download: too many redirects", code, null);
                }
                target = next;
            }
            long total;
            boolean append;
            if (code == 206) {
                Range r = parseContentRange(c.getHeaderField("Content-Range"));
                if (r == null || r.start != have) {
                    // Not the range we asked for: start again from nothing.
                    deleteQuietly(part);
                    if (mayRestart) {
                        c.disconnect();
                        return attempt(url, dest, headers, progress, false);
                    }
                    throw new TransferException(
                        TransferException.Reason.SIZE_MISMATCH,
                        "server sent range " + c.getHeaderField("Content-Range")
                    );
                }
                total = r.total;
                append = true;
            } else if (code == 200) {
                total = c.getContentLengthLong();
                have = 0;
                append = false;
            } else if (code == 416 && have > 0) {
                Range r = parseContentRange(c.getHeaderField("Content-Range"));
                if (r != null && r.total == have) {
                    progress.onBytes(have, have);
                    return finish(part, dest, have);
                }
                deleteQuietly(part);
                if (mayRestart) {
                    c.disconnect();
                    return attempt(url, dest, headers, progress, false);
                }
                throw TransferException.forStatus(code, "download");
            } else {
                throw TransferException.forStatus(code, "download");
            }
            progress.onBytes(have, total);
            long got = copy(c, part, append, have, total, progress);
            if (total >= 0 && got != total) {
                if (got < total) throw new TransferException(
                    TransferException.Reason.NETWORK,
                    "connection closed at " + got + " of " + total
                );
                deleteQuietly(part);
                throw new TransferException(TransferException.Reason.SIZE_MISMATCH, "got " + got + " bytes, expected " + total);
            }
            return finish(part, dest, got);
        } catch (IOException e) {
            throw new TransferException(TransferException.Reason.NETWORK, "download: " + e, 0, e);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    /** Copies the body into {@code part}; returns the part file's size. Network and disk errors are told apart. */
    private static long copy(HttpURLConnection c, File part, boolean append, long have, long total, Progress progress)
        throws TransferException, IOException {
        byte[] buffer = new byte[BUFFER];
        long size = have;
        FileOutputStream out;
        try {
            out = new FileOutputStream(part, append);
        } catch (IOException e) {
            throw TransferException.forDisk(e);
        }
        try (InputStream in = c.getInputStream()) {
            while (true) {
                Pause.check(progress);
                int n = in.read(buffer); // IOException here is the network
                if (n < 0) break;
                try {
                    out.write(buffer, 0, n);
                } catch (IOException e) {
                    throw TransferException.forDisk(e);
                }
                size += n;
                progress.onBytes(size, total);
            }
        } finally {
            try {
                out.getFD().sync();
            } catch (IOException ignored) {
                // Best effort: the size check below still guards the rename.
            }
            try {
                out.close();
            } catch (IOException e) {
                throw TransferException.forDisk(e);
            }
        }
        return part.length();
    }

    private static long finish(File part, File dest, long size) throws TransferException {
        if (part.length() != size) {
            throw new TransferException(TransferException.Reason.SIZE_MISMATCH, "part file is " + part.length() + ", expected " + size);
        }
        if (Files.isSymbolicLink(dest.toPath())) {
            throw new TransferException(TransferException.Reason.UNKNOWN, "refusing to replace a symbolic link at " + dest);
        }
        if (dest.exists() && !dest.delete()) {
            throw new TransferException(TransferException.Reason.UNKNOWN, "can't replace " + dest);
        }
        if (!part.renameTo(dest)) throw new TransferException(TransferException.Reason.UNKNOWN, "can't rename " + part + " to " + dest);
        return size;
    }

    static void deleteQuietly(File f) {
        if (f.exists() && !f.delete()) f.deleteOnExit();
    }
}
