import { describe, expect, it, vi } from 'vitest';

import type { BackgroundTransferPlugin, TransferEvent } from '../src/definitions';
import { BackgroundTransfer, wrap } from '../src/index';
import { BackgroundTransferWeb } from '../src/web';

const record: TransferEvent = {
  transfer: {
    id: 'v1',
    direction: 'upload',
    state: 'queued',
    url: 'https://x/u',
    path: '/v1',
    bytes: 0,
    total: -1,
    updatedAt: 1,
  },
};

function fakeNative(): BackgroundTransferPlugin {
  return {
    isAvailable: vi.fn(async () => ({ available: true, mechanism: 'job' as const })),
    upload: vi.fn(async () => record),
    download: vi.fn(async () => record),
    cancel: vi.fn(async () => undefined),
    list: vi.fn(async () => ({ transfers: [record.transfer] })),
    forget: vi.fn(async () => undefined),
    addListener: vi.fn(async () => ({ remove: async () => undefined })) as never,
    removeAllListeners: vi.fn(async () => undefined),
  };
}

describe('on the web', () => {
  it('says it is unavailable', async () => {
    await expect(BackgroundTransfer.isAvailable()).resolves.toEqual({ available: false, mechanism: 'none' });
  });

  it('refuses transfers with UNAVAILABLE', async () => {
    await expect(BackgroundTransfer.upload({ id: 'v1', url: 'https://x/u', path: '/v1' })).rejects.toMatchObject({
      code: 'UNAVAILABLE',
    });
    await expect(BackgroundTransfer.download({ id: 'v1', url: 'https://x/d', path: '/v1' })).rejects.toMatchObject({
      code: 'UNAVAILABLE',
    });
    await expect(new BackgroundTransferWeb().cancel()).rejects.toMatchObject({ code: 'UNAVAILABLE' });
  });

  it('lists nothing and forgets nothing', async () => {
    await expect(BackgroundTransfer.list()).resolves.toEqual({ transfers: [] });
    await expect(BackgroundTransfer.forget()).resolves.toBeUndefined();
  });
});

describe('upload protocol', () => {
  it('defaults to firebase-resumable', async () => {
    const native = fakeNative();
    await wrap(native).upload({ id: 'v1', url: 'https://x/u', path: '/v1' });
    expect(native.upload).toHaveBeenCalledWith({
      id: 'v1',
      url: 'https://x/u',
      path: '/v1',
      protocol: 'firebase-resumable',
    });
  });

  it('passes a known protocol on', async () => {
    const native = fakeNative();
    await wrap(native).upload({ id: 'v1', url: 'https://x/u', path: '/v1', protocol: 'firebase-resumable' });
    expect(native.upload).toHaveBeenCalledWith(expect.objectContaining({ protocol: 'firebase-resumable' }));
  });

  it('refuses an unknown protocol before the native side sees it', async () => {
    const native = fakeNative();
    await expect(
      wrap(native).upload({ id: 'v1', url: 'https://x/u', path: '/v1', protocol: 'gcs-resumable' as never }),
    ).rejects.toThrow('protocol must be one of firebase-resumable, put, s3-multipart, azure-blocks');
    expect(native.upload).not.toHaveBeenCalled();
  });

  it('refuses an unknown protocol on the web too', async () => {
    await expect(
      BackgroundTransfer.upload({ id: 'v1', url: 'https://x/u', path: '/v1', protocol: 'nope' as never }),
    ).rejects.toThrow('protocol must be one of firebase-resumable');
  });

  it('passes an s3-multipart upload on with its parts', async () => {
    const native = fakeNative();
    const partUrls = ['https://s3/b/k?partNumber=1', 'https://s3/b/k?partNumber=2'];
    await wrap(native).upload({
      id: 'v1',
      url: 'https://s3/b/k?uploadId=x',
      path: '/v1',
      protocol: 's3-multipart',
      partUrls,
    });
    expect(native.upload).toHaveBeenCalledWith(expect.objectContaining({ protocol: 's3-multipart', partUrls }));
  });

  it('refuses inconsistent options on the web before saying it is unavailable', async () => {
    await expect(
      BackgroundTransfer.upload({ id: 'v1', url: 'https://s3/b/k?uploadId=x', path: '/v1', protocol: 's3-multipart' }),
    ).rejects.toThrow('partUrls is required for s3-multipart');
    await expect(
      BackgroundTransfer.upload({ id: 'v1', url: 'https://acct/c/b', path: '/v1', protocol: 'azure-blocks' }),
    ).rejects.toThrow('url must be a blob SAS URL');
    await expect(
      BackgroundTransfer.upload({ id: 'v1', url: 'https://x/put', path: '/v1', protocol: 'put' }),
    ).rejects.toMatchObject({ code: 'UNAVAILABLE' });
  });
});

describe('wrap', () => {
  it('checks upload options before the native side sees them', async () => {
    const native = fakeNative();
    const plugin = wrap(native);
    await expect(plugin.upload({ id: '', url: 'https://x/u', path: '/v1' })).rejects.toThrow('id is required');
    expect(native.upload).not.toHaveBeenCalled();
  });

  it('hands checked options on, with file:// turned into a path', async () => {
    const native = fakeNative();
    const plugin = wrap(native);
    await expect(plugin.download({ id: 'v1', url: 'https://x/d', path: 'file:///a/b%20c.mp4' })).resolves.toBe(record);
    expect(native.download).toHaveBeenCalledWith({ id: 'v1', url: 'https://x/d', path: '/a/b c.mp4' });
  });

  it('passes the other calls straight through', async () => {
    const native = fakeNative();
    const plugin = wrap(native);
    await plugin.cancel({ id: 'v1', direction: 'upload' });
    await plugin.forget({ ids: [{ id: 'v1', direction: 'upload' }] });
    await plugin.list();
    await plugin.isAvailable();
    const listener = () => undefined;
    await plugin.addListener('stateChange', listener);
    await plugin.removeAllListeners();
    expect(native.cancel).toHaveBeenCalledWith({ id: 'v1', direction: 'upload' });
    expect(native.forget).toHaveBeenCalledWith({ ids: [{ id: 'v1', direction: 'upload' }] });
    expect(native.addListener).toHaveBeenCalledWith('stateChange', listener);
    expect(native.list).toHaveBeenCalled();
    expect(native.isAvailable).toHaveBeenCalled();
    expect(native.removeAllListeners).toHaveBeenCalled();
  });
});
