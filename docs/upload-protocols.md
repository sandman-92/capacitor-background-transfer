# Upload protocols

Which protocol to pick, what your server has to set up for each, and how each one resumes.
For the shared basics (install, events, `list()`) see the [README](../README.md).

Every protocol has the same guarantees: it keeps going with the phone locked or the app in the
background or closed; `progress` and `stateChange` events and `list()` behave the same; an upload
is reported `finished` only when the server has confirmed the whole object; a commit whose answer
was lost is never taken as success (`session-closed`); and every stopped upload has a `reason`.
Options that are missing or don't fit together are refused at once by `upload()`, on the web too.
Parts and blocks go one at a time, in order; uploads of different files queue one after another.

The plugin keeps what it has sent (S3 `ETag`s, Azure block ids, whether the commit went) in the
transfer's record, saved as it changes, so a resume survives the app being killed. It never asks
your app for fresh URLs while an upload runs, so make every URL last as long as the upload may
take (below).

## `put`

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

## `s3-multipart`

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

## `azure-blocks`

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

## Checked here, and not

The protocols are tested against MinIO and Azurite in Docker (see
[CONTRIBUTING.md](../CONTRIBUTING.md#local-storage-servers)): by JVM and Swift tests, and end to end on the Android emulator (API
35, and API 33 for the pre-Android-14 worker) and the iOS simulator. Not run here: a locked
iPhone, the app swiped away, and real AWS and Azure accounts (presigned URL and SAS expiry against
the real services, S3's 200-with-an-error answers, R2 and B2).
