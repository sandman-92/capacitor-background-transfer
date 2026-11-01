import type { DownloadOptions, UploadOptions } from './definitions';
import { UPLOAD_LIMITS, UPLOAD_PROTOCOLS } from './definitions';

const HTTP_URL = /^https?:\/\/[^/]+/i;

/**
 * Checks a transfer's options before they cross to the native side, so both
 * platforms refuse the same mistakes with the same words. Returns the
 * options with `path` as a plain absolute path.
 */
export function checkTransferOptions<T extends UploadOptions | DownloadOptions>(options: T): T {
  if (!options || typeof options !== 'object') throw new Error('options are required');
  const { id, url, path, headers } = options;
  if (typeof id !== 'string' || id.trim() === '') throw new Error('id is required');
  if (typeof url !== 'string' || !HTTP_URL.test(url)) throw new Error('url must be an http or https URL');
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
 * Checks an upload's options as `checkTransferOptions` does, its `protocol`
 * (`firebase-resumable` when omitted, refused when unknown) and the options
 * that go with it. The native sides check the same things, and also that
 * `partUrls` fits the file's size, which only they can read.
 */
export function checkUploadOptions(options: UploadOptions): UploadOptions {
  const checked = checkTransferOptions(options);
  const protocol = checked.protocol ?? 'firebase-resumable';
  if (!UPLOAD_PROTOCOLS.includes(protocol)) {
    throw new Error(`protocol must be one of ${UPLOAD_PROTOCOLS.join(', ')}`);
  }
  const { partUrls, partSize, listPartsUrl, blockSize } = checked;
  if (protocol !== 's3-multipart' && (partUrls !== undefined || partSize !== undefined || listPartsUrl !== undefined)) {
    throw new Error('partUrls, partSize and listPartsUrl are only for s3-multipart');
  }
  if (protocol !== 'azure-blocks' && blockSize !== undefined) {
    throw new Error('blockSize is only for azure-blocks');
  }
  if (protocol === 's3-multipart') {
    if (!Array.isArray(partUrls) || partUrls.length === 0) throw new Error('partUrls is required for s3-multipart');
    if (partUrls.length > UPLOAD_LIMITS.s3MaxParts) {
      throw new Error(`partUrls holds more than ${UPLOAD_LIMITS.s3MaxParts} parts`);
    }
    if (!partUrls.every((u) => typeof u === 'string' && HTTP_URL.test(u))) {
      throw new Error('partUrls must be http or https URLs');
    }
    const size = partSize ?? UPLOAD_LIMITS.defaultPartSize;
    if (!Number.isSafeInteger(size) || size < 1 || size > UPLOAD_LIMITS.s3MaxPartSize) {
      throw new Error('partSize must be a whole number of bytes up to 5 GiB');
    }
    if (partUrls.length > 1 && size < UPLOAD_LIMITS.s3MinPartSize) {
      throw new Error('partSize must be at least 5 MiB when there is more than one part');
    }
    if (listPartsUrl !== undefined && (typeof listPartsUrl !== 'string' || !HTTP_URL.test(listPartsUrl))) {
      throw new Error('listPartsUrl must be an http or https URL');
    }
  }
  if (protocol === 'azure-blocks') {
    if (!isSasUrl(checked.url)) throw new Error('url must be a blob SAS URL (with a sig parameter)');
    const size = blockSize ?? UPLOAD_LIMITS.defaultPartSize;
    if (!Number.isSafeInteger(size) || size < 1 || size > UPLOAD_LIMITS.azureMaxBlockSize) {
      throw new Error('blockSize must be a whole number of bytes up to 4000 MiB');
    }
  }
  return { ...checked, protocol };
}

/** A blob URL with a SAS token: a `sig` parameter, and no `comp` (the plugin adds its own). */
function isSasUrl(url: string): boolean {
  const query = url.split('#')[0].split('?')[1];
  if (!query) return false;
  const names = query.split('&').map((p) => decodeURIComponent(p.split('=')[0]));
  const sig = query.split('&').find((p) => p.startsWith('sig='));
  return sig !== undefined && sig.length > 'sig='.length && !names.includes('comp');
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
