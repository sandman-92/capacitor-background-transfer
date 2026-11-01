import { describe, expect, it } from 'vitest';

import { checkTransferOptions, checkUploadOptions, toPlainPath } from '../src/validate';

const ok = { id: 'v1', url: 'https://firebasestorage.googleapis.com/upload?x=1', path: '/data/v1.mp4' };

describe('toPlainPath', () => {
  it('passes an absolute path through', () => {
    expect(toPlainPath('/data/user/0/app/files/v1.mp4')).toBe('/data/user/0/app/files/v1.mp4');
  });

  it('turns a file:// URI into a path and decodes it', () => {
    expect(toPlainPath('file:///var/mobile/Documents/my%20clip.mov')).toBe('/var/mobile/Documents/my clip.mov');
  });

  it.each([
    ['', 'path is required'],
    [undefined, 'path is required'],
    ['videos/v1.mp4', 'path must be absolute or a file:// URI'],
    ['content://media/1', 'path must be absolute or a file:// URI'],
    ['/data/videos/', 'path must name a file'],
    ['/data/../etc/passwd', 'path must not contain ..'],
  ])('refuses %j', (path, message) => {
    expect(() => toPlainPath(path)).toThrow(message);
  });
});

describe('checkTransferOptions', () => {
  it('returns the options with a plain path', () => {
    expect(checkTransferOptions({ ...ok, path: 'file:///data/v1.mp4', headers: { 'X-A': 'b' } })).toEqual({
      ...ok,
      headers: { 'X-A': 'b' },
    });
  });

  it('does not change the caller’s object', () => {
    const options = { ...ok, path: 'file:///data/v1.mp4' };
    checkTransferOptions(options);
    expect(options.path).toBe('file:///data/v1.mp4');
  });

  it('accepts http for local test servers', () => {
    expect(checkTransferOptions({ ...ok, url: 'http://10.0.2.2:9199/upload/x' }).url).toBe(
      'http://10.0.2.2:9199/upload/x',
    );
  });

  it.each([
    [{ ...ok, id: '' }, 'id is required'],
    [{ ...ok, id: '   ' }, 'id is required'],
    [{ ...ok, url: 'ftp://host/x' }, 'url must be an http or https URL'],
    [{ ...ok, url: '/relative' }, 'url must be an http or https URL'],
    [{ ...ok, path: 'relative.mp4' }, 'path must be absolute'],
    [{ ...ok, headers: ['a'] }, 'headers must be an object of strings'],
    [{ ...ok, headers: { 'X-N': 5 } }, 'header X-N must be a string'],
    [{ ...ok, headers: { 'X-Bad': 'a\r\nInjected: 1' } }, 'header X-Bad must be one line'],
  ])('refuses %j', (options, message) => {
    expect(() => checkTransferOptions(options as never)).toThrow(message);
  });

  it('refuses missing options', () => {
    expect(() => checkTransferOptions(undefined as never)).toThrow('options are required');
  });
});

describe('checkUploadOptions', () => {
  const MIB = 1024 * 1024;
  const file = { id: 'u1', path: '/data/u1.bin' };
  const parts = ['https://s3.example.com/b/k?partNumber=1&uploadId=x', 'https://s3.example.com/b/k?partNumber=2&uploadId=x'];
  const s3 = { ...file, protocol: 's3-multipart' as const, url: 'https://s3.example.com/b/k?uploadId=x', partUrls: parts };
  const sas = 'https://acct.blob.core.windows.net/c/blob.bin?sv=2021-08-06&sr=b&sp=cw&se=2030-01-01&sig=abc%3D';
  const azure = { ...file, protocol: 'azure-blocks' as const, url: sas };

  it('defaults the protocol and leaves firebase-resumable as it was', () => {
    expect(checkUploadOptions({ ...file, url: 'https://x/u' })).toEqual({ ...file, url: 'https://x/u', protocol: 'firebase-resumable' });
  });

  it.each(['put', 's3-multipart', 'azure-blocks'] as const)('accepts a well-formed %s upload', (protocol) => {
    const options = protocol === 's3-multipart' ? s3 : protocol === 'azure-blocks' ? azure : { ...file, protocol, url: 'https://x/put' };
    expect(checkUploadOptions(options).protocol).toBe(protocol);
  });

  it('accepts a part size of 5 MiB, a single part of any size, a ListParts URL and a block size', () => {
    expect(checkUploadOptions({ ...s3, partSize: 5 * MIB, listPartsUrl: 'https://s3.example.com/b/k?uploadId=x' }).partSize).toBe(5 * MIB);
    expect(checkUploadOptions({ ...s3, partUrls: [parts[0]], partSize: 1000 }).partSize).toBe(1000);
    expect(checkUploadOptions({ ...azure, blockSize: 1024 }).blockSize).toBe(1024);
  });

  it.each([
    [{ ...file, url: 'https://x/u', protocol: 'gcs' }, 'protocol must be one of firebase-resumable, put, s3-multipart, azure-blocks'],
    [{ ...s3, partUrls: undefined }, 'partUrls is required for s3-multipart'],
    [{ ...s3, partUrls: [] }, 'partUrls is required for s3-multipart'],
    [{ ...s3, partUrls: 'https://x' }, 'partUrls is required for s3-multipart'],
    [{ ...s3, partUrls: [parts[0], 'ftp://x/2'] }, 'partUrls must be http or https URLs'],
    [{ ...s3, partUrls: [parts[0], 7] }, 'partUrls must be http or https URLs'],
    [{ ...s3, partUrls: new Array(10001).fill(parts[0]) }, 'partUrls holds more than 10000 parts'],
    [{ ...s3, partSize: 5 * MIB - 1 }, 'partSize must be at least 5 MiB when there is more than one part'],
    [{ ...s3, partSize: 0 }, 'partSize must be a whole number of bytes up to 5 GiB'],
    [{ ...s3, partSize: 5.5 * MIB + 0.5 }, 'partSize must be a whole number of bytes up to 5 GiB'],
    [{ ...s3, partSize: 5 * 1024 * MIB + 1 }, 'partSize must be a whole number of bytes up to 5 GiB'],
    [{ ...s3, listPartsUrl: 'list' }, 'listPartsUrl must be an http or https URL'],
    [{ ...file, url: 'https://x/put', protocol: 'put', partUrls: parts }, 'partUrls, partSize and listPartsUrl are only for s3-multipart'],
    [{ ...azure, partSize: 8 * MIB }, 'partUrls, partSize and listPartsUrl are only for s3-multipart'],
    [{ ...s3, blockSize: 8 * MIB }, 'blockSize is only for azure-blocks'],
    [{ ...azure, url: 'https://acct.blob.core.windows.net/c/blob.bin' }, 'url must be a blob SAS URL (with a sig parameter)'],
    [{ ...azure, url: 'https://acct.blob.core.windows.net/c/blob.bin?sv=2021&sig=' }, 'url must be a blob SAS URL'],
    [{ ...azure, url: `${sas}&comp=block` }, 'url must be a blob SAS URL'],
    [{ ...azure, blockSize: 4000 * MIB + 1 }, 'blockSize must be a whole number of bytes up to 4000 MiB'],
    [{ ...azure, blockSize: -1 }, 'blockSize must be a whole number of bytes up to 4000 MiB'],
  ])('refuses %#', (options, message) => {
    expect(() => checkUploadOptions(options as never)).toThrow(message);
  });
});
