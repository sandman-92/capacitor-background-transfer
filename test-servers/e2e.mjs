// End-to-end runs of the upload protocols on ONE booted device: the Android emulator or the iOS
// simulator, with the example app built in harness mode (`npm run build:harness` in example-app,
// then `npx cap sync` and install). The app takes its commands from the harness (harness.mjs);
// this script makes the files on the device, sets the uploads up, locks, backgrounds and kills the
// app, and checks what the servers stored and what the app reports.
//
//   node test-servers/e2e.mjs --platform android [--only s3-multipart] [--case locked]
//   node test-servers/e2e.mjs --platform ios
//
// Node's standard library only. Needs the servers (`npm run servers:up`) and adb or simctl.
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const PLATFORM = opt('platform', 'android');
const ONLY = opt('only');
const CASE = opt('case');
const HARNESS = opt('harness', 'http://localhost:8790');
const APP = 'io.github.sandman92.backgroundtransfer.example';
const SIMCTL =
  process.env.SIMCTL || '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl';
const MIB = 1024 * 1024;
const PART = 5 * MIB;
/** Three parts or blocks: 5, 5 and 1 MiB. */
const SIZE = 11 * MIB;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const log = (...parts) => console.log(new Date().toISOString().slice(11, 19), ...parts);

function sh(cmd, argv, { check = true, timeout = 120000 } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return execFileSync(cmd, argv, { encoding: 'utf8', timeout, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    } catch (e) {
      const text = `${e.stdout || ''}${e.stderr || ''}`;
      // adb's server sometimes drops the device for a moment.
      if (cmd === 'adb' && attempt < 3 && /offline|not found|closed|protocol fault/.test(text)) {
        execFileSync('adb', ['wait-for-device'], { timeout: 120000 });
        continue;
      }
      if (!check) return text.trim();
      throw new Error(`${cmd} ${argv.join(' ')}: ${text}`);
    }
  }
}

async function harness(method, route, body) {
  const response = await fetch(HARNESS + route, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 204) return null;
  const json = await response.json();
  if (response.status >= 300) throw new Error(`${method} ${route}: ${JSON.stringify(json)}`);
  return json;
}

// ---- The device ---------------------------------------------------------------------------------

const android = {
  runAs: (command, check = true) => sh('adb', ['shell', 'run-as', APP, 'sh', '-c', `'${command}'`], { check, timeout: 300000 }),
  makeFile(name, bytes) {
    this.runAs(`head -c ${bytes} /dev/urandom > files/${name}`);
  },
  sha256(name) {
    return this.runAs(`sha256sum files/${name}`).split(/\s+/)[0];
  },
  remainders: () => [],
  launch: () => sh('adb', ['shell', 'am', 'start', '-n', `${APP}/.MainActivity`]),
  background: () => sh('adb', ['shell', 'input', 'keyevent', 'KEYCODE_HOME']),
  lock: () => sh('adb', ['shell', 'input', 'keyevent', 'KEYCODE_SLEEP']),
  unlock() {
    sh('adb', ['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
    sh('adb', ['shell', 'wm', 'dismiss-keyguard'], { check: false });
  },
  kill() {
    // Outright, as the system does under memory pressure.
    const pid = sh('adb', ['shell', 'pidof', APP], { check: false });
    if (!pid) return;
    this.runAs(`kill -9 ${pid}`, false);
    // Some images' SELinux policy stops run-as killing the app: there, run `adb root` first.
    if (sh('adb', ['shell', 'pidof', APP], { check: false }) === pid) sh('adb', ['shell', 'kill', '-9', pid], { check: false });
  },
};

const ios = {
  _data: null,
  data() {
    this._data ??= sh(SIMCTL, ['get_app_container', 'booted', APP, 'data']);
    return this._data;
  },
  makeFile(name, bytes) {
    fs.mkdirSync(path.join(this.data(), 'Documents'), { recursive: true });
    fs.writeFileSync(path.join(this.data(), 'Documents', name), crypto.randomBytes(bytes));
  },
  sha256(name) {
    return crypto.createHash('sha256').update(fs.readFileSync(path.join(this.data(), 'Documents', name))).digest('hex');
  },
  remainders() {
    const d = path.join(this.data(), 'Library/Application Support/BackgroundTransfer/remainders');
    return fs.existsSync(d) ? fs.readdirSync(d) : [];
  },
  launch: () => sh(SIMCTL, ['launch', 'booted', APP]),
  // Opening Settings sends the app to the background.
  background: () => sh(SIMCTL, ['launch', 'booted', 'com.apple.Preferences']),
  lock() {},
  unlock() {},
  // Ends the process as the system does when it needs the memory (not a swipe away).
  kill: () => sh(SIMCTL, ['terminate', 'booted', APP], { check: false }),
};

const device = PLATFORM === 'ios' ? ios : android;

// ---- Talking to the app -------------------------------------------------------------------------

let since = 0;

async function reports() {
  return (await harness('GET', `/reports?since=${since}`)).reports;
}

async function waitFor(what, check, timeout = 90000, every = 1000) {
  const until = Date.now() + timeout;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await sleep(every);
  }
}

async function command(op, args = {}) {
  const { seq } = await harness('POST', '/commands', { op, args });
  const result = await waitFor(`${op} to answer`, async () => (await reports()).find((r) => r.kind === 'result' && r.seq === seq), 60000, 500);
  if (!result.ok) throw Object.assign(new Error(result.error), { refused: true });
  return result.result;
}

/** Starts the app afresh (ending it first if it is running) and returns what it listed at launch. */
async function launch() {
  device.kill();
  await sleep(1000);
  const before = Date.now();
  device.unlock();
  device.launch();
  const launched = await waitFor('the app to launch', async () => (await reports()).filter((r) => r.kind === 'launched' && r.received >= before).pop());
  return launched.transfers;
}

/** Cancels and forgets whatever earlier cases left, so this case's upload isn't queued behind it. */
async function cleanSlate() {
  for (const t of (await command('list')).transfers) {
    if (['queued', 'running', 'interrupted'].includes(t.state)) await command('cancel', { id: t.id, direction: t.direction });
  }
  await sleep(1000);
  await command('forget');
}

async function record(id) {
  return (await command('list')).transfers.find((t) => t.id === id && t.direction === 'upload');
}

/** The transfer's state events since the case started. */
async function events(id, kind = 'stateChange') {
  // In the order the app sent them: reports go one request each and can arrive out of order.
  return (await reports())
    .filter((r) => r.kind === kind && r.transfer?.id === id)
    .sort((a, b) => a.at - b.at)
    .map((r) => r.transfer);
}

// ---- Uploads as an app sets them up -------------------------------------------------------------

/** The computer as the device sees it: the emulator's alias for the host, or the simulator's loopback. */
const DEVICE_HOST = PLATFORM === 'ios' ? '127.0.0.1' : '10.0.2.2';

async function setUp(protocol, id, given = {}) {
  const extra = { host: DEVICE_HOST, ...given };
  const name = `${id}.bin`;
  device.makeFile(name, SIZE);
  const sha = device.sha256(name);
  let options;
  let object;
  if (protocol === 'put') {
    const put = await harness('POST', '/s3/put', { ...extra, key: id });
    options = { id, name, protocol, url: put.url };
    object = { route: `/s3/object?key=${put.key}` };
  } else if (protocol === 's3-multipart') {
    const m = await harness('POST', '/s3/multipart', { ...extra, key: id, size: SIZE, partSize: PART });
    options = { id, name, protocol, url: m.url, partUrls: m.partUrls, partSize: PART, listPartsUrl: m.listPartsUrl };
    object = { route: `/s3/object?key=${m.key}` };
  } else {
    const blob = await harness('POST', '/azure/blob', { ...extra, name: id });
    options = { id, name, protocol, url: blob.url, blockSize: PART };
    object = { route: `/azure/blob?name=${blob.name}` };
  }
  return { options, sha, object, target: protocol === 'azure-blocks' ? 'azure' : 's3' };
}

async function stored(u) {
  return harness('GET', u.object.route);
}

async function assertStored(u, timeout = 180000) {
  const o = await waitFor('the object on the server', async () => ((await stored(u)).exists ? stored(u) : null), timeout, 2000);
  assert(o.size === SIZE, `stored ${o.size} bytes, expected ${SIZE}`);
  assert(o.sha256 === u.sha, 'the stored object matches the file');
}

/** Requests that carried part or block `n` (put: every PUT). */
async function sendsOf(u, n) {
  const { requests } = await harness('GET', `/requests?target=${u.target}`);
  // Every attempt counts, also one cut off before it was answered.
  const puts = requests.filter((q) => q.method === 'PUT');
  if (u.options.protocol === 'put') return puts;
  if (u.options.protocol === 's3-multipart') return puts.filter((q) => q.partNumber === n);
  // Azure: the n-th distinct block id in the order they were first sent.
  const ids = [...new Set(puts.filter((q) => q.comp === 'block').map((q) => q.blockid))];
  return puts.filter((q) => q.comp === 'block' && q.blockid === ids[n - 1]);
}

function assert(ok, what) {
  if (!ok) throw new Error(`not so: ${what}`);
}

/**
 * Progress as the app saw it: bytes so far, never more than the total, and never back except when
 * a part cut off part-way is started again (to the stored parts' end, a part boundary; for put, 0).
 */
function assertProgress(progress, total) {
  assert(progress.length > 0, 'progress events arrived');
  for (let i = 1; i < progress.length; i++) {
    const back = progress[i].bytes < progress[i - 1].bytes;
    assert(!back || progress[i].bytes % PART === 0, `progress went from ${progress[i - 1].bytes} to ${progress[i].bytes}`);
  }
  assert(progress.every((p) => p.bytes <= total && p.total === total), 'progress never passes the total');
}

async function waitState(id, states, timeout = 180000) {
  return waitFor(`${id} to be ${states.join(' or ')}`, async () => {
    const r = await record(id).catch(() => null);
    return r && states.includes(r.state) ? r : null;
  }, timeout, 1500);
}

// ---- The cases ----------------------------------------------------------------------------------

const cases = {
  /** Criteria 1 and 6, Android: the device locked part-way; stored while locked, reported finished. */
  async locked(protocol) {
    if (PLATFORM !== 'android') return 'skip';
    const id = `locked-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id);
    await launch();
    await cleanSlate();
    await harness('POST', '/throttle', { bytesPerSecond: 1.5 * MIB });
    await command('upload', u.options);
    await waitFor('bytes to move', async () => (await events(id, 'progress')).some((p) => p.bytes > MIB));
    device.lock();
    log(`  ${id}: locked`);
    await assertStored(u);
    device.unlock();
    const r = await waitState(id, ['finished', 'failed']);
    assert(r.state === 'finished' && r.bytes === SIZE && r.total === SIZE, `reported finished ${r.bytes}/${r.total} (was ${r.state})`);
    assertProgress(await events(id, 'progress'), SIZE);
  },

  /** Criteria 1 and 6: the app sent to the background part-way and its process killed. */
  async killed(protocol) {
    const id = `killed-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id);
    await launch();
    await cleanSlate();
    await harness('POST', '/throttle', { bytesPerSecond: 1.5 * MIB });
    await command('upload', u.options);
    await waitFor('bytes to move', async () => (await events(id, 'progress')).some((p) => p.bytes > MIB));
    device.background();
    await sleep(2000);
    device.kill();
    log(`  ${id}: in the background, process killed`);
    await harness('POST', '/throttle', { bytesPerSecond: 3 * MIB });
    let alone = true;
    try {
      // iOS holds back each launch that starts the next part, doubling the wait: 1, 2, 4 minutes.
      await assertStored(u, PLATFORM === 'ios' ? 540000 : 120000);
    } catch (e) {
      // Android restarts a job whose process died when it sees fit; opening the app schedules it at once.
      alone = false;
      log(`  ${id}: not stored with the app closed in time; opening it`);
      await launch();
      const r = await record(id);
      if (r?.state === 'interrupted') {
        // Below Android 14 the worker can't come back by itself: the app starts it again.
        log(`  ${id}: interrupted (${r.reason}), starting it again`);
        await command('upload', u.options);
      }
      await assertStored(u);
    }
    if (alone) log(`  ${id}: stored with the app closed`);
    const transfers = await launch();
    const listed = transfers.find((t) => t.id === id);
    const r = listed?.state === 'finished' ? listed : await waitState(id, ['finished', 'failed']);
    assert(r.state === 'finished' && r.bytes === SIZE && r.total === SIZE, `reported finished at launch ${r.bytes}/${r.total} (was ${r.state})`);
    assertProgress(await events(id, 'progress'), SIZE);
    assert(device.remainders().length === 0, 'no temporary copies are left');
    return alone ? undefined : 'stored only after the app was opened again';
  },

  /** Criteria 2 and 6: interrupted part-way (network cut), started again; nothing stored is sent again. */
  async interrupted(protocol) {
    const id = `cut-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id);
    await launch();
    await cleanSlate();
    await harness('POST', '/throttle', { bytesPerSecond: 1.5 * MIB });
    await command('upload', u.options);
    // Part-way through the second part (for put, part-way through the file).
    await waitFor('the second part to be under way', async () => (await events(id, 'progress')).some((p) => p.bytes > PART + MIB), 90000, 500);
    await harness('POST', '/outage', { seconds: 25 });
    log(`  ${id}: network cut for 25 s`);
    await harness('POST', '/throttle', { bytesPerSecond: 0 });
    // The system may carry on by itself once the network is back; otherwise it is interrupted.
    const after = await waitState(id, ['interrupted', 'finished', 'failed', 'queued'], 240000);
    if (after.state === 'interrupted' || after.state === 'queued') {
      // Interrupted, or (Android 14+) back in the queue for the system to run again when it sees
      // fit: starting it again runs it now.
      log(`  ${id}: ${after.state} (${after.reason}), starting it again`);
      await command('upload', u.options);
    }
    const done = await waitState(id, ['finished', 'failed']);
    assert(done.state === 'finished', `finished (was ${done.state} ${done.reason || ''} ${done.message || ''})`);
    await assertStored(u);
    if (protocol === 'put') {
      const puts = await sendsOf(u, 1);
      assert(puts.length >= 2 && puts[puts.length - 1].bytes === SIZE, 'the PUT is sent again whole');
    } else {
      // A part the server stored is never sent again; one cut off is.
      assert((await sendsOf(u, 1)).length === 1, 'part 1 is sent once');
      for (const n of [1, 2, 3]) {
        const stored = (await sendsOf(u, n)).filter((q) => q.status >= 200 && q.status < 300);
        assert(stored.length === 1, `part ${n} is stored once (stored ${stored.length} times)`);
      }
      const again = [];
      for (const n of [2, 3]) if ((await sendsOf(u, n)).length >= 2) again.push(n);
      assert(again.length > 0, 'the part that was cut off is sent again');
    }
    assertProgress(await events(id, 'progress'), SIZE);
    assert(device.remainders().length === 0, 'no temporary copies are left');
  },

  /** Criterion 3: an expired URL or SAS fails with a reason saying which request; nothing left behind. */
  async expired(protocol) {
    const id = `expired-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id, { expires: protocol === 'azure-blocks' ? -60 : 1 });
    if (protocol === 's3-multipart') delete u.options.listPartsUrl;
    await launch();
    await cleanSlate();
    await sleep(2100);
    await command('upload', u.options);
    const r = await waitState(id, ['failed', 'finished'], 90000);
    const which = { put: 'PUT', 's3-multipart': 'part 1 of 3', 'azure-blocks': 'block 1 of 3' }[protocol];
    assert(r.state === 'failed' && r.reason === 'session-refused' && r.httpStatus === 403, `failed session-refused 403 (was ${r.state} ${r.reason} ${r.httpStatus})`);
    assert(r.message.includes(which), `the message names ${which}: ${r.message}`);
    assert(!(await events(id)).some((t) => t.state === 'finished'), 'never reported finished');
    assert(!(await stored(u)).exists, 'nothing is stored');
    assert(device.remainders().length === 0, 'no temporary copies are left');
  },

  /** Criterion 3: the commit (for put, the PUT) refused. */
  async refusedCommit(protocol) {
    const id = `refused-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id);
    await launch();
    await cleanSlate();
    await harness('POST', '/faults', commitFault(protocol, { action: 'status', status: 403 }));
    await command('upload', u.options);
    const r = await waitState(id, ['failed', 'finished'], 90000);
    const which = { put: 'PUT', 's3-multipart': 'complete', 'azure-blocks': 'commit (Put Block List)' }[protocol];
    assert(r.state === 'failed' && r.reason === 'session-refused', `failed session-refused (was ${r.state} ${r.reason})`);
    assert(r.message.includes(which), `the message names ${which}: ${r.message}`);
    assert(device.remainders().length === 0, 'no temporary copies are left');
  },

  /** Criterion 4: the commit succeeded but its answer was lost; never reported finished on its own say-so. */
  async lostAnswer(protocol) {
    const id = `lost-${protocol}-${Date.now() % 100000}`;
    const u = await setUp(protocol, id);
    await launch();
    await cleanSlate();
    await harness('POST', '/faults', commitFault(protocol, { action: 'drop-answer' }));
    await command('upload', u.options);
    let r = await waitState(id, ['interrupted', 'failed', 'finished'], 120000);
    await assertStored(u);
    if (r.state === 'interrupted') {
      log(`  ${id}: interrupted (${r.reason}), starting it again`);
      await command('upload', u.options);
      r = await waitState(id, ['failed', 'finished'], 90000);
    }
    if (protocol === 'put') {
      // The PUT is its own confirmation: sent again, it is answered.
      assert(r.state === 'finished', `finished after the PUT was sent again (was ${r.state} ${r.reason})`);
    } else if (r.state === 'finished') {
      // Only on the server's word: the commit was sent again (iOS resends a request whose
      // connection dropped) and that answer arrived.
      const { requests } = await harness('GET', `/requests?target=${u.target}`);
      const commits = requests.filter((q) => (protocol === 's3-multipart' ? q.method === 'POST' : q.comp === 'blocklist' && q.method === 'PUT'));
      const last = commits[commits.length - 1];
      assert(commits.length >= 2 && last.status >= 200 && last.status < 300 && !last.fault, 'finished only after a resent commit was answered');
      log(`  ${id}: the commit was resent and answered ${last.status}`);
    } else {
      assert(r.state === 'failed' && r.reason === 'session-closed', `failed session-closed (was ${r.state} ${r.reason})`);
      assert(!(await events(id)).some((t) => t.state === 'finished'), 'never reported finished');
    }
    assert(device.remainders().length === 0, 'no temporary copies are left');
  },
};

function commitFault(protocol, fault) {
  if (protocol === 's3-multipart') return { ...fault, target: 's3', method: 'POST' };
  if (protocol === 'azure-blocks') return { ...fault, target: 'azure', method: 'PUT', query: 'comp=blocklist' };
  return { ...fault, target: 's3', method: 'PUT' };
}

// ---- Running them -------------------------------------------------------------------------------

const protocols = ['put', 's3-multipart', 'azure-blocks'].filter((p) => !ONLY || p === ONLY);
const names = Object.keys(cases).filter((c) => !CASE || c === CASE);
const results = [];
for (const name of names) {
  for (const protocol of protocols) {
    await harness('POST', '/reset', {});
    await harness('POST', '/reports/clear', {});
    since = 0;
    log(`${name} ${protocol}`);
    try {
      const note = await cases[name](protocol);
      if (note === 'skip') {
        log('  skipped on this platform');
        continue;
      }
      results.push({ name, protocol, ok: true, note });
      log(`  pass${note ? ` (${note})` : ''}`);
    } catch (e) {
      results.push({ name, protocol, ok: false, error: e.message });
      log(`  FAIL ${e.message}`);
      device.unlock();
    }
  }
}
await harness('POST', '/reset', {});
const failed = results.filter((r) => !r.ok);
console.log(`\n${PLATFORM}: ${results.length - failed.length} of ${results.length} passed`);
for (const f of failed) console.log(`  FAIL ${f.name} ${f.protocol}: ${f.error}`);
for (const n of results.filter((r) => r.note)) console.log(`  note ${n.name} ${n.protocol}: ${n.note}`);
process.exit(failed.length ? 1 : 0);
