# Changelog

## 0.1.0 (2026-11-08)

First version.

- `upload()` to an existing Firebase Storage resumable upload (the `X-Goog-Upload` protocol):
  asks for the offset, sends the rest, finalizes. No `Authorization` header unless passed in
  `headers`. A `protocol` option (`firebase-resumable`, the default and only value) leaves room
  for other protocols; unknown values are refused on every platform.
- `download()` to `<path>.part`, renamed into place only when whole; resumes with `Range`.
- Android 14+: a user-initiated data transfer job per direction. Android 6 to 13: a WorkManager
  `dataSync` foreground-service worker. iOS: background `URLSession`s, with a temporary copy of
  the remaining bytes to resume an upload part-way.
- One transfer per direction at a time; `progress` and `stateChange` events; `list()`,
  `cancel()`, `forget()`; a reason for every stopped transfer, including `session-closed` for a
  session that was already closed when the upload started.
- iOS: an upload answered with anything but a clean finalize of the file's exact size is checked
  against the session, including after a relaunch; remainder copies no transfer names are
  removed at launch.
- `isAvailable()` carries a `warning` below Android 14 when the app's manifest doesn't declare
  WorkManager's foreground service with the `dataSync` type.
- The web reports the plugin as unavailable.
- Three more upload protocols (#2):
  - `put`: the whole file in one `PUT` (an S3 presigned URL, an Azure SAS URL, any server that
    takes one); an interrupted upload starts again from the first byte.
  - `s3-multipart`: an S3 multipart upload with every part URL, the completion URL and
    optionally a ListParts URL presigned up front (`partUrls`, `partSize`, `listPartsUrl`). Parts
    go one at a time; their `ETag`s are kept, parts already stored are skipped on resume, and the
    upload is finished only when S3 answers the completion with the completed object.
  - `azure-blocks`: an Azure block blob through one SAS URL (`blockSize`): blocks with stable ids,
    resumed from the uncommitted block list (or the plugin's record when the SAS can't read it),
    committed with `Put Block List`.
  - A commit whose answer was lost reports `session-closed` when the upload is started again,
    never `finished`. Their options are refused at once when missing or inconsistent, with the
    same words on the web, Android and iOS.
  - iOS sends each part or block from a temporary copy of its range: one at a time while the
    app is on screen, and every remaining one handed to the background session at once when it
    leaves (temporary disk equal to what's left to send; one at a time again when that wouldn't
    leave 256 MiB free), so a background upload doesn't wait for a wake between parts. `put`
    sends the file in place.
  - `test-servers/`: MinIO and Azurite in Docker with a harness that presigns URLs and injects
    faults; `npm run test:servers` runs the JVM and Swift tests against them; the example app's
    harness mode and `test-servers/e2e.mjs` run them end to end on an emulator or simulator.
- Hardening, from the security audit of 2026-11-03 (#7, #8, #9, #10, #11):
  - `path` is confined natively to the app's own directories (Android: files, no-backup files
    and cache, internal and external; iOS: Documents, Library and tmp), plus any `allowedRoots`
    from the plugin's configuration, after symbolic links are resolved; the plugin's own storage,
    `..` segments and a download onto a symbolic link are refused, and a download never writes
    through one. The URL's scheme and the headers (one line, no control characters) are checked
    natively as well as in the wrapper, with the same words.
  - Headers only reach the host in the URL: Android follows a download's redirect on the same
    origin only and never an upload's; iOS holds its plain requests to the same rule and reports a
    background task that was redirected elsewhere `session-refused` when it ends.
  - The transfer store is out of backups (Android: `getNoBackupFilesDir()`, moved there from
    `filesDir` on the first launch; iOS: the plugin's directory is excluded from backup, resume
    data and remainder copies included), and a record drops its headers as soon as the transfer
    stops.
  - `.gitignore` covers `.env` files, keystores, certificates and platform credential files, and
    CI runs a secret scan on every push and pull request.
