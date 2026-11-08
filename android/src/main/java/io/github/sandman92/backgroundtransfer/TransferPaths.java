package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The checks on a transfer's options that the native side repeats, whatever the JavaScript wrapper
 * did: a script in the web view can call the plugin directly and skip {@code validate.ts}. The
 * refusals use the wrapper's words. Plain Java, so it runs under JUnit.
 */
final class TransferPaths {

    private static final Pattern HTTP_URL = Pattern.compile("^https?://[^/]+.*", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern CONTROL = Pattern.compile("[\\x00-\\x1f\\x7f]");

    static final String NOT_HTTP = "url must be an http or https URL";
    static final String OUTSIDE = "path must be inside the app's storage";
    static final String PLUGIN_DIR = "path must not be inside the plugin's own storage";
    static final String SYMLINK = "path must not be a symbolic link";

    /** How many hops a redirect is followed on the same host before the transfer is refused. */
    static final int MAX_REDIRECTS = 5;

    private TransferPaths() {}

    /** What is wrong with {@code url}, or null. */
    static String checkUrl(String url) {
        return url != null && HTTP_URL.matcher(url).matches() ? null : NOT_HTTP;
    }

    /** What is wrong with the headers (a name or value with a line break or another control character), or null. */
    static String checkHeaders(Map<String, String> headers) {
        if (headers == null) return null;
        for (Map.Entry<String, String> h : headers.entrySet()) {
            String name = h.getKey();
            if (
                name == null ||
                name.isEmpty() ||
                CONTROL.matcher(name).find() ||
                h.getValue() == null ||
                CONTROL.matcher(h.getValue()).find()
            ) {
                return "header " + name + " must be one line";
            }
        }
        return null;
    }

    /** The wrapper's checks on the path's shape: absolute, naming a file, no {@code ..} segment. */
    static String checkShape(String path) {
        if (path == null || path.isEmpty()) return "path is required";
        if (!path.startsWith("/")) return "path must be absolute or a file:// URI";
        if (path.endsWith("/")) return "path must name a file";
        for (String segment : path.split("/")) if ("..".equals(segment)) return "path must not contain ..";
        return null;
    }

    /**
     * Refuses a path that isn't under one of {@code roots} (the app's own directories) once symbolic
     * links are resolved, or that is inside {@code refused} (the plugin's own storage, which holds
     * other transfers' headers). For a download, the destination and its {@code .part} must not be
     * symbolic links either, since both are replaced. Returns what is wrong, or null.
     */
    static String confine(String path, List<File> roots, File refused, boolean download) {
        String shape = checkShape(path);
        if (shape != null) return shape;
        File file = new File(path);
        File canonical;
        try {
            canonical = canonical(file);
        } catch (IOException e) {
            return OUTSIDE;
        }
        if (refused != null) {
            try {
                if (isUnder(canonical, canonical(refused))) return PLUGIN_DIR;
            } catch (IOException ignored) {
                // The plugin's directory can't be resolved: nothing to be inside of.
            }
        }
        boolean inside = false;
        for (File root : roots) {
            if (root == null) continue;
            try {
                if (isUnder(canonical, canonical(root))) {
                    inside = true;
                    break;
                }
            } catch (IOException ignored) {
                // A root that can't be resolved (an unmounted volume) admits nothing.
            }
        }
        if (!inside) return OUTSIDE;
        if (download && (Files.isSymbolicLink(file.toPath()) || Files.isSymbolicLink(Downloader.partFile(file).toPath()))) {
            return SYMLINK;
        }
        return null;
    }

    /**
     * {@code file} with every symbolic link resolved: its deepest existing ancestor is canonicalised
     * and the rest appended, so a file not yet written (a download's destination) resolves too.
     */
    static File canonical(File file) throws IOException {
        File absolute = file.getAbsoluteFile();
        List<String> rest = new ArrayList<>();
        File existing = absolute;
        while (existing != null && !existing.exists()) {
            rest.add(0, existing.getName());
            existing = existing.getParentFile();
        }
        if (existing == null) throw new IOException("no existing ancestor for " + file);
        File resolved = existing.getCanonicalFile();
        for (String name : rest) resolved = new File(resolved, name);
        return resolved;
    }

    /** Whether {@code file} is {@code root} or inside it (both canonical). */
    static boolean isUnder(File file, File root) {
        String f = file.getPath();
        String r = root.getPath();
        return f.equals(r) || f.startsWith(r.endsWith(File.separator) ? r : r + File.separator);
    }
}
