# Changelog

## 0.1.0 (unreleased)

First version.

- `upload()` to an existing Google Cloud Storage or Firebase Storage resumable upload session:
  asks for the offset, sends the rest, finalizes. No `Authorization` header unless passed in
  `headers`.
- `download()` to `<path>.part`, renamed into place only when whole; resumes with `Range`.
- Android 14+: a user-initiated data transfer job per direction. Android 6 to 13: a WorkManager
  `dataSync` foreground-service worker. iOS: background `URLSession`s, with a temporary copy of
  the remaining bytes to resume an upload part-way.
- One transfer per direction at a time; `progress` and `stateChange` events; `list()`,
  `cancel()`, `forget()`; a reason for every stopped transfer, including `session-closed` for a
  session that was already closed when the upload started.
- iOS: an upload answered with anything but a clean finalize of the file's exact size is checked
  against the session, including after a relaunch; remainder copies no transfer names are
  removed at launch.
- `isAvailable()` carries a `warning` below Android 14 when the app's manifest doesn't declare
  WorkManager's foreground service with the `dataSync` type.
- The web reports the plugin as unavailable.
