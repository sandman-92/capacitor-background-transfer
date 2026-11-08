# Contributing

Issues and pull requests are welcome.

## Setup

```bash
npm install
```

You need Node.js 20 or later; for Android, JDK 21 and the Android SDK (`ANDROID_HOME`); for iOS,
Xcode on macOS; for the tests against local storage servers, Docker.

## Checks

Run these before opening a pull request:

```bash
npm run verify   # typecheck, Vitest, build, JUnit, XCTest
npm run lint     # ESLint and Prettier (and SwiftLint where installed)
npm run test:servers   # with Docker: the JUnit and XCTest suites against MinIO and Azurite
```

A change to an upload protocol should also pass the end-to-end runs on an emulator or simulator
(`npm run test:e2e`; see [Local storage servers](#local-storage-servers)).

`npm run fmt` fixes formatting. The API section of `README.md` is generated from
`src/definitions.ts` by `npm run build`; edit the comments there, not the README.

## The tests

```bash
npm run build           # TypeScript, the API section of README.md, rollup bundles
npm test                # Vitest: option checks, the web implementation
npm run test:android    # JUnit: chunking, offsets, Range, retries, the queue (JDK 21, Android SDK)
npm run test:ios        # XCTest on macOS: remainder copies, part files, upload outcomes
npm run verify          # all of the above
npm run test:servers    # MinIO and Azurite in Docker; the JUnit and XCTest suites against them
```

### Local storage servers

`test-servers/` holds a Docker Compose file running MinIO (S3, release
`RELEASE.2025-10-15T17-29-55Z`, built from its repository by `minio.Dockerfile` since MinIO no
longer publishes images; the first start builds it) and Azurite (Azure Blob, 3.37.0) with their
well-known development credentials (`minioadmin`/`minioadmin`, and Azurite's `devstoreaccount1`),
and a small harness in front of them (`harness.mjs`, Node's standard library only). Its control
API on port 8790 creates multipart uploads, presigns part URLs and SAS URLs, checks what the
servers stored, and injects faults; the S3 (8791) and Azure (8792) endpoints it hands out go
through a recording proxy that can cut a request part-way, refuse it, swallow its answer, slow it
down or drop every connection for a while. The containers are memory-limited, their images
pinned, and their ports published on `127.0.0.1` only.

`npm run test:servers` needs Docker running, a JDK 21 (`JAVA_HOME`) and the Android SDK
(`ANDROID_HOME`, or `sdk.dir` in `android/local.properties`), and on macOS Swift; it refuses to
start without them. It reruns the JUnit suite even when Gradle holds results from a run without
the servers, and says how many of `ServersTest`'s cases ran. In CI the JUnit suite runs against
the compose servers on Linux; the Swift suite runs on macOS, which has no Docker, against the
same MinIO release built from its repository, Azurite 3.37.0 from npm and the harness. CI also
scans every push and pull request for committed secrets (gitleaks, configured in
`.gitleaks.toml`, which allowlists the test servers' published development credentials).

```bash
npm run servers:up      # start them (docker compose up --wait)
BT_HARNESS=http://localhost:8790 npm run test:android   # the JVM tests that need them run only with BT_HARNESS set
BT_HARNESS=http://localhost:8790 npm run test:ios
npm run servers:down
```

End to end, on one booted Android emulator or iOS simulator at a time (the URLs it hands the
device use `10.0.2.2` on Android and `127.0.0.1` on iOS):

```bash
npm run build && (cd example-app && npm install && npm run build:harness && npx cap sync)
# Android: build and install example-app/android (./gradlew assembleDebug; adb install -r -g …)
# iOS: build the example for the simulator signed ad hoc (CODE_SIGN_IDENTITY=-): an unsigned
#      app is never woken in the background when a task ends
npm run servers:up
npm run test:e2e -- --platform android    # or --platform ios; --only s3-multipart, --case killed
```

It makes the test files on the device (three parts of 5, 5 and 1 MiB), locks the device, sends the
app to the background and kills it, cuts the network, lets URLs expire, refuses or swallows the
commit, and checks the stored objects and what the app reports.

`test:ios` runs `ios/CoreTests`, a package of its own whose sources are symlinks to
`ios/Sources/BackgroundTransferCore` and `ios/Tests/BackgroundTransferCoreTests`, because
Capacitor's Swift package only ships iOS binaries. The Android tests run the uploader and
downloader against a local MockWebServer. The upload protocols' tests against real servers are described under
[Local storage servers](#local-storage-servers).

Things only a real device can show: locking an iPhone mid-transfer, Low Power Mode, an Android
restart part-way through (the job is persisted), and makers' own battery managers.

## Trying a change on a device

`example-app/` uses the plugin from this folder:

```bash
cd example-app
npm install
npm run sync
npx cap run android   # or: npx cap run ios
```

## Releasing

A GitHub release publishes the package to npm (`.github/workflows/release.yml`). Nothing is
published by a merge to `main`.

1. On a branch, set the version in `package.json` (and `package-lock.json`: `npm version X.Y.Z
   --no-git-tag-version` does both) and date the version's entry in `CHANGELOG.md` (`## X.Y.Z
   (YYYY-MM-DD)`, not `(unreleased)`). Merge it.
2. On GitHub, draft a release from `main` with a new tag `vX.Y.Z` and the changelog entry as its
   notes. Tick **pre-release** for a version to try first: it is published under npm's `next`
   dist-tag, so `npm install capacitor-background-transfer@next` gets it and plain installs don't.
   Unticking it later moves `latest` to that version (the workflow's promote job, which needs the
   `NPM_TOKEN` secret: trusted publishing covers `npm publish` only), or publish the next version
   as a full release.
3. Publishing the release runs the workflow: it checks that the tag names the version in
   `package.json`, that `CHANGELOG.md` has a dated entry for it and that the tagged commit is on
   `main`; runs the lint, TypeScript, JUnit and XCTest suites and the iOS build (the server tests
   ran on the merge to `main`); shows what the tarball holds (`npm pack --dry-run`, the `files`
   list in `package.json`); and runs `npm publish --provenance --access public`, so the npm page
   links the release back to this repository and the workflow run.

### One-time npm setup

The workflow signs in to npm one of two ways:

- **Trusted publishing (no secret).** On npmjs.com, under the package's settings, add a trusted
  publisher: GitHub Actions, repository `sandman-92/capacitor-background-transfer`, workflow
  `release.yml`, no environment. The workflow's `id-token: write` permission lets npm verify the
  run, and no token is stored anywhere. npm only offers this for a package that already exists,
  so the first release can't use it.
- **A token (`NPM_TOKEN`).** For the first release (or if the trusted publisher is ever removed):
  on npmjs.com create a granular access token with read and write access to this package (or to
  new packages, the first time) and 2FA bypass for automation, and store it as the repository
  secret `NPM_TOKEN`. The workflow writes it to `.npmrc` for the publish only. Once the trusted
  publisher is set up the secret can go, and the workflow uses trusted publishing; keep it if you
  want unticking pre-release on GitHub to promote a version to `latest`, which only a token can do.

Provenance needs a public repository, which this is.
