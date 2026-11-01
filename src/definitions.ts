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
 *   the two below), e.g. Firebase Storage security rules refused the upload at finalize (403).
 * - `session-expired`: the upload session or download URL is gone (HTTP 404
 *   or 410). Start a new session.
 * - `session-closed`: the upload session was already closed when the upload started. That isn't
 *   proof the object was accepted (the Firebase Storage emulator closes a session whose finalize its security rules
 *   refused): check the object's metadata with the user's token, and start a new session if it
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
   * of a `finished` one reports `failed` (`session-closed`): its session is
   * closed, so start a new session to send the file again.
   */
  id: string;
  /**
   * Absolute path or `file://` URI of the local file: the file to send, or
   * where the downloaded file goes.
   */
  path: string;
  /**
   * Extra request headers sent on every request of this transfer. None by
   * default: an upload sends no `Authorization` header unless you pass one.
   */
  headers?: Record<string, string>;
  /** Android only. */
  notification?: TransferNotification;
}

/**
 * The upload protocol a transfer speaks.
 *
 * - `firebase-resumable`: a Firebase Storage resumable upload (the
 *   `X-Goog-Upload-*` protocol: `POST` with `X-Goog-Upload-Command` `query`,
 *   `upload` and `upload, finalize`).
 *
 * The only one so far; others may be added without changing the interface.
 */
export type UploadProtocol = 'firebase-resumable';

/** The protocols this version knows. */
export const UPLOAD_PROTOCOLS: readonly UploadProtocol[] = ['firebase-resumable'];

export interface UploadOptions extends TransferOptionsBase {
  /**
   * The session URL of an upload you have already started (for
   * `firebase-resumable`, the `X-Goog-Upload-URL` from its `start`). The
   * plugin asks it how many bytes it holds, sends the rest and finalizes.
   */
  url: string;
  /**
   * The protocol the session speaks. Default `firebase-resumable`. An
   * unknown value is refused.
   */
  protocol?: UploadProtocol;
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
  /** Bytes the server holds (upload) or that have landed in `.part` (download). */
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
   * Queue an upload to an existing resumable session. Call it while the app
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
