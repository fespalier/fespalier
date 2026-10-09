# fespalier_download_background

Background downloads for [fespalier](https://github.com/fespalier/fespalier) (since 0.15.0): a `DownloadBackend` for
[`fespalier_download`](../fespalier_download) over
[`background_downloader`](https://pub.dev/packages/background_downloader). The operating system runs the transfer
(WorkManager, and user-initiated data transfer jobs on Android 14 and newer; a background `URLSession` on iOS), so it goes
on while the app is in the background and after the app was closed.

fespalier itself has no download feature: no file kind, no `fespalier:` key, no `fsp` command, and the generated code is the
same bytes. The full guide is
[docs/downloads.md](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#the-background-backend). This page is
the short version.

## Install

Add it next to fespalier and `fespalier_download`, with the same `url` and the same `ref` for all three: pub resolves them
to one package each only if they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.14.0
  fespalier_download:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_download
      ref: v0.14.0
  fespalier_download_background:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_download_background
      ref: v0.14.0
```

<!-- x-release-please-end -->

Needs Dart 3.13 and **Flutter 3.47 or newer**: `background_downloader` 9.6 needs them, and this package was written against
9.6.4. That is why it is a package of its own and is not in CI's Flutter 3.32 floor job; an app on an older Flutter keeps
`HttpDownloadBackend`. The platform setup (Kotlin 2.1, `POST_NOTIFICATIONS`, the user-initiated job service, iOS 14, the
notification delegate) is in
[Android and iOS setup](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#android-and-ios-setup).

## Wire it

```dart
final engine = Downloads(
  backend: BackgroundDownloaderBackend(
    notifications: const DownloadNotifications(
      running: 'Downloading',
      complete: 'Download finished',
      failed: 'Download failed',
    ),
  ),
  store: FileDownloadStore(bases: bases),
  files: TransferDownloadFiles(bases: bases),
);
// startup(): override downloadsEngine with it, and open it before anything of the app's own calls
// FileDownloader().start() or resumeFromBackground().
```

`engine.start(DownloadRequest(..., priority: DownloadPriority.userInitiated, displayName: 'Manual 42'))` queues the
transfer. The `Downloads` engine, the providers and the registry are `fespalier_download`'s.

## What it does

- **Honest capabilities.** On Android and iOS: pause, resume across a restart, background, `userInitiated`, `unmetered`;
  `notifications` only when you gave it a `running` text. The desktop pauses and nothing else. On the web every start ends
  `Failed(unsupported)` and the plugin is never touched.
- **A request becomes a task**: the id is the task id; the file is a base folder, a sub-folder and a name, never an
  absolute path; `userInitiated` is priority 0 (a user-initiated job on Android 14 and newer) and `background` is 5; every
  task allows pause; `unmetered` is `requiresWiFi`; the size and SHA-256 travel in the task's metadata. **A foreground
  service is never asked for.**
- **A plugin update becomes a status**: 401 and 403 are `unauthorized`, any other HTTP error `rejected`, a connection error
  `network`, a file system error `storage`; only the exception's type and code are read, never its text. A finished file is
  checked against the size and digest (`Verifying`, then `Complete` or a mismatch).
- **Notifications are off unless configured**, and `userInitiated` without one is `Failed(notificationsRequired)`. **The
  package never asks for the notification permission.**
- **Auth is what the request carries**: a short-lived grant (a URL or a download-scoped header). **Headers are written to
  the operating system's task queue in plaintext** until the task ends, and a retry sends the same ones. Never a refresh
  token. A proof per request (DPoP) is impossible there: the plugin's native callbacks cannot reach the app's state. With a
  `grantor` on the engine, `enqueue` and `resume` get the granted request and headers; a renewal after a 401 is a cancel and
  a new task, and the late `canceled` update of the old one is dropped.

## Rules

- **Only its own group** (`fespalier.download`): callbacks are registered, tracked and configured for that group. The
  app's `FileDownloader().updates` stream is never listened to, and the plugin's global `start`, `reset`, `configure` and
  `rescheduleKilledTasks` are never called (`test/no_timers_test.dart` greps `lib/` for each; only
  `lib/src/plugin_transport.dart` may register or remove callbacks). Callbacks are registered before
  `resumeFromBackground`.
- **The plugin's database is not the registry.** `fespalier_download`'s `FileDownloadStore` is. A task the plugin lists as
  running that the operating system lost ends `Failed(killed)`, and `retry` starts it again with a fresh grant: it is not
  enqueued again from what the task carries.
- **No timer, no polling, no listener of its own**, and nothing that opens a dialog, a menu, a sheet or a snack bar.
- **Telemetry** is the engine's `fespalier.download.transfer` span with `background` true; the backend adds none, and no
  URL, id, path, header or error text is reported.

## Test it

`package:fespalier_download_background/testing.dart` has `FakeBackgroundTransport`: the test plays the operating system
(`emitStatus`, `emitProgress`, `tap`) and reads what the backend asked of the plugin. Pass it as `transport:` (with
`platform:` and `files:`) to `BackgroundDownloaderBackend`.

## What no test shows

There is no device in CI. `PluginTransport`, the one file that calls `background_downloader`, is not run by any test, and the
following depend on behaviour of the operating system and the plugin that nobody has run on a device; they are tracked in
[issue #158](https://github.com/fespalier/fespalier/issues/158) and are **UNCHECKED**:

- when a notification tap arrives after a cold start, relative to `resumeFromBackground` (the `fespalier_download` adapter answers a cold tap in `launch()` and a later one as a warm tap, so the app works either way);
- whether a resume with new headers is sent with them;
- whether a failed update carries the server's response headers (the plugin documents the status code in its exception);
- whether the plugin's database delete is scoped to the group (its source says so; it was read, not run);
- whether an Android task that cycles every nine minutes reuses the headers it was enqueued with;
- whether the plugin's cancel keeps the partial file (a renewed grant or a retry is a cancel and a new task);
- what happens to updates of the group when the app opened the plugin itself before this backend;
- that the package builds for the web (the web path never calls the plugin).
