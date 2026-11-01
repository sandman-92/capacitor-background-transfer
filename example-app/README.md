# Example app

A small app for trying the plugin by hand on a device or simulator.

```bash
npm install
npm run build
npx cap sync
npx cap run android   # or: npx cap run ios
```

Enter a URL and a file name, then press Upload or Download. Upload needs the session URL of a
resumable upload you have already started; Download needs a URL the device can fetch. Files are
read from and written to the app's data directory.

The native projects allow plain `http` (`usesCleartextTraffic`, `NSAllowsArbitraryLoads`) so the
app can talk to a test server on your computer. Don't copy that into a release build.

## Harness mode

`npm run build:harness` (then `npx cap sync`) builds in a remote control for the end-to-end runs
in `../test-servers`: the app polls the test harness on your computer for commands and reports
every result and event back. `npm run build` leaves it out again.
