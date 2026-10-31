import { WebPlugin } from '@capacitor/core';

import type { AvailableResult, BackgroundTransferPlugin, TransferEvent, TransferRecord } from './definitions';

/**
 * The web has no background transfers: it says so, and every transfer call
 * is refused with Capacitor's `UNAVAILABLE` code, so the app keeps its
 * in-app path there.
 */
export class BackgroundTransferWeb extends WebPlugin implements BackgroundTransferPlugin {
  async isAvailable(): Promise<AvailableResult> {
    return { available: false, mechanism: 'none' };
  }

  async upload(): Promise<TransferEvent> {
    throw this.unavailable('Background transfers are not available on the web.');
  }

  async download(): Promise<TransferEvent> {
    throw this.unavailable('Background transfers are not available on the web.');
  }

  async cancel(): Promise<void> {
    throw this.unavailable('Background transfers are not available on the web.');
  }

  async list(): Promise<{ transfers: TransferRecord[] }> {
    return { transfers: [] };
  }

  async forget(): Promise<void> {
    return;
  }
}
