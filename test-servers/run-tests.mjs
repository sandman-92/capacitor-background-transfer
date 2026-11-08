// `npm run test:servers`: starts MinIO, Azurite and the harness (compose.yaml), runs the JUnit and
// XCTest suites against them, says how many server tests ran, and stops the servers again,
// whatever happened. Refuses to start without what the suites need, rather than half-running.
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const compose = ['compose', '-f', path.join(root, 'test-servers/compose.yaml')];
const env = { ...process.env, BT_HARNESS: 'http://localhost:8790' };

function works(cmd, args) {
  return spawnSync(cmd, args, { stdio: 'ignore', env }).status === 0;
}

const missing = [];
if (!works('docker', ['info'])) missing.push('Docker (is it running?)');
const java = env.JAVA_HOME ? path.join(env.JAVA_HOME, 'bin', 'java') : 'java';
if (!works(java, ['-version'])) missing.push('a JDK 21: set JAVA_HOME');
const localProperties = path.join(root, 'android/local.properties');
const sdk =
  env.ANDROID_HOME ||
  env.ANDROID_SDK_ROOT ||
  (fs.existsSync(localProperties) && /^sdk\.dir=/m.test(fs.readFileSync(localProperties, 'utf8')));
if (!sdk) missing.push('the Android SDK: set ANDROID_HOME (or sdk.dir in android/local.properties)');
if (process.platform === 'darwin' && !works('swift', ['--version'])) missing.push('Swift (Xcode)');
if (missing.length) {
  console.error(`test:servers needs ${missing.join('; ')}`);
  process.exit(2);
}

function run(cmd, args, cwd = root) {
  console.log(`$ ${cmd} ${args.join(' ')}`);
  return spawnSync(cmd, args, { cwd, stdio: 'inherit', env }).status === 0;
}

/** How many of ServersTest's cases ran and passed, from Gradle's reports. */
function serversTestCount() {
  const dir = path.join(root, 'android/build/test-results/testDebugUnitTest');
  const file = fs.existsSync(dir) && fs.readdirSync(dir).find((f) => f.includes('ServersTest'));
  if (!file) return 'no ServersTest results';
  const xml = fs.readFileSync(path.join(dir, file), 'utf8');
  const [, tests, skipped, failures, errors] = xml.match(
    /tests="(\d+)" skipped="(\d+)" failures="(\d+)" errors="(\d+)"/,
  );
  return `${tests - skipped} of ServersTest's ${tests} cases ran (${skipped} are for another protocol), ${failures} failed, ${errors} errors`;
}

let ok = false;
try {
  ok = run('docker', [...compose, 'up', '-d', '--wait']);
  // Always rerun: the servers are outside Gradle's view, so its earlier results prove nothing here.
  if (ok) ok = run('./gradlew', ['testDebugUnitTest', '--rerun'], path.join(root, 'android'));
  console.log(`JUnit: ${serversTestCount()}`);
  if (ok && process.platform === 'darwin')
    ok = run('swift', ['test', '--disable-keychain', '--package-path', 'ios/CoreTests']);
} finally {
  execFileSync('docker', [...compose, 'down'], { stdio: 'inherit' });
}
process.exit(ok ? 0 : 1);
