# capacitor-background-transfer

**Uploads and downloads that keep going when your Capacitor app doesn't.**

[![npm](https://img.shields.io/npm/v/capacitor-background-transfer.svg)](https://www.npmjs.com/package/capacitor-background-transfer)
[![CI](https://github.com/sandman-92/capacitor-background-transfer/actions/workflows/ci.yml/badge.svg)](https://github.com/sandman-92/capacitor-background-transfer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Capacitor 7](https://img.shields.io/badge/Capacitor-7-119eff.svg)
![Android 6+](https://img.shields.io/badge/Android-6.0%2B-3ddc84.svg)
![iOS 15+](https://img.shields.io/badge/iOS-15%2B-lightgrey.svg)

[Install](#install) · [npm](https://www.npmjs.com/package/capacitor-background-transfer) ·
[Quick start](#quick-start) · [Upload protocols](docs/upload-protocols.md) · [How it works](docs/how-it-works.md) · [API](#api) · [Changelog](CHANGELOG.md)

A phone suspends an app soon after it leaves the screen, and an upload made with `fetch` or XHR
from the web view is suspended with it. For a large file on a mobile network, the user has to keep
the app open and the screen on until the last byte arrives.

This plugin hands the transfer to the operating system instead: a user-initiated data transfer job
on Android 14 and later, a foreground service below that, and a background `URLSession` on iOS.
The user can lock the phone or switch apps, the app can be closed, the connection can drop, and
the file still arrives. After an interruption it picks up from where it stopped instead of
starting again.

## Highlights

- **Keeps going in the background.** It carries on with the phone locked, the app in the
  background or closed, and through Doze. On iOS the system's transfer daemon keeps it running
  after the app's process has ended.
- **Resumes instead of restarting.** An upload asks the server how much it already holds and
  sends the rest. A download resumes with a `Range` request.
- **Four upload protocols.** Firebase Storage resumable uploads, Amazon S3 multipart uploads
  (and S3-compatible services), Azure Blob block blobs, and a plain `PUT` to any presigned or
  SAS URL. Downloads work with any URL.
- **No cloud keys in the plugin.** Your app or server starts the upload and hands over its URL,
  presigned where the protocol needs it. The plugin never signs a request.
- **Truthful outcomes.** A transfer is reported finished only once every byte is confirmed, and
  a download appears at its path only when it is complete. Every stopped transfer has a `reason`.
  After a relaunch, `list()` tells you what finished or failed while the app was closed.
- **A small API.** `upload`, `download`, `cancel`, `list`, `forget` and two events, fully typed.
  On the web it reports itself unavailable, so your app can fall back to its own code there.

## Status

Early but complete: version 0.x, so the API may still change before 1.0. The JVM and Swift tests
run in CI, including against local MinIO (S3) and Azurite (Azure) servers. The upload protocols
also run end to end on the Android emulator and the iOS simulator, with the app killed, the
network cut and URLs left to expire. Real AWS and Azure accounts, a locked iPhone and makers' own
battery managers haven't been tested yet (see [what's checked](docs/upload-protocols.md#checked-here-and-not)).
Reports from real apps are very welcome.

## Install

The plugin is published on npm as
[`capacitor-background-transfer`](https://www.npmjs.com/package/capacitor-background-transfer).

```bash
npm install capacitor-background-transfer
npx cap sync
```

| Platform | Supported |
|---|---|
| Capacitor | 7 |
| Android | 6.0 (API 23) and later |
| iOS | 15 and later, with Swift Package Manager or CocoaPods |
| Web | No: `isAvailable()` returns `{ available: false }` |

Each platform needs one small change to your app:

### Android: one manifest entry

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

### iOS: one `AppDelegate` method

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

### Where files may be

A transfer's `path` must be inside the app's own storage, and the native side checks this after
resolving symbolic links, whatever called it: on Android the app's files, no-backup files and
cache directories, internal and external (`Directory.Data`, `Directory.Cache` and
`Directory.External` of the Filesystem plugin); on iOS Documents, Library and tmp (every
Filesystem directory). Paths with `..`, paths into the plugin's own storage, and a download onto a
symbolic link are refused. An app that keeps files elsewhere (an app group container, say) lists
the extra roots in the plugin's configuration, never from JavaScript:

```ts
// capacitor.config.ts
plugins: {
  BackgroundTransfer: {
    allowedRoots: ['/private/var/mobile/Containers/Shared/AppGroup/…/Videos'],
  },
},
```

## Quick start

```ts
import { BackgroundTransfer } from 'capacitor-background-transfer';

const { available } = await BackgroundTransfer.isAvailable();

await BackgroundTransfer.addListener('progress', ({ transfer }) => {
  console.log(`${transfer.id}: ${transfer.bytes} of ${transfer.total} bytes`);
});
await BackgroundTransfer.addListener('stateChange', ({ transfer }) => {
  // queued, running, interrupted, finished, failed or cancelled
});

// Upload: your server (or the Firebase SDK) starts the upload, then the plugin sends the file.
await BackgroundTransfer.upload({
  id: 'clip-42',
  path: fileUri, // an absolute path or file:// URI, e.g. from Filesystem.getUri()
  url: sessionUrl, // here, the X-Goog-Upload-URL of a Firebase Storage resumable upload
  notification: { title: 'Uploading', text: 'clip-42.mp4' }, // Android only
});

// Download any URL to a file.
await BackgroundTransfer.download({ id: 'clip-42', url: downloadUrl, path: destinationUri });

// At launch: what happened while the app was closed.
const { transfers } = await BackgroundTransfer.list();
```

Two rules to know:

- **Start transfers while the app is on screen.** Android only lets a user-initiated job be
  scheduled then, and iOS may defer work started from the background.
- **The `id` is how you resume.** Calling `upload()` or `download()` again with the `id` of an
  `interrupted`, `failed` or `cancelled` transfer carries on from where it stopped. See
  [Starting a transfer again](docs/how-it-works.md#starting-a-transfer-again).

## Upload protocols

Pick one with the `protocol` option. Every protocol behaves the same way in the background and
reports through the same events.

| `protocol` | Uploads to | An interrupted upload resumes from |
|---|---|---|
| `firebase-resumable` (default) | A Firebase Storage resumable upload session | What the session holds |
| `s3-multipart` | An Amazon S3 multipart upload with presigned part URLs. S3-compatible services are expected to work; only MinIO is tested | The parts S3 holds, or the plugin's own record of them |
| `azure-blocks` | An Azure Blob Storage block blob through one SAS URL | The blocks Azure holds |
| `put` | Any URL that takes the whole file in one `PUT`, e.g. an S3 presigned `PutObject` URL or an Azure blob SAS URL | The start: there is nothing to resume from |

[docs/upload-protocols.md](docs/upload-protocols.md) has the server-side setup, the options, URL
lifetimes and a code example for each one.

## How it works

| | Android 14+ | Android 6 to 13 | iOS |
|---|---|---|---|
| Runs as | A user-initiated data transfer job | A WorkManager worker in a `dataSync` foreground service | A background `URLSession` |
| Locked, in the background or removed from Recents | Carries on | Carries on | Carries on, also after the app's process ends |
| Network drops while the app is off screen | Waits, then resumes by itself | Reported `interrupted`, so start it again at the next launch | The system often retries; otherwise reported `interrupted` |
| Notification | Shows progress | Shows progress (the service's notification) | None |

One transfer runs per direction at a time, and the rest wait in a queue.
[docs/how-it-works.md](docs/how-it-works.md) covers each platform in detail, including
system stops, ordering, iOS resends, what is stored on the device, and every failure `reason`.

## FAQ

**Why not just use `fetch` from the web view?** The web view's requests run in your app's process,
which the system suspends soon after the app leaves the screen. This plugin hands the transfer to
a part of the system that keeps running.

**What happens if the user swipes the app away or force-stops it?** The system ends the
transfer on purpose. It is reported `interrupted` (on iOS at the next launch), and starting it
again with the same `id` carries on from where it stopped.

**Are there limits?** Below Android 14, the system allows a `dataSync` foreground service six
hours a day. iOS may defer transfers started while the app is in the background. On iOS, resuming
an upload part-way needs temporary disk space for a copy of the bytes still to send.

**Where do my headers go?** To the host in the URL, and nowhere else: a redirect to another host
is refused rather than followed (on iOS, where the system follows it by itself, the transfer is
reported `session-refused` when it ends). While a transfer is queued or running its record,
`headers` included, is kept in the app's sandbox, in storage that is left out of device backups;
the headers are dropped the moment it finishes, fails, is cancelled or is interrupted (a restart
brings its own). The URL stays in the record until you call `forget()`, so presigned URLs with a
short life are the better route for credentials.

## Feedback and contributing

Found a bug or want a feature? [Open an issue](https://github.com/sandman-92/capacitor-background-transfer/issues).
Pull requests are welcome too. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build the plugin,
run its tests (including the local S3 and Azure servers) and try a change on a device with the
[example app](example-app/). To report a security problem privately, see [SECURITY.md](SECURITY.md).

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

## License

[MIT](LICENSE). Made by [sandman-92](https://github.com/sandman-92).
