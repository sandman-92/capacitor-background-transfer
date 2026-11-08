// The example app's harness mode, for the end-to-end runs (test-servers/e2e.mjs): built in with
// `npm run build:harness`, it polls the test harness on the computer for commands, calls the plugin
// through its JavaScript API, and posts every result and event back. The harness is the computer
// as each device sees it: the Android emulator's alias for the host, or the simulator's loopback.
import { Directory, Filesystem } from '@capacitor/filesystem';
import { Capacitor } from '@capacitor/core';
import { BackgroundTransfer } from 'capacitor-background-transfer';

const HARNESS = Capacitor.getPlatform() === 'android' ? 'http://10.0.2.2:8790' : 'http://127.0.0.1:8790';

const timeout = (ms) => (AbortSignal.timeout ? AbortSignal.timeout(ms) : undefined);

async function report(kind, body) {
  try {
    await fetch(`${HARNESS}/reports`, {
      method: 'POST',
      signal: timeout(10000),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind, at: Date.now(), platform: Capacitor.getPlatform(), ...body }),
    });
  } catch {
    // The harness is away, or the network is cut on purpose.
  }
}

/** `name` (a file in the app's data directory) becomes `path`. */
async function withPath(args) {
  if (!args.name) return args;
  const { uri } = await Filesystem.getUri({ directory: Directory.Data, path: args.name });
  const { name, ...rest } = args;
  return { ...rest, path: uri };
}

async function run({ op, args = {} }) {
  switch (op) {
    case 'isAvailable':
      return BackgroundTransfer.isAvailable();
    case 'upload':
      return BackgroundTransfer.upload(await withPath(args));
    case 'cancel':
      return BackgroundTransfer.cancel(args);
    case 'list':
      return BackgroundTransfer.list();
    case 'forget':
      return BackgroundTransfer.forget(args);
    case 'dataPath':
      return Filesystem.getUri({ directory: Directory.Data, path: args.name || '' });
    default:
      throw new Error(`unknown op ${op}`);
  }
}

async function poll(log) {
  for (;;) {
    try {
      const response = await fetch(`${HARNESS}/commands/next`, { signal: timeout(10000) });
      if (response.status === 200) {
        const command = await response.json();
        log(`harness: ${command.op}`);
        try {
          await report('result', { seq: command.seq, ok: true, result: await run(command) });
        } catch (error) {
          log(`harness: ${command.op} failed: ${error?.message || error}`);
          await report('result', { seq: command.seq, ok: false, error: String(error?.message || error) });
        }
        continue;
      }
    } catch {
      // No harness yet: try again shortly.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

export async function startHarness(log) {
  await BackgroundTransfer.addListener('stateChange', ({ transfer }) => report('stateChange', { transfer }));
  await BackgroundTransfer.addListener('progress', ({ transfer }) => report('progress', { transfer }));
  // What ran, finished or failed while the app was closed.
  const { transfers } = await BackgroundTransfer.list();
  await report('launched', { transfers });
  poll(log);
}
