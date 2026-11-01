package io.github.sandman92.backgroundtransfer;

import java.io.File;
import java.util.Map;

/** Sends a file to an upload session in one protocol. {@link Uploader} is the Firebase Storage one. */
public interface UploadAdapter {
    /** Uploads {@code file} to the session at {@code url}; returns the file's size once the server has it all. */
    long run(String url, File file, Map<String, String> headers, Progress progress) throws TransferException;
}
