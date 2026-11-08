import type { PluginListenerHandle } from '@capacitor/core';

/** Which way a transfer moves bytes. */
export type TransferDirection = 'upload' | 'download';

/**
 * Where a transfer is.
 *
 * - `queued`: waiting its turn (one transfer runs per direction), or waiting
 *   for the network on Android 14+, where the system restarts it.
 * - `running`: bytes are moving.
 * - `interrupted`: stopped by a network drop, the app being swiped away or
 *   the system, and won't restart by itself. Start it again with the same
 *   `id` and it carries on from where it stopped.
 * - `finished`: every byte landed. For a download the file is at `path`.
 * - `failed`: it can't finish as asked; `reason` says why. Its temporary
 *   files are gone.
 * - `cancelled`: `cancel()` was called. Its temporary files are gone.
 */
export type TransferState = 'queued' | 'running' | 'interrupted' | 'finished' | 'failed' | 'cancelled';

/**
 * Why a transfer stopped without finishing.
 *
 * - `file-missing`: the upload's file isn't there (or is a directory).
 * - `disk-full`: no space for a download, or for the remainder copy an
 *   iPhone upload needs to resume part-way.
 * - `session-refused`: the server refused the request (HTTP 4xx other than
 *   the two below), e.g. Firebase Storage security rules refused the upload at finalize (403), or
 *   a presigned URL or SAS token expired or lacks a permission (403). `message` names the
 *   request that was refused (a part, a block, the `PUT`, or the commit).
 * - `session-expired`: the upload session or download URL is gone (HTTP 404
 *   or 410), e.g. an S3 multipart upload that was aborted, found out while
 *   sending a part or asking ListParts. Start a new session. (An S3 upload
 *   found gone only at the completion reports `session-closed`: it may have
 *   been completed.)
 * - `session-closed`: the upload can't be confirmed from here. For `firebase-resumable`, the
 *   session was already closed when the upload started; that isn't proof the object was accepted
 *   (the Firebase Storage emulator closes a session whose finalize its security rules refused).
 *   For `s3-multipart` and `azure-blocks`, the request that completes the object was sent in an
 *   earlier run (or earlier in this one) and its answer never came, so it may or may not have
 *   been applied. Either way, check the object on the server, and start a new upload if it
 *   isn't there or is the wrong size.
 * - `size-mismatch`: the bytes that landed don't add up to the size the
 *   server or file said.
 * - `network`: the connection dropped. Used with `interrupted`.
 * - `stopped-by-system`: the system ended the work (the app was swiped away
 *   on iPhone, the work was stopped below Android 14). Used with
 *   `interrupted`.
 * - `cancelled`: `cancel()` was called.
 * - `server-error`: the server kept answering 5xx.
 * - `unknown`: anything else; `message` has the detail.
 */
export type TransferFailureReason =
  | 'file-missing'
  | 'disk-full'
  | 'session-refused'
  | 'session-expired'
  | 'session-closed'
  | 'size-mismatch'
  | 'network'
  | 'stopped-by-system'
  | 'cancelled'
  | 'server-error'
  | 'unknown';

/** What Android shows while a transfer runs. Ignored on iPhone. */
export interface TransferNotification {
  /** Notification channel id. Default `background-transfer`. */
  channelId?: string;
  /** The channel's name in system settings, used when the channel is first created. Default `Transfers`. */
  channelName?: string;
  /** Default `Uploading` or `Downloading`. */
  title?: string;
  /** Optional second line. */
  text?: string;
}

interface TransferOptionsBase {
  /**
   * Your id for the transfer, unique per direction. Starting a transfer with
   * the id of one that is `interrupted`, `failed` or `cancelled` starts it
   * again (an upload asks the server for its offset; a download resumes from
   * its `.part` file). Starting one that is `queued` or `running` changes
   * nothing and returns its current record. Starting an upload with the id
   * of a `finished` one reports `failed` (`session-closed`) for every
   * protocol but `put`: its session is closed, so start a new session to send
   * the file again. A `put` sends the whole file again.
   */
  id: string;
  /**
   * Absolute path or `file://` URI of the local file: the file to send, or
   * where the downloaded file goes.
   */
  path: string;
  /**
   * Extra request headers sent on every request of this transfer (for an
   * upload in parts: every part, block, query and the commit). None by
   * default: an upload sends no `Authorization` header unless you pass one.
   */
  headers?: Record<string, string>;
  /** Android only. */
  notification?: TransferNotification;
}

/**
 * The upload protocol a transfer speaks. The plugin never signs anything: you
 * create the upload on the server and hand the plugin URLs that carry their
 * own authorisation (a session URL, presigned URLs, a SAS URL).
 *
 * - `firebase-resumable`: a Firebase Storage resumable upload (the
 *   `X-Goog-Upload-*` protocol: `POST` with `X-Goog-Upload-Command` `query`,
 *   `upload` and `upload, finalize`). `url` is the session URL.
 * - `put`: the whole file in one `PUT` to `url`, e.g. an S3 presigned `PUT`
 *   URL or an Azure blob SAS URL (pass `x-ms-blob-type: BlockBlob` in
 *   `headers` for Azure). An interrupted upload starts again from the first
 *   byte. S3 takes at most 5 GB in one `PUT`.
 * - `s3-multipart`: an S3 (or S3-compatible) multipart upload you have
 *   created. `partUrls` are the presigned `UploadPart` URLs, part 1 first;
 *   `url` is the presigned `CompleteMultipartUpload` URL. The plugin sends the
 *   parts one at a time, keeps each `ETag`, skips the parts already stored when
 *   it resumes, then completes the upload listing every part.
 * - `azure-blocks`: an Azure block blob. `url` is the blob's SAS URL with
 *   write permission (`sp` including `w`, or `c` and `w`). The plugin sends
 *   blocks with stable ids (`Put Block`), skips the ones in the blob's
 *   uncommitted block list when it resumes, then commits them
 *   (`Put Block List`).
 */
export type UploadProtocol = 'firebase-resumable' | 'put' | 's3-multipart' | 'azure-blocks';

/** The protocols this version knows. */
export const UPLOAD_PROTOCOLS: readonly UploadProtocol[] = [
  'firebase-resumable',
  'put',
  's3-multipart',
  'azure-blocks',
];

const MIB = 1024 * 1024;

/** The limits the plugin checks for `s3-multipart` and `azure-blocks`. */
export const UPLOAD_LIMITS = {
  /** Default `partSize` and `blockSize`: 8 MiB. */
  defaultPartSize: 8 * MIB,
  /** S3's smallest part, other than the last: 5 MiB. */
  s3MinPartSize: 5 * MIB,
  /** S3's largest part: 5 GiB. */
  s3MaxPartSize: 5 * 1024 * MIB,
  /** S3's most parts in one upload. */
  s3MaxParts: 10000,
  /** Azure's largest block: 4000 MiB. */
  azureMaxBlockSize: 4000 * MIB,
  /** Azure's most blocks in one blob. */
  azureMaxBlocks: 50000,
} as const;

export interface UploadOptions extends TransferOptionsBase {
  /**
   * Where the upload goes, which depends on `protocol`:
   *
   * - `firebase-resumable`: the session URL of an upload you have already
   *   started (the `X-Goog-Upload-URL` from its `start`). The plugin asks it
   *   how many bytes it holds, sends the rest and finalizes.
   * - `put`: the URL to `PUT` the whole file to.
   * - `s3-multipart`: the presigned `CompleteMultipartUpload` URL (`POST`,
   *   with the upload's `uploadId`).
   * - `azure-blocks`: the blob's SAS URL (with its `sig` parameter). The
   *   blob's properties go in `headers` as `x-ms-blob-content-type` and the
   *   other `x-ms-blob-*` headers: they are sent with the commit only.
   */
  url: string;
  /**
   * The protocol the upload speaks. Default `firebase-resumable`. An
   * unknown value is refused.
   */
  protocol?: UploadProtocol;
  /**
   * `s3-multipart` only, and required there: the presigned `UploadPart` URL
   * of every part, part 1 first. There must be exactly as many as the file
   * needs in `partSize` parts (at most 10,000). They must stay valid until
   * the last part is sent.
   */
  partUrls?: string[];
  /**
   * `s3-multipart` only: the size of every part but the last, in bytes.
   * Default 8 MiB. At least 5 MiB when there is more than one part, at most
   * 5 GiB.
   */
  partSize?: number;
  /**
   * `s3-multipart` only, optional: the presigned `ListParts` URL (`GET`, with
   * the `uploadId`). When it is given, a resumed upload asks the server which
   * parts it holds instead of trusting the plugin's own record, so a part
   * the server lost is sent again and fresh URLs for the same upload carry on
   * where the old ones stopped.
   */
  listPartsUrl?: string;
  /**
   * `azure-blocks` only: the size of every block but the last, in bytes.
   * Default 8 MiB, at most 4000 MiB, and at most 50,000 blocks.
   */
  blockSize?: number;
}

export interface DownloadOptions extends TransferOptionsBase {
  /**
   * The URL to fetch, already resolved (a Storage download URL carries its
   * own token). Bytes go to `<path>.part` and the file is renamed to `path`
   * only once every byte has landed.
   */
  url: string;
}

/** What the plugin knows about one transfer. */
export interface TransferRecord {
  id: string;
  direction: TransferDirection;
  state: TransferState;
  url: string;
  path: string;
  /** Uploads: the protocol the session speaks. */
  protocol?: UploadProtocol;
  /**
   * Bytes the server holds (upload) or that have landed in `.part`
   * (download). For `s3-multipart` and `azure-blocks`, the parts or blocks
   * stored plus the bytes of the one being sent (so it goes back to the
   * stored parts' end when a part cut off part-way is sent again); for `put`,
   * the bytes sent so far in this attempt. Below `total` until the server has
   * confirmed the whole object.
   */
  bytes: number;
  /** Total size, or -1 until it is known. */
  total: number;
  /** Set when `state` is `failed`, `cancelled` or `interrupted`. */
  reason?: TransferFailureReason;
  /** Detail for logs; not for showing to people. */
  message?: string;
  /** HTTP status of the response that stopped it, when there was one. */
  httpStatus?: number;
  /** Milliseconds since the epoch. */
  updatedAt: number;
}

export interface AvailableResult {
  available: boolean;
  /**
   * How transfers run here: `job` (Android 14+ user-initiated data transfer
   * job), `worker` (WorkManager `dataSync` foreground service below Android
   * 14), `urlsession` (iPhone background `URLSession`) or `none` (web).
   */
  mechanism: 'job' | 'worker' | 'urlsession' | 'none';
  /**
   * Set when the app is set up so that transfers can't run as they should, e.g. below Android 14
   * when the manifest doesn't declare WorkManager's foreground service with the `dataSync` type
   * (the worker then stops when the app leaves the screen). For logs, not for people.
   */
  warning?: string;
}

export interface TransferEvent {
  transfer: TransferRecord;
}

export interface BackgroundTransferPlugin {
  /** Whether native background transfers work here. The web says no. */
  isAvailable(): Promise<AvailableResult>;

  /**
   * Queue an upload to an upload you have set up on the server (see
   * `UploadProtocol`). Refused at once if its options are missing or don't
   * fit together (on Android and iOS also when `partUrls` doesn't match the
   * file's size). Call it while the app
   * is on screen: Android only lets a user-initiated job be scheduled then,
   * and iPhone may defer tasks started from the background.
   */
  upload(options: UploadOptions): Promise<TransferEvent>;

  /** Queue a download. Same rules as `upload`. */
  download(options: DownloadOptions): Promise<TransferEvent>;

  /** Cancel a transfer; its temporary files are removed. Unknown ids are ignored. */
  cancel(options: { id: string; direction: TransferDirection }): Promise<void>;

  /**
   * Every transfer the plugin remembers, including ones that ran, finished
   * or failed while the app was closed. Ask on launch.
   */
  list(): Promise<{ transfers: TransferRecord[] }>;

  /**
   * Forget finished, failed and cancelled transfers (all of them, or the
   * given ids). Queued, running and interrupted ones are kept.
   */
  forget(options?: { ids?: { id: string; direction: TransferDirection }[] }): Promise<void>;

  /** Bytes moved. At most a few events a second per transfer. */
  addListener(eventName: 'progress', listener: (event: TransferEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Any change of `state` (queued, running, interrupted, finished, failed,
   * cancelled).
   */
  addListener(eventName: 'stateChange', listener: (event: TransferEvent) => void): Promise<PluginListenerHandle>;

  removeAllListeners(): Promise<void>;
}
