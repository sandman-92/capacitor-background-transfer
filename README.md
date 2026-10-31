# capacitor-background-transfer

Background uploads and downloads for Capacitor 7 on Android and iOS. A transfer keeps going
while the phone is locked or the app is in the background or closed, and picks up where it
stopped after a dropped connection.

- **Upload** to a resumable upload session of Google Cloud Storage or Firebase Storage (the
  `X-Goog-Upload-*` protocol) that your app has already started. The plugin asks the session how
  many bytes it holds and sends the rest. It sends no `Authorization` header unless you pass one
  in `headers`.
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

// Start the resumable upload session yourself (it is where your credentials go), then hand
// its URL to the plugin.
await BackgroundTransfer.upload({
  id: 'clip-42',
  url: sessionUrl, // the X-Goog-Upload-URL from the session's start
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
it again from where it stopped (an upload asks the server; a download uses its `.part` file).
Starting one that is `queued` or `running` changes nothing. Starting an upload with the `id` of a
`finished` one finds its session closed and reports `failed` (`session-closed`): start a new
session to send the file again.

### Why a transfer stopped

`reason` on a stopped transfer is one of:

| Reason | Meaning |
|---|---|
| `file-missing` | The file to upload isn't there |
| `disk-full` | No space for a download, or for the remainder copy an iOS upload needs to resume part-way |
| `session-refused` | HTTP 4xx, e.g. 403 when Firebase Storage security rules refuse the upload at finalize. Start a new session |
| `session-expired` | HTTP 404 or 410: the session or URL is gone. Start a new session |
| `session-closed` | The session was already closed when the upload started. That isn't proof the object was accepted (the Firebase Storage emulator closes a session whose finalize its rules refused): check the object's metadata |
| `size-mismatch` | The bytes that landed don't add up to the expected size |
| `network` | The connection dropped (with `interrupted`) |
| `stopped-by-system` | The system ended the work, or the user did from the Task Manager or by swiping the app away (with `interrupted`) |
| `cancelled` | `cancel()` was called |
| `server-error` | The server kept answering 5xx |
| `unknown` | Anything else; `message` has the detail |

## How it works on each platform

| | Android 14+ (API 34+) | Android 6 to 13 | iOS |
|---|---|---|---|
| Mechanism | A user-initiated data transfer job, one per direction | A WorkManager worker promoted to a `dataSync` foreground service, one per direction | A background `URLSession` per direction, one connection per host |
| Upload | 4 MiB chunks read from the file in place | Same | The whole file in one request when the server holds nothing; otherwise a temporary copy of the remaining bytes (a background session can't send a byte range), deleted when the task ends |
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

Queue an upload to an existing resumable session. Call it while the app
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

| Prop             | Type                                                                    | Description                                                                |
| ---------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **`id`**         | <code>string</code>                                                     |                                                                            |
| **`direction`**  | <code><a href="#transferdirection">TransferDirection</a></code>         |                                                                            |
| **`state`**      | <code><a href="#transferstate">TransferState</a></code>                 |                                                                            |
| **`url`**        | <code>string</code>                                                     |                                                                            |
| **`path`**       | <code>string</code>                                                     |                                                                            |
| **`bytes`**      | <code>number</code>                                                     | Bytes the server holds (upload) or that have landed in `.part` (download). |
| **`total`**      | <code>number</code>                                                     | Total size, or -1 until it is known.                                       |
| **`reason`**     | <code><a href="#transferfailurereason">TransferFailureReason</a></code> | Set when `state` is `failed`, `cancelled` or `interrupted`.                |
| **`message`**    | <code>string</code>                                                     | Detail for logs; not for showing to people.                                |
| **`httpStatus`** | <code>number</code>                                                     | HTTP status of the response that stopped it, when there was one.           |
| **`updatedAt`**  | <code>number</code>                                                     | Milliseconds since the epoch.                                              |


#### UploadOptions

| Prop      | Type                | Description                                                                                                                                                                            |
| --------- | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`url`** | <code>string</code> | The resumable session URL (`X-Goog-Upload-URL`) of an upload you have already started with the user's token. The plugin asks it how many bytes it holds, sends the rest and finalizes. |


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


#### TransferFailureReason

Why a transfer stopped without finishing.

- `file-missing`: the upload's file isn't there (or is a directory).
- `disk-full`: no space for a download, or for the remainder copy an
  iPhone upload needs to resume part-way.
- `session-refused`: the server refused the request (HTTP 4xx other than
  the two below), e.g. Firebase Storage security rules refused the upload at finalize (403).
- `session-expired`: the upload session or download URL is gone (HTTP 404
  or 410). Start a new session.
- `session-closed`: the upload session was already closed when the upload started. That isn't
  proof the object was accepted (the Firebase Storage emulator closes a session whose finalize its security rules
  refused): check the object's metadata with the user's token, and start a new session if it
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
npm run test:android    # JUnit: chunking, offsets, Range, retries, the queue (needs JDK 21 and the Android SDK)
npm run test:ios        # XCTest on macOS: remainder copies, part files, upload outcomes
npm run verify          # all of the above
```

`test:ios` runs `ios/CoreTests`, a package of its own whose sources are symlinks to
`ios/Sources/BackgroundTransferCore` and `ios/Tests/BackgroundTransferCoreTests`, because
Capacitor's Swift package only ships iOS binaries. The Android tests run the uploader and
downloader against a local MockWebServer. `example-app/` is a small app for trying the plugin by
hand; see its README.

Things only a real device can show: locking an iPhone mid-transfer, Low Power Mode, an Android
restart part-way through (the job is persisted), and makers' own battery managers.

## License

[MIT](LICENSE)
