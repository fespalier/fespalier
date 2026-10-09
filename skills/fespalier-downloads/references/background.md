# The background backend

Since 0.15.0, `package:fespalier_download_background`, over `background_downloader` (written against 9.6.4). It needs
**Flutter 3.47 and Dart 3.13**, so it is a package of its own and not in the Flutter 3.32 floor job: an app on an older
Flutter keeps `HttpDownloadBackend`. A release that predates 0.15.0 has no such package.

```dart
final engine = Downloads(
  backend: BackgroundDownloaderBackend(
    notifications: const DownloadNotifications(running: 'Downloading', complete: 'Done', failed: 'Failed'),
  ),
  store: FileDownloadStore(bases: bases),
  files: TransferDownloadFiles(bases: bases),
);
```

Override `downloadsEngine` with it in `startup.dart`, and `open()` the engine **before** anything of the app's calls
`FileDownloader().start()` or `resumeFromBackground()` (the plugin delivers what it kept once).

## What it is

- **Capabilities are honest.** Android and iOS: pause, resume across a restart, background, `userInitiated`, `unmetered`;
  `notifications` only with a `running` text. Desktop: pause only (an `unmetered` request is refused). Web and Fuchsia:
  every start is `Failed(unsupported)` and the plugin is never touched.
- **A request becomes a plugin task** (`downloadTaskOf`, pure): task id = request id; group `fespalier.download`; the file as
  base folder (`support` = application support, `cache` = temporary, `documents` = documents), sub-folder and name, never
  absolute; `userInitiated` = priority 0 (a user-initiated data transfer job on Android 14+, with a notification and the job
  service declared), `background` = 5; `allowPause` always (what continues a long task across WorkManager's nine-minute
  cycles); `unmetered` = `requiresWiFi` (iOS: no cellular, a metered hotspot still passes); retries from
  `BackgroundOptions(retries: 3)`; headers = request then attempt; size and sha256 in `metaData`.
- **A plugin update becomes a status** (`downloadStatusOf`, `failureOf`, `progressOf`, pure): `enqueued` Queued, `running`
  Running, `waitingToRetry` Waiting(retry), `paused` Paused, `canceled` Cancelled, `notFound` Failed(rejected) with 404,
  `failed` by exception type (401/403 `unauthorized`, other HTTP `rejected`, connection `network`, file system `storage`,
  URL `invalidRequest`, resume `killed`, else `other`). The exception's text is never read. The plugin reports a fraction,
  so `received` is 0 and `total` null when the server gave no size.
- **A finished file is checked** by the backend (size, then SHA-256, `Verifying` first): the engine does not check files.

## Rules

- **Only its own group.** Callbacks (`registerCallbacks(group:)`), tracking (`trackTasksInGroup`) and notifications
  (`configureNotificationForGroup`) are for `fespalier.download` and nothing else, registered **before**
  `resumeFromBackground`. Never listen to `FileDownloader().updates` (the app's single-subscription stream), never call the
  global `start`, `reset`, `configure` or **`rescheduleKilledTasks`** (no group parameter; it would enqueue the app's tasks).
  `lib/src/plugin_transport.dart` is the one file that calls the plugin, and `test/no_timers_test.dart` greps for the rest.
- **The plugin's database is not the registry**; `FileDownloadStore` is. A task the plugin lists as running that the system
  lost ends `Failed(killed)` (unless its file is whole) and `retry` starts it again with a fresh grant.
- **No foreground service.** `Config.runInForeground` is the app's global and is never set. The `dataSync` type in the plugin's
  job service declaration is the plugin's own attribute, not a service this package starts.
- **Notifications are off unless configured**, per backend and group; the title is your text and the body the download's
  `displayName`. `userInitiated` without a `running` text is `Failed(notificationsRequired)` and nothing is queued. **Never
  ask for the notification permission in the package**; the app does, with a rationale.
- **Auth is what the request carries**: a short-lived grant. Headers sit **in plaintext in the OS task queue** until the
  task ends and a retry sends the same ones (`retries: 0` where that matters). No refresh token; no DPoP (native callbacks
  cannot reach the app's state).
- **Telemetry** is the engine's span with `background` true; the backend adds none and reports no URL, id, path, header or
  error text.

## Setup (the plugin's, read from 9.6.4)

Android: Kotlin 2.1.0+, `POST_NOTIFICATIONS` (API 33+) and the app's own runtime request, `RUN_USER_INITIATED_JOBS` and the
`UIDTJobService` declaration (as the plugin's README gives it), `android:launchMode="singleTask"`. iOS: 14.0+, HTTPS (or ATS),
`UNUserNotificationCenter.current().delegate = self` in `AppDelegate.swift` for notifications, and optionally the
`BYPASS_PERMISSION_IOS…PHOTOLIBRARY` switches to drop the Photo Library `Info.plist` keys. macOS: the network client
entitlement. The full list is "Android and iOS setup" in `docs/downloads.md`.

## Test it

`package:fespalier_download_background/testing.dart`: `FakeBackgroundTransport` plays the operating system
(`emitStatus`, `emitProgress`, `tap`), is seeded with `records`, `active` and `undelivered`, and records `calls`,
`enqueued`, `paused`, `resumed`, `cancelled`, `plans` and `leaked`. Build the backend with `transport:`, `platform:`
(`BackgroundPlatform.android`) and `files:` (`FakeTransferFiles`). No test runs the plugin.

## UNCHECKED (issue #158)

Never write these as fact; no device has answered them: when a notification tap arrives after a cold start relative to
`resumeFromBackground`; whether a resume with new headers sends them; whether a failed update carries the server's
response headers; whether the plugin's database delete is scoped to a group; whether an Android task cycling every nine
minutes reuses its stored headers; what happens to a group's updates when the app opened the plugin first; whether the
package builds for the web.
