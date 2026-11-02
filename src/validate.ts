import type { DownloadOptions, UploadOptions } from './definitions';
import { UPLOAD_PROTOCOLS } from './definitions';

/**
 * Checks a transfer's options before they cross to the native side, so both
 * platforms refuse the same mistakes with the same words. Returns the
 * options with `path` as a plain absolute path.
 */
export function checkTransferOptions<T extends UploadOptions | DownloadOptions>(options: T): T {
  if (!options || typeof options !== 'object') throw new Error('options are required');
  const { id, url, path, headers } = options;
  if (typeof id !== 'string' || id.trim() === '') throw new Error('id is required');
  if (typeof url !== 'string' || !/^https?:\/\/[^/]+/i.test(url)) throw new Error('url must be an http or https URL');
  const plain = toPlainPath(path);
  if (headers !== undefined) {
    if (headers === null || typeof headers !== 'object' || Array.isArray(headers)) {
      throw new Error('headers must be an object of strings');
    }
    for (const [name, value] of Object.entries(headers)) {
      if (typeof value !== 'string') throw new Error(`header ${name} must be a string`);
      if (/[\r\n]/.test(name) || /[\r\n]/.test(value)) throw new Error(`header ${name} must be one line`);
    }
  }
  return { ...options, path: plain };
}

/**
 * Checks an upload's options as `checkTransferOptions` does, and its
 * `protocol`: `firebase-resumable` when omitted, refused when unknown.
 */
export function checkUploadOptions(options: UploadOptions): UploadOptions {
  const checked = checkTransferOptions(options);
  const protocol = checked.protocol ?? 'firebase-resumable';
  if (!UPLOAD_PROTOCOLS.includes(protocol)) {
    throw new Error(`protocol must be one of ${UPLOAD_PROTOCOLS.join(', ')}`);
  }
  return { ...checked, protocol };
}

/** `file:///a/b%20c.mp4` → `/a/b c.mp4`; absolute paths pass through. */
export function toPlainPath(path: unknown): string {
  if (typeof path !== 'string' || path === '') throw new Error('path is required');
  let plain = path;
  if (plain.startsWith('file://')) {
    plain = decodeURIComponent(plain.slice('file://'.length));
  }
  if (!plain.startsWith('/')) throw new Error('path must be absolute or a file:// URI');
  if (plain.endsWith('/')) throw new Error('path must name a file');
  if (plain.split('/').includes('..')) throw new Error('path must not contain ..');
  return plain;
}
