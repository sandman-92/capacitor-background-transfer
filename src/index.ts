import { registerPlugin } from '@capacitor/core';

import type { BackgroundTransferPlugin } from './definitions';
import { checkTransferOptions, checkUploadOptions } from './validate';

const Native = registerPlugin<BackgroundTransferPlugin>('BackgroundTransfer', {
  web: () => import('./web').then((m) => new m.BackgroundTransferWeb()),
});

/**
 * The plugin, with `upload` and `download` options checked (and `file://`
 * URIs turned into paths) before they reach the native side.
 */
const BackgroundTransfer: BackgroundTransferPlugin = wrap(Native);

export function wrap(plugin: BackgroundTransferPlugin): BackgroundTransferPlugin {
  return {
    isAvailable: () => plugin.isAvailable(),
    upload: async (options) => plugin.upload(checkUploadOptions(options)),
    download: async (options) => plugin.download(checkTransferOptions(options)),
    cancel: (options) => plugin.cancel(options),
    list: () => plugin.list(),
    forget: (options) => plugin.forget(options),
    addListener: ((eventName: 'progress' | 'stateChange', listener: never) =>
      plugin.addListener(eventName as 'progress', listener)) as BackgroundTransferPlugin['addListener'],
    removeAllListeners: () => plugin.removeAllListeners(),
  };
}

export * from './definitions';
export { checkTransferOptions, checkUploadOptions, toPlainPath } from './validate';
export { BackgroundTransfer };
