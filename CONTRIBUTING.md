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
(`npm run test:e2e`; see "Local storage servers" in the README).

`npm run fmt` fixes formatting. The API section of `README.md` is generated from
`src/definitions.ts` by `npm run build`; edit the comments there, not the README.

## Trying a change on a device

`example-app/` uses the plugin from this folder:

```bash
cd example-app
npm install
npm run sync
npx cap run android   # or: npx cap run ios
```

## Releasing

Releases are tagged `vX.Y.Z` on `main` with a matching `CHANGELOG.md` entry, then published with
`npm publish`.
