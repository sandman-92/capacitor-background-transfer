# How transfers run

What each platform does with a transfer, what happens when the system or the user stops it,
and how to start it again. For setup and a first upload see the [README](../README.md).

## On each platform

| | Android 14+ (API 34+) | Android 6 to 13 | iOS |
|---|---|---|---|
| Mechanism | A user-initiated data transfer job, one per direction | A WorkManager worker promoted to a `dataSync` foreground service, one per direction | A background `URLSession` per direction, one connection per host |
| Upload | Read from the file in place: 4 MiB chunks (`firebase-resumable`), each part or block, or the whole file (`put`) | Same | `firebase-resumable`: the whole file in one request when the server holds nothing, otherwise a temporary copy of the remaining bytes (a background session can't send a byte range). `s3-multipart`, `azure-blocks`: each part or block from a temporary copy of its range, one at a time while the app is on screen and every remaining one handed over at once when it leaves (the session still sends them one by one). `put`: the file in place. Copies are deleted when their task ends |
| Download | Streamed to `<path>.part`, resumed with `Range` | Same | A background download task, resumed from the system's resume data or with `Range`. While it runs the bytes are in the system's own temporary file |
| Locked, Doze, removed from Recents | Carries on | Carries on | Carries on in the system's transfer daemon, also after the app's process ends |
| Network drops with the app off-screen | The system stops the job and runs it again when the network is back | Reported `interrupted`: a foreground service can't be started again from the background, so start the transfer again at the next launch | The system often retries by itself; if it gives up, reported `interrupted` |
| Force-stopped, or stopped from the Task Manager (Android); swiped away (iOS) | Reported `interrupted` | Same | Reported `interrupted` at the next launch |
| Notification | The job's notification is its progress (channel, title and text from `notification`). Runs with notifications refused | The foreground service's notification | None |
| Limits | None on duration | The six-hour daily `dataSync` limit | Work started from the background may be deferred |

Some details:

- **Android, system stops.** A job the system stops (quota, device state) goes back in the queue
  and the system runs it again, which can take minutes; the next `upload()`, `download()` or app
  launch schedules it afresh straight away. If the app's process dies while a job runs, the
  system starts the job again once the device leaves Doze, and it carries on from the server's
  offset or the `.part` size.
- **Order.** On Android the queue runs in the order transfers were started. On iOS every
  transfer is handed to the system at once (one connection per host keeps them one at a time),
  and the system picks the order. Each part-way iOS upload has its remainder copy made when it
  is started, so the disk it borrows adds up across a queue.
- **iOS resends.** The system may resend an upload by itself after a dropped connection, with
  the offset the request was made with. Unless the answer is a clean finalize of exactly the
  file's size, the plugin asks the session what it holds before believing it: a session still
  open is `interrupted` (start it again to carry on), a wrong-sized object is `size-mismatch`.
  The answer is recorded first, and the system's completion handler is held until it is in
  (the check gives up after 20 seconds, inside the roughly 30 seconds a relaunched app gets); if
  the app still ends first, the next launch checks again.
- **Stored on the device.** Each transfer's record is kept in the app's sandbox until `forget()`
  removes it: `no_backup/background-transfer/transfers.json` on Android (a store an earlier
  version kept under `files/` is moved there on the first launch) and
  `Library/Application Support/BackgroundTransfer/transfers.json` on iOS, a directory marked
  excluded from backups, which also covers the remainder copies and a download's resume data. So
  neither Android Auto Backup nor an iCloud or Finder backup carries the records to another
  device. The `headers` you pass are in the record only while the transfer is queued or running:
  they are dropped as soon as it finishes, fails, is cancelled or is interrupted (starting it again
  supplies them afresh). The URL stays, since the app reads it back from `list()`. On iOS the
  system's resume data for an interrupted download still embeds the original request, headers
  included, until the download is started again or cancelled.
- **Where the headers go.** Only to the host named in the URL. On Android a download follows a
  redirect on the same scheme, host and port (five hops at most) and refuses one anywhere else
  (`session-refused`, with the 3xx status); an upload never follows one, since the body would have
  to go again. On iOS the plain requests (the session query, ListParts, Get Block List) are held to
  the same rule; the background session follows redirects by itself and can't be stopped, so a task
  whose answer came from another host is reported `session-refused` when it ends, its file
  discarded, and the headers have by then reached that host once. Pass headers only with URLs that
  don't redirect.
- **Where the files may be.** The native side checks `path` itself, after resolving symbolic
  links, so a script that calls the plugin without the TypeScript wrapper gets the same refusals:
  inside the app's own directories (or the `allowedRoots` from the plugin's configuration), never
  the plugin's own storage, no `..`, and no download onto a symbolic link (checked again when the
  bytes land). The URL's scheme and the headers (one line each, no control characters) are checked
  natively too.

## Starting a transfer again

Start transfers while the app is on screen: Android only lets a user-initiated job be scheduled
then, and iOS may defer background work started from the background.

Starting a transfer with the `id` of one that is `interrupted`, `failed` or `cancelled` starts
it again from where it stopped (an upload asks the server, or for `s3-multipart` without a
ListParts URL uses its own record of the parts sent; a `put` starts again from the first byte; a
download uses its `.part` file). Starting one that is `queued` or `running` changes nothing.
Starting an upload with the `id` of a `finished` one reports `failed` (`session-closed`) for
every protocol but `put`: start a new upload to send the file again.

## Why a transfer stopped

`reason` on a stopped transfer is one of:

| Reason | Meaning |
|---|---|
| `file-missing` | The file to upload isn't there |
| `disk-full` | No space for a download, or for the remainder copy an iOS upload needs to resume part-way |
| `session-refused` | HTTP 4xx, e.g. 403 when Firebase Storage security rules refuse the upload at finalize, or when a presigned URL or SAS token has expired or lacks a permission. `message` names the request (`part 2 of 3 HTTP 403`, `block 1 of 3 HTTP 403`, `PUT HTTP 403`, `complete HTTP 403`, `commit (Put Block List) HTTP 403`). Start a new upload |
| `session-expired` | HTTP 404 or 410: the session, upload ID or URL is gone. Start a new upload |
| `session-closed` | The upload can't be confirmed from here, so check the object on the server. `firebase-resumable`: the session was already closed when the upload started, which isn't proof the object was accepted (the Firebase Storage emulator closes a session whose finalize its rules refused). `s3-multipart` and `azure-blocks`: the commit was sent earlier and its answer never came (or S3 says the upload is no longer open); it may or may not have been applied |
| `size-mismatch` | The bytes that landed don't add up to the expected size |
| `network` | The connection dropped (with `interrupted`) |
| `stopped-by-system` | The system ended the work, or the user did from the Task Manager or by swiping the app away (with `interrupted`) |
| `cancelled` | `cancel()` was called |
| `server-error` | The server kept answering 5xx |
| `unknown` | Anything else; `message` has the detail |
