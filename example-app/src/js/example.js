import { Directory, Filesystem } from '@capacitor/filesystem';
import { BackgroundTransfer } from 'capacitor-background-transfer';

const $ = (id) => document.getElementById(id);
const lines = [];

function log(line) {
  lines.unshift(`${new Date().toLocaleTimeString()} ${line}`);
  lines.length = Math.min(lines.length, 50);
  $('log').textContent = lines.join('\n');
}

async function refresh() {
  const { transfers } = await BackgroundTransfer.list();
  $('transfers').textContent = transfers
    .map((t) => `${t.direction} ${t.id}: ${t.state} ${t.bytes}/${t.total}${t.reason ? ` (${t.reason})` : ''}`)
    .join('\n');
}

async function options() {
  const name = $('name').value.trim();
  const { uri } = await Filesystem.getUri({ directory: Directory.Data, path: name });
  return { id: name, url: $('url').value.trim(), path: uri };
}

async function run(what, call) {
  try {
    await call();
  } catch (error) {
    log(`${what} failed: ${error?.message || error}`);
  }
  await refresh();
}

$('upload').onclick = () => run('upload', async () => BackgroundTransfer.upload(await options()));
$('download').onclick = () => run('download', async () => BackgroundTransfer.download(await options()));
$('cancel').onclick = () =>
  run('cancel', async () => {
    const id = $('name').value.trim();
    await BackgroundTransfer.cancel({ id, direction: 'upload' });
    await BackgroundTransfer.cancel({ id, direction: 'download' });
  });
$('list').onclick = () => run('list', async () => undefined);
$('forget').onclick = () => run('forget', async () => BackgroundTransfer.forget());

async function main() {
  $('available').textContent = JSON.stringify(await BackgroundTransfer.isAvailable());
  await BackgroundTransfer.addListener('stateChange', ({ transfer }) => {
    log(`${transfer.direction} ${transfer.id} ${transfer.state}${transfer.reason ? ` (${transfer.reason})` : ''}`);
    refresh();
  });
  await BackgroundTransfer.addListener('progress', ({ transfer }) => {
    log(`${transfer.direction} ${transfer.id} ${transfer.bytes}/${transfer.total}`);
  });
  await refresh();
  // `npm run build:harness` builds in the end-to-end runs' remote control (src/js/harness.js).
  if (import.meta.env.VITE_HARNESS) {
    const { startHarness } = await import('./harness.js');
    await startHarness(log);
  }
}

main();
