import { describe, expect, it } from 'vitest';

import { checkTransferOptions, toPlainPath } from '../src/validate';

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
