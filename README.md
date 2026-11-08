# capacitor-background-transfer

Background uploads and downloads for Capacitor 7 on Android and iOS. A transfer keeps going
while the phone is locked or the app is in the background or closed, and picks up where it
stopped after a dropped connection.

- **Upload** to an upload your app has set up on the server, in one of four protocols (the
  `protocol` option; see [Upload protocols](#upload-protocols)):
  - `firebase-resumable` (the default): a Firebase Storage resumable upload (the `X-Goog-Upload`
    protocol). The plugin asks the session how many bytes it holds and sends the rest.
  - `put`: the whole file in one `PUT` to a URL, e.g. an S3 presigned URL or an Azure SAS URL.
  - `s3-multipart`: an Amazon S3 (or S3-compatible) multipart upload, with every URL presigned.
  - `azure-blocks`: an Azure Blob Storage block blob through one SAS URL.

  The plugin never signs a request or holds a cloud credential: the URLs you pass carry their own
  authorisation. It sends no `Authorization` header unless you pass one in `headers`.
- **Download** any URL to a file. Bytes go to `<path>.part`, which is renamed to `<path>` only
  once every byte has landed, and an interrupted download resumes with a `Range` request.
- **Both**: one transfer per direction at a time, the rest queued; progress and state events
  while the app is open; `list()` says what ran, finished or failed while it was closed;
  `cancel()` removes temporary files; nothing half-written is reported as finished.

On the web the plugin reports itself unavailable (`isAvailable()` returns `{ available: false }`
and transfer calls reject with `UNAVAILABLE`), so an app can fall back to its own code there.

## Install

```bash
npm install capacitor-background-transfer
npx cap sync
```

Requires Capacitor 7, Android 6 (API 23) or later and iOS 15 or later.

### Android

The plugin's manifest adds the `INTERNET`, `ACCESS_NETWORK_STATE`, `RUN_USER_INITIATED_JOBS`,
`RECEIVE_BOOT_COMPLETED`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` and
`POST_NOTIFICATIONS` permissions and its job service. **Your app declares WorkManager's
foreground service with the `dataSync` type** (the plugin doesn't, so it can't clash with an app
that declares the service with other types as well). In `android/app/src/main/AndroidManifest.xml`,
inside `<application>` (with `xmlns:tools` on `<manifest>`):

```xml
<service
    android:name="androidx.work.impl.foreground.SystemForegroundService"
    android:foregroundServiceType="dataSync"
    tools:node="merge" />
```

Without it, transfers below Android 14 stop when the app leaves the screen, and `isAvailable()`
carries a `warning` saying so. Ask for the notification permission on Android 13+ if you want the
progress notification shown; transfers run without it. The WorkManager version follows
`workManagerVersion` in your `variables.gradle` (default 2.10.0).

### iOS

Hand the system's background session events to the plugin in `AppDelegate`, so transfers that
end while the app is closed are recorded straight away (otherwise on the next launch):

```swift
import BackgroundTransferPlugin

func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    if BackgroundTransferPlugin.handleEvents(forBackgroundURLSession: identifier, completionHandler: completionHandler) { return }
    completionHandler()
}
```

The module is `BackgroundTransferPlugin` with both Swift Package Manager and CocoaPods. Files to
upload must be readable while the phone is locked: the default data protection (until the first
unlock after a restart) is; complete protection isn't.

## Usage

```ts
import { BackgroundTransfer } from 'capacitor-background-transfer';

const { available } = await BackgroundTransfer.isAvailable();

await BackgroundTransfer.addListener('stateChange', ({ transfer }) => {
  // transfer.state: queued, running, interrupted, finished, failed or cancelled
});
await BackgroundTransfer.addListener('progress', ({ transfer }) => {
  // transfer.bytes of transfer.total
});

// Start the Firebase Storage resumable upload yourself (it is where your credentials go), then
// hand its session URL to the plugin.
await BackgroundTransfer.upload({
  id: 'clip-42',
  url: sessionUrl, // the X-Goog-Upload-URL from the session's start
  protocol: 'firebase-resumable', // the default; any other value is refused
  path: fileUri, // an absolute path or file:// URI, e.g. from Filesystem.getUri()
  notification: { title: 'Uploading', text: 'clip-42.mp4' }, // Android only
});

await BackgroundTransfer.download({ id: 'clip-42', url: downloadUrl, path: destinationUri });

// At launch: what happened while the app was away.
const { transfers } = await BackgroundTransfer.list();
```

Start transfers while the app is on screen: Android only lets a user-initiated job be scheduled
then, and iOS may defer background work started from the background.

Starting a transfer with the `id` of one that is `interrupted`, `failed` or `cancelled` starts
it again from where it stopped (an upload asks the server, or for `s3-multipart` without a
ListParts URL uses its own record of the parts sent; a `put` starts again from the first byte; a
download uses its `.part` file). Starting one that is `queued` or `running` changes nothing.
Starting an upload with the `id` of a `finished` one reports `failed` (`session-closed`) for
every protocol but `put`: start a new upload to send the file again.

### Why a transfer stopped

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

## Upload protocols

Every protocol has the same guarantees: it keeps going with the phone locked or the app in the
background or closed; `progress` and `stateChange` events and `list()` behave the same; an upload
is reported `finished` only when the server has confirmed the whole object; a commit whose answer
was lost is never taken as success (`session-closed`); and every stopped upload has a `reason`.
Options that are missing or don't fit together are refused at once by `upload()`, on the web too.
Parts and blocks go one at a time, in order; uploads of different files queue as before.

The plugin keeps what it has sent (S3 `ETag`s, Azure block ids, whether the commit went) in the
transfer's record, saved as it changes, so a resume survives the app being killed. It never asks
your app for fresh URLs while an upload runs, so make every URL last as long as the upload may
take (below).

### `put`

The whole file in one `PUT`, e.g. to an S3 presigned `PutObject` URL or an Azure blob SAS URL.

```ts
await BackgroundTransfer.upload({
  id: 'clip-42',
  path: fileUri,
  protocol: 'put',
  url: presignedPutUrl,
  headers: { 'Content-Type': 'video/mp4' }, // for Azure also 'x-ms-blob-type': 'BlockBlob'
});
```

- **Server side:** presign a `PUT` (S3: `PutObject`; Azure: a blob SAS with `c` and `w`). Any
  server that takes a `PUT` of the body and answers 2xx works. Headers you sign into the URL must
  be passed in `headers`.
- **Resuming:** there is nothing to resume from; an interrupted upload sends the file again from
  the first byte. S3 takes at most 5 GB in one `PUT`; use `s3-multipart` for bigger files, or
  when a restart from zero would cost too much.
- **URL lifetime:** until the last byte is sent, including any time the upload waits for the
  network or is restarted.
- **iOS disk:** none; the file is sent in place.

### `s3-multipart`

An Amazon S3 multipart upload you have created, with every URL presigned up front.

```ts
// On your server: CreateMultipartUpload, then presign UploadPart for parts 1..n,
// CompleteMultipartUpload and (optionally) ListParts, all for the same UploadId.
await BackgroundTransfer.upload({
  id: 'clip-42',
  path: fileUri,
  protocol: 's3-multipart',
  url: presignedCompleteUrl, // POST ?uploadId=…
  partUrls: presignedPartUrls, // PUT ?partNumber=1&uploadId=…, part 1 first
  partSize: 8 * 1024 * 1024, // the default
  listPartsUrl: presignedListPartsUrl, // GET ?uploadId=…, optional
});
```

- **Server side:** `CreateMultipartUpload`, then presign `UploadPart` once for every part
  (`ceil(size / partSize)` of them, or one for an empty file), `CompleteMultipartUpload` and,
  optionally, `ListParts`. The bucket's CORS rules don't matter (the requests are native), but
  if you presign with signed headers, pass them in `headers`. Add a lifecycle rule that aborts
  incomplete multipart uploads after a few days: the plugin can't abort one it gives up on.
- **Options:** `partUrls` (required, at most 10,000, exactly as many as the file needs), `partSize`
  (default 8 MiB; at least 5 MiB when there is more than one part, at most 5 GiB), `listPartsUrl`
  (optional). On Android and iOS `upload()` also checks `partUrls` against the file's size.
- **Resuming:** a restarted upload carries over what it sent only when its URL, part size and
  file size are the same as before. With `listPartsUrl`, a resumed upload asks S3 which parts it
  holds and sends the rest, so you can also presign fresh URLs for the same `UploadId` and carry
  on where expired ones stopped. Without it, the plugin trusts its own record of the parts it
  sent.
- **Completion:** finished only when S3 answers `CompleteMultipartUpload` with the completed
  object (S3 can answer 200 with an error, which is not taken as success). If the completion's
  answer is lost, starting the upload again reports `session-closed`: check the object (e.g.
  `HeadObject`) before starting a new upload.
- **URL lifetime:** S3 presigned URLs last at most 7 days (and no longer than the credentials that
  signed them: a role session's URL dies with the session). Each part URL must be valid until its
  part is sent and the completion URL until the end, including time spent waiting for the network.
  Presign for the longest the upload may reasonably take, e.g. a day or more for large files on
  mobile networks.
- **S3-compatible services** (MinIO, Cloudflare R2, Backblaze B2, DigitalOcean Spaces) speak the
  same protocol and are expected to work; only MinIO is tested.
- **iOS in the background:** while the app is on screen the parts go one at a time. When it
  leaves the screen, every remaining part is copied and handed to the background session at
  once (its one connection per host still sends them one by one), and so is the rest when the
  system wakes the app in the background with parts still to send. Otherwise each next part
  would wait for a background wake, which the system holds back longer every time (about 1, 2,
  4, 8 minutes...). The commit goes once every part is stored, whatever order their answers
  come back in; in the background it waits for one more wake (about a minute on the iOS 27
  simulator: 11 MiB in three parts was stored about 70 s after the app left the screen). A
  refused or dropped part, or `cancel()`, stops the others and removes their copies; once
  `cancel()` is called nothing more is sent. A commit already out is left to finish: the upload
  is `finished` if the server confirms the object, and `cancelled` otherwise (then, since the
  commit may have been applied, starting it again reports `session-closed`).
- **iOS disk:** a background session can only send whole files, so each part is sent from a
  temporary copy of its byte range, deleted when its task ends. On screen that is about one part
  (8 MiB by default) of extra disk at a time; once the app leaves the screen, copies of everything
  still to send, as for a part-way `firebase-resumable` upload. If that wouldn't leave 256 MiB
  free, it carries on one part at a time instead (and says so in the transfer's `message`), with
  the system's growing waits between parts.

### `azure-blocks`

An Azure Blob Storage block blob through one SAS URL.

```ts
await BackgroundTransfer.upload({
  id: 'clip-42',
  path: fileUri,
  protocol: 'azure-blocks',
  url: blobSasUrl, // https://account.blob.core.windows.net/container/blob?sv=…&sp=rcw&sig=…
  blockSize: 8 * 1024 * 1024, // the default
});
```

- **Server side:** make a SAS for the blob (a service SAS with `sr=b`, or a user delegation SAS)
  with `c` and `w` permissions, and `r` so a resumed upload can read the uncommitted block list.
  Without `r` the plugin resumes from its own record of the blocks it sent.
- **Options:** `url` (must carry a `sig` parameter, and no `comp`), `blockSize` (default 8 MiB,
  at most 4000 MiB, and at most 50,000 blocks).
- **The blob's properties:** a `Content-Type` in `headers` only labels each request's body, not
  the blob. Pass the blob's own properties as `x-ms-blob-content-type` (and
  `x-ms-blob-cache-control`, `x-ms-blob-content-disposition` and the other `x-ms-blob-*`
  headers): the plugin sends those with the commit only, where Azure sets them.
- **How it goes:** each block is sent with `Put Block` and an id made from the transfer's `id`, the
  file's size and the block size, so the same upload finds its blocks again and another file
  doesn't; a resumed upload reads the blob's uncommitted block list and sends only the blocks it
  lacks; then `Put Block List` commits them. Finished only on its 201. Azure discards uncommitted
  blocks after 7 days.
- **Completion:** if the commit's answer is lost, starting the upload again reports
  `session-closed`: check the blob (e.g. its properties) before starting a new upload. (On iOS
  the system may resend the commit by itself after a dropped connection; Azure answers a repeated
  `Put Block List` of the same blocks with 201, and that answer is taken as the confirmation.)
- **SAS lifetime:** until the commit, including time spent waiting for the network. A user
  delegation SAS lasts at most 7 days; a service SAS as long as you set (keep it short, but longer
  than the upload may take).
- **iOS:** as for `s3-multipart`: one block at a time on screen, every remaining block handed
  over once the app leaves it, with temporary disk to match (or one at a time when the disk is
  short).

### Checked here, and not

The protocols are tested against MinIO and Azurite in Docker (see
[Development](#development)): by JVM and Swift tests, and end to end on the Android emulator (API
35, and API 33 for the pre-Android-14 worker) and the iOS simulator. Not run here: a locked
iPhone, the app swiped away, and real AWS and Azure accounts (presigned URL and SAS expiry against
the real services, S3's 200-with-an-error answers, R2 and B2).

## How it works on each platform

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
- **Stored on the device.** Each transfer's record, including any `headers` you pass, is kept in
  the app's sandbox until `forget()` removes it (`files/background-transfer/transfers.json` on
  Android, `Library/Application Support/BackgroundTransfer/transfers.json` on iOS). Pass
  credentials there only if you must, and forget the transfer once it ends.

## API

<docgen-index>

* [`isAvailable()`](#isavailable)
* [`upload(...)`](#upload)
* [`download(...)`](#download)
* [`cancel(...)`](#cancel)
* [`list()`](#list)
* [`forget(...)`](#forget)
* [`addListener('progress', ...)`](#addlistenerprogress-)
* [`addListener('stateChange', ...)`](#addlistenerstatechange-)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### isAvailable()

```typescript
isAvailable() => Promise<AvailableResult>
```

Whether native background transfers work here. The web says no.

**Returns:** <code>Promise&lt;<a href="#availableresult">AvailableResult</a>&gt;</code>

--------------------


### upload(...)

```typescript
upload(options: UploadOptions) => Promise<TransferEvent>
```

Queue an upload to an upload you have set up on the server (see
`UploadProtocol`). Refused at once if its options are missing or don't
fit together (on Android and iOS also when `partUrls` doesn't match the
file's size). Call it while the app
is on screen: Android only lets a user-initiated job be scheduled then,
and iPhone may defer tasks started from the background.

| Param         | Type                                                    |
| ------------- | ------------------------------------------------------- |
| **`options`** | <code><a href="#uploadoptions">UploadOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#transferevent">TransferEvent</a>&gt;</code>

--------------------


### download(...)

```typescript
download(options: DownloadOptions) => Promise<TransferEvent>
```

Queue a download. Same rules as `upload`.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#downloadoptions">DownloadOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#transferevent">TransferEvent</a>&gt;</code>

--------------------


### cancel(...)

```typescript
cancel(options: { id: string; direction: TransferDirection; }) => Promise<void>
```

Cancel a transfer; its temporary files are removed. Unknown ids are ignored.

| Param         | Type                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------- |
| **`options`** | <code>{ id: string; direction: <a href="#transferdirection">TransferDirection</a>; }</code> |

--------------------


### list()

```typescript
list() => Promise<{ transfers: TransferRecord[]; }>
```

Every transfer the plugin remembers, including ones that ran, finished
or failed while the app was closed. Ask on launch.

**Returns:** <code>Promise&lt;{ transfers: TransferRecord[]; }&gt;</code>

--------------------


### forget(...)

```typescript
forget(options?: { ids?: { id: string; direction: TransferDirection; }[] | undefined; } | undefined) => Promise<void>
```

Forget finished, failed and cancelled transfers (all of them, or the
given ids). Queued, running and interrupted ones are kept.

| Param         | Type                                                                                                     |
| ------------- | -------------------------------------------------------------------------------------------------------- |
| **`options`** | <code>{ ids?: { id: string; direction: <a href="#transferdirection">TransferDirection</a>; }[]; }</code> |

--------------------


### addListener('progress', ...)

```typescript
addListener(eventName: 'progress', listener: (event: TransferEvent) => void) => Promise<PluginListenerHandle>
```

Bytes moved. At most a few events a second per transfer.

| Param           | Type                                                                        |
| --------------- | --------------------------------------------------------------------------- |
| **`eventName`** | <code>'progress'</code>                                                     |
| **`listener`**  | <code>(event: <a href="#transferevent">TransferEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('stateChange', ...)

```typescript
addListener(eventName: 'stateChange', listener: (event: TransferEvent) => void) => Promise<PluginListenerHandle>
```

Any change of `state` (queued, running, interrupted, finished, failed,
cancelled).

| Param           | Type                                                                        |
| --------------- | --------------------------------------------------------------------------- |
| **`eventName`** | <code>'stateChange'</code>                                                  |
| **`listener`**  | <code>(event: <a href="#transferevent">TransferEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

--------------------


### Interfaces


#### AvailableResult

| Prop            | Type                                                     | Description                                                                                                                                                                                                                                                                |
| --------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`available`** | <code>boolean</code>                                     |                                                                                                                                                                                                                                                                            |
| **`mechanism`** | <code>'job' \| 'worker' \| 'urlsession' \| 'none'</code> | How transfers run here: `job` (Android 14+ user-initiated data transfer job), `worker` (WorkManager `dataSync` foreground service below Android 14), `urlsession` (iPhone background `URLSession`) or `none` (web).                                                        |
| **`warning`**   | <code>string</code>                                      | Set when the app is set up so that transfers can't run as they should, e.g. below Android 14 when the manifest doesn't declare WorkManager's foreground service with the `dataSync` type (the worker then stops when the app leaves the screen). For logs, not for people. |


#### TransferEvent

| Prop           | Type                                                      |
| -------------- | --------------------------------------------------------- |
| **`transfer`** | <code><a href="#transferrecord">TransferRecord</a></code> |


#### TransferRecord

What the plugin knows about one transfer.

| Prop             | Type                                                                    | Description                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**         | <code>string</code>                                                     |                                                                                                                                                                                                                                                                                                                                                                                           |
| **`direction`**  | <code><a href="#transferdirection">TransferDirection</a></code>         |                                                                                                                                                                                                                                                                                                                                                                                           |
| **`state`**      | <code><a href="#transferstate">TransferState</a></code>                 |                                                                                                                                                                                                                                                                                                                                                                                           |
| **`url`**        | <code>string</code>                                                     |                                                                                                                                                                                                                                                                                                                                                                                           |
| **`path`**       | <code>string</code>                                                     |                                                                                                                                                                                                                                                                                                                                                                                           |
| **`protocol`**   | <code><a href="#uploadprotocol">UploadProtocol</a></code>               | Uploads: the protocol the session speaks.                                                                                                                                                                                                                                                                                                                                                 |
| **`bytes`**      | <code>number</code>                                                     | Bytes the server holds (upload) or that have landed in `.part` (download). For `s3-multipart` and `azure-blocks`, the parts or blocks stored plus the bytes of the one being sent (so it goes back to the stored parts' end when a part cut off part-way is sent again); for `put`, the bytes sent so far in this attempt. Below `total` until the server has confirmed the whole object. |
| **`total`**      | <code>number</code>                                                     | Total size, or -1 until it is known.                                                                                                                                                                                                                                                                                                                                                      |
| **`reason`**     | <code><a href="#transferfailurereason">TransferFailureReason</a></code> | Set when `state` is `failed`, `cancelled` or `interrupted`.                                                                                                                                                                                                                                                                                                                               |
| **`message`**    | <code>string</code>                                                     | Detail for logs; not for showing to people.                                                                                                                                                                                                                                                                                                                                               |
| **`httpStatus`** | <code>number</code>                                                     | HTTP status of the response that stopped it, when there was one.                                                                                                                                                                                                                                                                                                                          |
| **`updatedAt`**  | <code>number</code>                                                     | Milliseconds since the epoch.                                                                                                                                                                                                                                                                                                                                                             |


#### UploadOptions

| Prop               | Type                                                      | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------ | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`url`**          | <code>string</code>                                       | Where the upload goes, which depends on `protocol`: - `firebase-resumable`: the session URL of an upload you have already started (the `X-Goog-Upload-URL` from its `start`). The plugin asks it how many bytes it holds, sends the rest and finalizes. - `put`: the URL to `PUT` the whole file to. - `s3-multipart`: the presigned `CompleteMultipartUpload` URL (`POST`, with the upload's `uploadId`). - `azure-blocks`: the blob's SAS URL (with its `sig` parameter). The blob's properties go in `headers` as `x-ms-blob-content-type` and the other `x-ms-blob-*` headers: they are sent with the commit only. |
| **`protocol`**     | <code><a href="#uploadprotocol">UploadProtocol</a></code> | The protocol the upload speaks. Default `firebase-resumable`. An unknown value is refused.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **`partUrls`**     | <code>string[]</code>                                     | `s3-multipart` only, and required there: the presigned `UploadPart` URL of every part, part 1 first. There must be exactly as many as the file needs in `partSize` parts (at most 10,000). They must stay valid until the last part is sent.                                                                                                                                                                                                                                                                                                                                                                           |
| **`partSize`**     | <code>number</code>                                       | `s3-multipart` only: the size of every part but the last, in bytes. Default 8 MiB. At least 5 MiB when there is more than one part, at most 5 GiB.                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **`listPartsUrl`** | <code>string</code>                                       | `s3-multipart` only, optional: the presigned `ListParts` URL (`GET`, with the `uploadId`). When it is given, a resumed upload asks the server which parts it holds instead of trusting the plugin's own record, so a part the server lost is sent again and fresh URLs for the same upload carry on where the old ones stopped.                                                                                                                                                                                                                                                                                        |
| **`blockSize`**    | <code>number</code>                                       | `azure-blocks` only: the size of every block but the last, in bytes. Default 8 MiB, at most 4000 MiB, and at most 50,000 blocks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |


#### DownloadOptions

| Prop      | Type                | Description                                                                                                                                                                           |
| --------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`url`** | <code>string</code> | The URL to fetch, already resolved (a Storage download URL carries its own token). Bytes go to `&lt;path&gt;.part` and the file is renamed to `path` only once every byte has landed. |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


### Type Aliases


#### TransferDirection

Which way a transfer moves bytes.

<code>'upload' | 'download'</code>


#### TransferState

Where a transfer is.

- `queued`: waiting its turn (one transfer runs per direction), or waiting
  for the network on Android 14+, where the system restarts it.
- `running`: bytes are moving.
- `interrupted`: stopped by a network drop, the app being swiped away or
  the system, and won't restart by itself. Start it again with the same
  `id` and it carries on from where it stopped.
- `finished`: every byte landed. For a download the file is at `path`.
- `failed`: it can't finish as asked; `reason` says why. Its temporary
  files are gone.
- `cancelled`: `cancel()` was called. Its temporary files are gone.

<code>'queued' | 'running' | 'interrupted' | 'finished' | 'failed' | 'cancelled'</code>


#### UploadProtocol

The upload protocol a transfer speaks. The plugin never signs anything: you
create the upload on the server and hand the plugin URLs that carry their
own authorisation (a session URL, presigned URLs, a SAS URL).

- `firebase-resumable`: a Firebase Storage resumable upload (the
  `X-Goog-Upload-*` protocol: `POST` with `X-Goog-Upload-Command` `query`,
  `upload` and `upload, finalize`). `url` is the session URL.
- `put`: the whole file in one `PUT` to `url`, e.g. an S3 presigned `PUT`
  URL or an Azure blob SAS URL (pass `x-ms-blob-type: BlockBlob` in
  `headers` for Azure). An interrupted upload starts again from the first
  byte. S3 takes at most 5 GB in one `PUT`.
- `s3-multipart`: an S3 (or S3-compatible) multipart upload you have
  created. `partUrls` are the presigned `UploadPart` URLs, part 1 first;
  `url` is the presigned `CompleteMultipartUpload` URL. The plugin sends the
  parts one at a time, keeps each `ETag`, skips the parts already stored when
  it resumes, then completes the upload listing every part.
- `azure-blocks`: an Azure block blob. `url` is the blob's SAS URL with
  write permission (`sp` including `w`, or `c` and `w`). The plugin sends
  blocks with stable ids (`Put Block`), skips the ones in the blob's
  uncommitted block list when it resumes, then commits them
  (`Put Block List`).

<code>'firebase-resumable' | 'put' | 's3-multipart' | 'azure-blocks'</code>


#### TransferFailureReason

Why a transfer stopped without finishing.

- `file-missing`: the upload's file isn't there (or is a directory).
- `disk-full`: no space for a download, or for the remainder copy an
  iPhone upload needs to resume part-way.
- `session-refused`: the server refused the request (HTTP 4xx other than
  the two below), e.g. Firebase Storage security rules refused the upload at finalize (403), or
  a presigned URL or SAS token expired or lacks a permission (403). `message` names the
  request that was refused (a part, a block, the `PUT`, or the commit).
- `session-expired`: the upload session or download URL is gone (HTTP 404
  or 410), e.g. an S3 multipart upload that was aborted, found out while
  sending a part or asking ListParts. Start a new session. (An S3 upload
  found gone only at the completion reports `session-closed`: it may have
  been completed.)
- `session-closed`: the upload can't be confirmed from here. For `firebase-resumable`, the
  session was already closed when the upload started; that isn't proof the object was accepted
  (the Firebase Storage emulator closes a session whose finalize its security rules refused).
  For `s3-multipart` and `azure-blocks`, the request that completes the object was sent in an
  earlier run (or earlier in this one) and its answer never came, so it may or may not have
  been applied. Either way, check the object on the server, and start a new upload if it
  isn't there or is the wrong size.
- `size-mismatch`: the bytes that landed don't add up to the size the
  server or file said.
- `network`: the connection dropped. Used with `interrupted`.
- `stopped-by-system`: the system ended the work (the app was swiped away
  on iPhone, the work was stopped below Android 14). Used with
  `interrupted`.
- `cancelled`: `cancel()` was called.
- `server-error`: the server kept answering 5xx.
- `unknown`: anything else; `message` has the detail.

<code>'file-missing' | 'disk-full' | 'session-refused' | 'session-expired' | 'session-closed' | 'size-mismatch' | 'network' | 'stopped-by-system' | 'cancelled' | 'server-error' | 'unknown'</code>

</docgen-api>

## Development

```bash
npm install
npm run build           # TypeScript, the API section of this README, rollup bundles
npm test                # Vitest: option checks, the web implementation
npm run test:android    # JUnit: chunking, offsets, Range, retries, the queue (JDK 21, Android SDK)
npm run test:ios        # XCTest on macOS: remainder copies, part files, upload outcomes
npm run verify          # all of the above
npm run test:servers    # MinIO and Azurite in Docker; the JUnit and XCTest suites against them
```

### Local storage servers

`test-servers/` holds a Docker Compose file running MinIO (S3, release
`RELEASE.2025-10-15T17-29-55Z`, built from its repository by `minio.Dockerfile` since MinIO no
longer publishes images; the first start builds it) and Azurite (Azure Blob, 3.37.0) with their
well-known development credentials (`minioadmin`/`minioadmin`, and Azurite's `devstoreaccount1`),
and a small harness in front of them (`harness.mjs`, Node's standard library only). Its control
API on port 8790 creates multipart uploads, presigns part URLs and SAS URLs, checks what the
servers stored, and injects faults; the S3 (8791) and Azure (8792) endpoints it hands out go
through a recording proxy that can cut a request part-way, refuse it, swallow its answer, slow it
down or drop every connection for a while. The containers are memory-limited, their images
pinned, and their ports published on `127.0.0.1` only.

`npm run test:servers` needs Docker running, a JDK 21 (`JAVA_HOME`) and the Android SDK
(`ANDROID_HOME`, or `sdk.dir` in `android/local.properties`), and on macOS Swift; it refuses to
start without them. It reruns the JUnit suite even when Gradle holds results from a run without
the servers, and says how many of `ServersTest`'s cases ran. In CI the JUnit suite runs against
the compose servers on Linux; the Swift suite runs on macOS, which has no Docker, against the
same MinIO release built from its repository, Azurite 3.37.0 from npm and the harness.

```bash
npm run servers:up      # start them (docker compose up --wait)
BT_HARNESS=http://localhost:8790 npm run test:android   # the JVM tests that need them run only with BT_HARNESS set
BT_HARNESS=http://localhost:8790 npm run test:ios
npm run servers:down
```

End to end, on one booted Android emulator or iOS simulator at a time (the URLs it hands the
device use `10.0.2.2` on Android and `127.0.0.1` on iOS):

```bash
npm run build && (cd example-app && npm install && npm run build:harness && npx cap sync)
# Android: build and install example-app/android (./gradlew assembleDebug; adb install -r -g …)
# iOS: build the example for the simulator signed ad hoc (CODE_SIGN_IDENTITY=-): an unsigned
#      app is never woken in the background when a task ends
npm run servers:up
npm run test:e2e -- --platform android    # or --platform ios; --only s3-multipart, --case killed
```

It makes the test files on the device (three parts of 5, 5 and 1 MiB), locks the device, sends the
app to the background and kills it, cuts the network, lets URLs expire, refuses or swallows the
commit, and checks the stored objects and what the app reports.

`test:ios` runs `ios/CoreTests`, a package of its own whose sources are symlinks to
`ios/Sources/BackgroundTransferCore` and `ios/Tests/BackgroundTransferCoreTests`, because
Capacitor's Swift package only ships iOS binaries. The Android tests run the uploader and
downloader against a local MockWebServer. `example-app/` is a small app for trying the plugin by
hand; see its README. The upload protocols' tests against real servers are described above,
under [Local storage servers](#local-storage-servers).

Things only a real device can show: locking an iPhone mid-transfer, Low Power Mode, an Android
restart part-way through (the job is persisted), and makers' own battery managers.

## License

[MIT](LICENSE)
