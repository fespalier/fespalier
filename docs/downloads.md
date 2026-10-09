# Downloads: fespalier_download

`fespalier_download` (since 0.15.0) is the vocabulary of a file download that outlives a screen: a **request** (an id, a
URL, a file and what the file must be), a **status** that says where the download stands, and the **ports** a transfer
engine is built from. It is pure Dart over `package:http` with no platform plugin, so it resolves on Flutter 3.32,
fespalier's floor, and an app that lists it links nothing native.

fespalier itself has no download feature: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart` is the
same bytes. The package is a companion, installed like `fespalier_flags`.

**What is in this release, and what is not.** This release is the model, the telemetry names, the fakes, the engine,
`Downloads`, which starts, pauses, resumes, retries, cancels and removes a download over a backend you give it and settles
the registry after a restart, a **foreground backend**, `HttpDownloadBackend`, that downloads over an `http.Client`
while the app runs, a **durable registry**, `FileDownloadStore`, and the **providers** a widget watches (`downloads`,
`downloadStatus`). A download that must go on while the app is closed is the job of the **background backend**, in the
separate package `fespalier_download_background` (since 0.15.0, Flutter 3.47 or newer, over `background_downloader`; see
[The background backend](#the-background-backend)). Notification taps as routes and uploads come in a later release of the
same line, and this page grows with it.

Contents: [Install](#install), [Requests and files](#requests-and-files), [Status](#status),
[Starting a download](#starting-a-download), [After a restart](#after-a-restart), [Sign-out](#sign-out),
[The foreground backend](#the-foreground-backend), [The background backend](#the-background-backend),
[Android and iOS setup](#android-and-ios-setup), [Credentials](#credentials), [In a widget](#in-a-widget), [Testing](#testing).

## Install

Add the package next to fespalier with the **same `url` and the same `ref`**: pub resolves the two to one package only
then. The tag must be a release that contains the package (0.15.0 or later). The install block, with the version
release-please keeps current, is in [the package's README](../packages/fespalier_download/README.md#install).

The package depends on `http` (`>=1.5.0 <2.0.0`, the first release with abortable requests), a pure Dart package, and on
fespalier and `fespalier_http` (for `HttpCredentials`; list it yourself, with the same `url` and `ref`, only if your code imports it). It resolves on Flutter 3.32 with the lowest versions it allows (CI's `floor` job runs `flutter pub downgrade`,
`flutter analyze` and `flutter test` on the package).

## Requests and files

A download is a `DownloadRequest`:

```dart
final request = DownloadRequest(
  id: 'manual-42',
  url: Uri.parse('https://files.example.com/manual-42.pdf'),
  file: const DownloadLocation(DownloadBase.support, 'manuals/manual-42.pdf'),
  bytes: 1048576, // optional: a different size ends Failed(sizeMismatch)
  sha256: '…64 hex digits…', // optional: a different digest ends Failed(hashMismatch)
);
```

- **A file is a base and a relative path, never an absolute path.** An iOS app's container path changes between launches,
  so a stored absolute path goes stale. `DownloadBase` is `support` (the application support folder, the default),
  `cache` (the platform may empty it) or `documents`. A backend resolves a location to a path for the moment of use and
  the path is never stored.
- **`DownloadLocation.isValid`** refuses an empty path, a leading `/`, an empty segment (`a//b`, a trailing `/`), a `..`
  segment, a `\` and a NUL character. Check it for a path that came from outside the app (a server's file name).
- **`DownloadRequest.isValid`** is false for an empty id, a URL that is not an absolute http or https URL with a host and
  no credentials in it, an invalid `file`, a negative `bytes`, a `sha256` that is not 64 hex digits, or an empty header
  name.
- **`network`** is `DownloadNetwork.any` or `unmetered` (Wi-Fi only), and **`priority`** is `DownloadPriority.background`
  (the default) or `userInitiated` (the person asked just now and watches it).
- **`toString()` of a request prints no field**: only `DownloadRequest`. The URL can be a capability, the headers a
  credential and the display name a person's own words, and a request ends up in a log line or an error report. A
  `DownloadLocation` prints its base only.
- **Headers may be kept on disk in plaintext** by a backend while a download is queued. Never put a refresh token or a
  long-lived bearer in one. The documented way to authorise a transfer is a short-lived capability: before starting, the
  app makes its normal signed request, the server answers with a short-lived single-file URL, and the request carries that.

## Status

A download is in one `DownloadStatus` at a time, a sealed family you can `switch` over exhaustively:

| Status                      | Meaning                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------- |
| `Absent`                    | No download is known with that id.                                                       |
| `Queued`                    | Handed to the backend, not running yet.                                                  |
| `Waiting(WaitReason)`       | Not running: `network`, `unmetered`, `retry` (an attempt failed) or `slot` (it is next). |
| `Running(received, total?)` | Transferring; `total` is null when the server did not say.                               |
| `Paused(received, total?)`  | Stopped on purpose, the bytes kept.                                                      |
| `Verifying`                 | Received; the size and the digest are being checked.                                     |
| `Complete(file, bytes)`     | The file is in place and checked.                                                        |
| `Failed(DownloadFailure)`   | Ended without a file.                                                                    |
| `Cancelled`                 | Stopped for good by the app; nothing kept.                                               |

`DownloadFailure` is a value, never an error's text: `unsupported` (the web), `invalidRequest`, `network`, `rejected` (an
HTTP error that asking again will not fix), `unauthorized` (401 or 403), `sizeMismatch`, `hashMismatch`, `storage`,
`notificationsRequired`, `killed` and `other`. Every status prints its state and numbers, never a path.

The ports are the seams the engine is built on, and an app does not call them: `DownloadBackend` (the transfer
machinery, with `DownloadCapabilities` saying what it can do and `DownloadEvents` as the way back), `DownloadStore` (the
durable list of what the app asked for: it is a registry, not a cache, so nothing is evicted) and `DownloadFiles`.

**Telemetry** (the names are the contract, add never rename): `fespalier.download.transfer` for one transfer with
`result` (`complete`, `failed`, `cancelled`), `failure`, `resumed`, `background`, `network` and `priority`;
`fespalier.download.reconciled`; and `fespalier.download.open` with `routed`. Their values are constants, booleans and enum
names: **never a URL, an id, a path, a display name, a header or an error's text**. `FespalierDownloadConventions` has
them, and `test/telemetry_test.dart` pins each one.

## Starting a download

`Downloads` is the engine. It imports no Riverpod, so it works in a test or a background isolate as it is; a later release
adds the providers on top.

```dart
final downloads = Downloads(backend: backend, store: store, files: files);
await downloads.open(); // before anything else
downloads.observe((id, status) => debugPrint('$id is $status')); // one owner

await downloads.start(request);
downloads.statusOf('manual-42'); // Queued, then what the backend reports
await downloads.pause('manual-42'); // true when the backend took the request
await downloads.resume('manual-42');
await downloads.retry('manual-42'); // from Failed only
await downloads.cancel('manual-42'); // stops it for good: Cancelled, nothing kept
await downloads.remove('manual-42'); // also deletes the file: Absent
final path = await downloads.pathOf('manual-42'); // null unless Complete
```

- **`start` never throws for a bad request.** An invalid request, or a `file` that is not a safe relative path, ends
  `Failed(invalidRequest)` and is not registered, so there is nothing to `retry`: start it again once it is right. A
  `userInitiated` request on a backend whose capabilities have no notifications ends `Failed(notificationsRequired)`.
  Starting an id that is already queued, running, paused or complete does nothing: it is the same download. Calling
  `start` before `open` is a `StateError`.
- **The backend reports, the engine does not guess.** `pause` and `resume` ask the backend and return what it answered;
  the status moves when the backend says so (`Paused`, `Running`), except that a resumed download shows `Queued` at once.
  A backend that cannot pause (its `capabilities.pause` is false) makes `pause` return false.
- **`retry` starts a `Failed` download again** from the request the registry holds. After `sizeMismatch` or `hashMismatch`
  it deletes the file first; after a network failure it keeps the bytes so the backend can go on from them.
- **`statuses` and `statusOf`** are the whole state: `statusOf` answers `Absent` for an id it does not know. A 401 or 403
  that the backend reports with a failed status ends `Failed(unauthorized)`.
- **`observe` is one owner slot.** A second call replaces the first, `observe(null)` clears it, and `close()` clears it
  too, so an engine that outlives a screen holds nothing of it. An observer that throws costs only its own update.
- **Generations drop what is stale.** Each id has a generation that a cancel, a remove, a restart and a sign-out move on.
  An event for an id the engine no longer knows, or for a download that has ended, is dropped; so is the rest of a
  `start` whose download was cancelled or cleared while it waited on the backend. A backend must not report on a
  transfer it was told to cancel: the engine cannot tell a late report of an old attempt from a new one once the same id
  has been started again. The same holds for `cancel` and `remove` themselves: if the id is started again while the
  backend is still stopping the old download, they stop there and leave the new download's registry entry and files alone.
- **Telemetry.** Each transfer is one `fespalier.download.transfer` span from its start to the state it ends in
  (`result`, and `failure` when it failed). Its attributes are only the constants of `FespalierDownloadConventions`:
  never a URL, an id, a path, a display name, a header or an error's text. With no sink installed the cost is a null check.

## After a restart

`open()` loads the registry from the `DownloadStore`, opens the backend and settles what ended while the app was not
running. Every entry starts as `Queued`; the backend then replays what it knows through `DownloadEvents` while it opens.

- A download the backend reports finished or failed ends `Complete` or `Failed`, and is reported once as
  `fespalier.download.reconciled` (the same `result` and `failure` attributes as a transfer).
- A download the backend reports as running goes on: it gets a transfer span with `resumed` true.
- A download the backend does not mention at all ends `Complete` when `DownloadFiles` finds its file (with the size the
  request names, when it names one) and `Failed(killed)` otherwise. Without a `DownloadFiles` it is `Failed(killed)`, so
  give the engine one when the backend does not replay finished downloads.
- A report about an id that is not in the registry is dropped: the backend's tasks that are not ours are not ours.

The registry is `FileDownloadStore` (see [In a widget](#in-a-widget)): a JSON file, so the list survives a
restart whatever the backend. A completed download keeps its registry entry, so `statusOf` and `pathOf` still answer after the next restart. Only
`remove`, `cancel` and [sign-out](#sign-out) drop an entry. Calling `open` twice does the work once; `close()`
unregisters from the backend and clears the observer, and the transfers the platform owns go on.

## Sign-out

`clearAccount()` ends everything the signed-in person had: it cancels every download, deletes the files and the registry,
moves every generation on and reports `Absent` for each id to the observer. Nothing an earlier attempt was still doing,
and no event that arrives afterwards, reaches the next account. Call it where the app signs out, before the next person
can sign in, as `crateStackAccount.clear` is in `fespalier_cratestack`.

## The foreground backend

`HttpDownloadBackend` (since 0.15.0) is a `DownloadBackend` that runs each download as a resumable HTTP transfer in the
app's own process, with the `http.Client` you give it, so its timeouts, proxy and certificates apply. It is pure Dart: the
base folders are yours to name, because the package depends on no plugin.

```dart
Future<String> bases(DownloadBase base) async => switch (base) {
  DownloadBase.support => (await getApplicationSupportDirectory()).path,
  DownloadBase.cache => (await getApplicationCacheDirectory()).path,
  DownloadBase.documents => (await getApplicationDocumentsDirectory()).path,
};

final downloads = Downloads(
  backend: HttpDownloadBackend(client: client, bases: bases),
  store: store,
  files: TransferDownloadFiles(bases: bases),
);
```

- **What it can do, honestly.** Its capabilities are `pause` and nothing else: no background, no notifications, no
  user-initiated priority, no `unmetered`, and a transfer does not survive the app being closed. A request with
  `DownloadNetwork.unmetered` is refused (`start` ends `Failed(other)`): the foreground cannot tell a metered network from
  another, and spending mobile data the app said not to is worse than not starting. It runs every start at once.
- **Where the bytes go.** They arrive in `<file>.part`, with the server's `ETag` (a strong one) or `Last-Modified` beside
  it in `<file>.part.etag`. A file at its destination is always whole and checked: the part is moved there, atomically,
  only when it has the `bytes` and the `sha256` the request names (the digest is computed in another isolate, so a large
  file does not take frames).
- **Who uses it.** The foreground transfer is the one `fespalier_maps`' file packs run on (since 0.15.0): `FilePacks` builds an
  `HttpTransfer` per attempt and maps its result to a `PackStatus` (a 401 or 403 stays `rejected` there), so the two packages
  resume, verify and move a file the same way. See [File packs](maps.md#file-packs).
- **Resuming.** A pause, a network failure and an app restart leave the part. The next attempt asks for
  `Range: bytes=<size of the part>-` with `If-Range: <validator>`, and appends. A server that ignores `Range` (it answers 200) makes the transfer start again from the first byte; a 206 whose validator is not the part's, or at another offset,
  and a 416 to a part the server no longer has the end of, each restart once. A part with no validator and no `sha256`
  starts again from the first byte, since nothing says it belongs to the file the server has now. After a restart the
  engine finds the download ended (`Failed(killed)`), and `retry` goes on from the part.
- **Cancel.** `cancel` and `remove` abort the request in flight (the client must honour `http.Abortable`, as the
  `package:http` clients do), so a connection that sends nothing cannot hold them up. A transfer that was running or paused
  loses its part; one that already ended keeps it, so `retry` can continue. Give the engine a `TransferDownloadFiles` so
  `remove`, `cancel` and sign-out also delete the finished file, the part and the validator.
- **Failures** are values: `network` (no connection, a body that ended short), `rejected` (any other HTTP error, with the
  status code), `unauthorized` (401 or 403), `sizeMismatch`, `hashMismatch`, `storage` (a write or a move the device refused)
  and `unsupported`. A mismatch deletes the part.
- **The web.** Where there is no `dart:io`, the file store answers `UnsupportedError` and every start ends
  `Failed(DownloadFailure.unsupported)` before any request is made; the package compiles for the web all the same. Hand the
  browser the URL instead.
- **Telemetry** is the engine's `fespalier.download.transfer` span, with `background` false. The transfer itself reports
  nothing, and a URL, an id, a path or a header never leave it.

Underneath, `HttpTransfer` is the transfer of one file, with no state beyond the attempt (`run`, `pause`, `stop`), and
`TransferFiles` the path-level file port it drives (`dart:io` by default). They are exported for a backend of your own;
most apps never touch them.

## The background backend

`fespalier_download_background` (since 0.15.0) is a second package with a `DownloadBackend` over
[`background_downloader`](https://pub.dev/packages/background_downloader): the **operating system** runs the transfer
(WorkManager, and user-initiated data transfer jobs on Android 14 and newer; a background `URLSession` on iOS), so it
goes on while the app is in the background and after the app was closed. It is a package of its own, and not part of
`fespalier_download`, because `background_downloader` 9.6 needs Dart 3.13 and **Flutter 3.47**: an app on an older
Flutter keeps the foreground backend and resolves as before, and the package is left out of CI's `floor` job as
`fespalier_sign_keypair` is. The install block is in
[the package's README](../packages/fespalier_download_background/README.md#install). It was written against
`background_downloader` **9.6.4**, whose sources and documentation were read, not recalled.

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
await engine.open(); // before anything of your own calls FileDownloader().start()
await engine.start(
  DownloadRequest(
    id: 'manual-42',
    url: grantUrl, // short-lived, from a signed request made in the foreground
    file: const DownloadLocation(DownloadBase.support, 'manuals/manual-42.pdf'),
    bytes: 1048576,
    sha256: digest,
    priority: DownloadPriority.userInitiated,
    displayName: 'Manual 42',
  ),
);
```

- **What it can do, honestly.** On Android and iOS: pause, resume across a restart, background, `userInitiated` and
  `unmetered`. `notifications` is true only when you gave it a `running` text. On the desktop it can pause and nothing else
  (the plugin has no operating-system background mode there, no notification and no network constraint), and a request with
  `DownloadNetwork.unmetered` is refused. On the web (and Fuchsia) every start ends `Failed(DownloadFailure.unsupported)`
  and the plugin is never touched.
- **What a request becomes.** The id is the task id; the file is the plugin's base folder (`support` is the application
  support folder, `cache` the temporary one, `documents` the documents folder), a sub-folder and a file name, never an
  absolute path. `userInitiated` is priority 0, which the plugin runs as a **user-initiated data transfer job on Android 14
  and newer** (when a notification is configured and the job service is declared, see
  [Android and iOS setup](#android-and-ios-setup)) and as a plain high-priority task elsewhere; `background` is the
  plugin's default priority 5. Every task allows pause, which is also how the plugin continues a long download across
  WorkManager's nine-minute cycles (without it, or without priority 0, an Android task stops at the limit).
  `DownloadNetwork.unmetered` is `requiresWiFi`: on Android 9 and newer a true Wi-Fi requirement, and on iOS "no
  cellular", which a metered hotspot satisfies. **A foreground service is never asked for**: the plugin's
  `runInForeground` configuration, which would make it a `dataSync` foreground service, is global to the app, and this
  package never sets a global.
- **Only its own group.** The tasks are in the plugin group `fespalier.download`, and callbacks are registered, tracked
  (`trackTasksInGroup`) and configured (notifications) for that group alone. The app's own `FileDownloader().updates`
  stream, a single-subscription stream that belongs to the app, is never listened to, and the plugin's global `start`,
  `reset`, `configure` and `rescheduleKilledTasks` are never called (the last has no group parameter and would enqueue
  the app's own tracked tasks again): `test/no_timers_test.dart` greps for each. Callbacks are registered **before**
  `resumeFromBackground`, so what finished while the app was away reaches the engine. **Open the engine before the app
  calls `FileDownloader().start()` or `resumeFromBackground()` itself**: the plugin delivers what it kept once, and an
  update for a group with no callbacks goes to the app's `updates` stream, not to the engine.
- **The plugin's database is not the registry.** It prunes itself (ten days, 500 records) whenever the app asks it to, and it is the plugin's. The
  registry is the engine's `FileDownloadStore`. At `open()` the plugin's records for the group are replayed to the engine
  as hints. A task the plugin still lists as running or enqueued that the operating system no longer has is **not**
  enqueued again from the stored task (the grant it carries may have expired): the engine ends it `Failed(killed)` unless
  its file is whole, and `retry` starts it again, with a fresh grant.
- **The file is checked.** The size and the SHA-256 of the request travel in the task (its `metaData`, which holds no
  URL, header or name), and when the plugin says a download finished, the backend reports `Verifying`, compares them and
  reports `Complete` or `Failed(sizeMismatch)` or `Failed(hashMismatch)`. That includes a download that finished while the
  app was away: `open()` waits for those checks before the engine settles the registry.
- **Failures are values.** An HTTP 401 or 403 is `unauthorized` (and the engine reads the code); any other HTTP error is
  `rejected`; a plugin `notFound` is `rejected` with 404; a connection error is `network`; a file system error is
  `storage`; a resume that could not be done is `killed`. Only the exception's type and code are read, never its text.
- **Notifications are off unless you configure them,** per backend (`notifications:` or `configureNotifications`), for its
  own group only: the title is your text and the body is the download's `displayName`. A `userInitiated` request on a
  backend without a `running` notification ends `Failed(notificationsRequired)` and nothing is queued, because Android
  requires a visible notification for a user-initiated job. **The package never asks for the notification permission**,
  on either platform: that is the app's, with a rationale of its own (`FileDownloader().permissions` or any permission
  package); the plugin shows no notification while it is not granted.
- **Auth is what the request carries.** The documented path is a short-lived capability: the app makes its normal signed
  request in the foreground, the server answers with a short-lived URL (or a download-scoped header), and that is what the
  task holds. **The headers of a task are written to the operating system's task queue in plaintext until it ends,** and a
  retry sends the same ones; set `BackgroundOptions(retries: 0)` where a stale grant must not be replayed. Never a refresh
  token, never a long-lived bearer. A proof per request (DPoP) cannot be done: the plugin's native callbacks run with no
  access to the app's state or its plugins. **A grant works here as it does anywhere** ([Credentials](#credentials)): the
  engine hands `enqueue` and `resume` the granted request (its URL) and the grant's headers, and after a 401 or 403 it
  cancels the attempt and enqueues again with a renewed grant. The backend drops the plugin's late `canceled` update for the
  attempt it cancelled (told apart from its successor by the task's creation time), so a renewed grant or a `retry` is not
  ended by the answer to its own cancel. Without a grantor the download ends `Failed(unauthorized)`, and `retry` starts it
  again.
- **Telemetry** is the engine's `fespalier.download.transfer` span with `background` true. The backend reports nothing
  of its own, and a URL, an id, a path, a header or an error's text never leave it.
- **What no test shows (UNCHECKED).** There is no device in CI: `PluginTransport`, the one file that calls the plugin, is
  a thin layer that no test runs, and the backend's logic is tested through `FakeBackgroundTransport`. These depend on
  behaviour of the operating system and the plugin that nobody has run on a device, and are tracked in
  [issue #158](https://github.com/fespalier/fespalier/issues/158): when a notification tap arrives after a **cold start**
  relative to `resumeFromBackground` (the engine's `tapped` is wired in 0.15.0 only as far as the backend reporting it);
  whether a **resume with new headers** is sent with them (the backend passes them; whether the plugin uses them is not
  known); whether a **failed update carries the server's headers**, or only the status code the plugin documents in its
  exception; whether the plugin's **database delete is scoped to the group** (its source deletes record by record for the
  group, which was read, not run); whether an Android task that **cycles every nine minutes reuses the headers** it was
  enqueued with (which would replay an expired grant); whether the plugin's cancel keeps the partial file (a renewed
  grant or a `retry` is a cancel and a new task, so it may start again from the first byte); how an update for a group with no callbacks arrives when the app
  opened the plugin first; and whether the package builds for the web (the web path never calls the plugin, but the
  plugin's own web support was not compiled here).

## Android and iOS setup

These steps are the plugin's, read from `background_downloader` 9.6.4's README and `doc/`, and nothing here is done for
you. Follow the plugin's current README where it moves.

**Android.**

- **Kotlin 2.1.0 or newer** in the app (`org.jetbrains.kotlin.android` version `2.1.0` or later in `settings.gradle`). The
  plugin itself is built with Kotlin 2.3.20 and compiles against Android SDK 36. Its README says the minimum API is 21;
  its `build.gradle` sets `minSdkVersion 23`, so treat 23 as the floor.
- **`android.permission.POST_NOTIFICATIONS`** in the app's `AndroidManifest.xml`, for Android 13 (API 33) and newer, and
  a runtime request for it that the app makes (this package does not):

  ```xml
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
  ```

- **User-initiated jobs (Android 14 and newer).** `userInitiated` requests run as user-initiated data transfer jobs, which
  have no execution time limit. The plugin's documentation asks for this in the app's manifest, and falls back to
  WorkManager when the permission is missing:

  ```xml
  <uses-permission android:name="android.permission.RUN_USER_INITIATED_JOBS" />

  <service
      android:name="com.bbflight.background_downloader.UIDTJobService"
      android:permission="android.permission.BIND_JOB_SERVICE"
      android:exported="true"
      android:foregroundServiceType="dataSync" />
  ```

  The `foregroundServiceType` is the plugin's own attribute on its job service: it is **not** a foreground service that
  this package starts, and the plugin's separate global switch for one (`runInForeground`) stays off. The plugin's own
  manifest declares the same service, so the merge supplies it even without this block; whether that alone is enough on a
  device is UNCHECKED, so declare it as the plugin's README says.

- **`android:launchMode="singleTask"`** on the main activity, which the plugin asks for so that a notification tap reaches
  the running app.
- **Without** user-initiated jobs, Android limits a standard task to nine minutes (two minutes for a priority below 5):
  every task here allows pause so that the plugin resumes across the cycles.

**iOS.**

- **iOS 14.0 or newer.** A background `URLSession` needs no capability or manifest entry; the plugin's README says "no
  special setup is required". iOS requires HTTPS unless App Transport Security is relaxed. A background transfer must
  finish within the system resource timeout (four hours by default).
- **Notifications:** set the notification centre's delegate in `AppDelegate.swift`, or the plugin's notifications do not
  show while the app is open:

  ```swift
  UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
  ```

  iOS shows no progress bar and one `running` notification, which changes only when the state does.

- **Photo Library keys.** The plugin can move files into the Photo Library, so Apple wants `Info.plist` usage strings
  even if you never do; this package never does. With Swift Package Manager, set `BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY=1`
  and `BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY=1` in the environment of `flutter build ios` to compile that code out
  (CocoaPods: the `-D BYPASS_PERMISSION_…` Swift flags in the `Podfile`). `flutter clean` after changing them.

**macOS** needs `com.apple.security.network.client` in both entitlements files; **Windows and Linux** need nothing. The
desktop has no operating-system background mode, so a download there stops with the app.
## Credentials

A download is a request the operating system may send **later, in another process, with no access to your app's session,
its plugins or its signing key**. That decides what credentials can be (since 0.15.0).

**The documented path is a short-lived capability grant.** Before the download starts, in the foreground, the app makes a
normal signed request (a `fespalier_http` client, so the session, its refresh and its proofs apply there), and the server
answers with something good for one file for a few minutes: a single-file URL and/or headers scoped to that download. The
transfer carries only that.

```dart
Future<DownloadGrant?> grant(DownloadRequest request, {required bool renewal}) async {
  final answer = await signedClient.post(Uri.parse('https://api.example.com/files/${request.id}/grant'));
  return DownloadGrant(url: Uri.parse(urlOf(answer))); // expires in minutes, names one file
}

final downloads = Downloads(backend: backend, store: store, files: files, grantor: grant);
```

- **`DownloadGrant`** is a `url` (replaces the request's own for this attempt) and `headers` (added for this attempt),
  either or both. Its `toString()` prints no field. The engine never stores it: the registry keeps the request as you made
  it, so a grant URL is not in `fespalier_downloads.json`. (A background backend may still keep the request it was handed
  in plaintext while it is queued, which is why a grant must expire.)
- **When it is asked.** The `grantor` is called before each `start`, `retry` and `resume` (`renewal: false`), and **once
  more after a 401 or 403** (`renewal: true`). Return null to send the request as it is.
- **After a 401 or 403 the engine asks once.** It cancels the failed attempt, keeping the bytes the backend can continue
  from (the foreground backend keeps its `.part`, and the new attempt sends `Range`), and enqueues again with the new
  grant. A second 401 or 403 ends `Failed(unauthorized)`; so does a grantor that throws or a grant whose URL is not a valid
  http or https URL. Nothing of the error is kept. There is no retry loop and no timer.
- **A newer state wins.** A `cancel`, `remove`, restart or `clearAccount` while the grant request is in flight drops its
  answer: nothing reaches the backend after it.
- **A resumed transfer keeps its address.** On `resume` only the grant's headers are used; an expired URL earns its 401 and
  is renewed then.
- **Telemetry.** The transfer span's end carries `fespalier.download.regranted: true` when a renewal was asked (absent
  otherwise). Never the grant, a URL or a header.

**Plain headers are allowed, and they are stored in plaintext.** `DownloadRequest.headers` may be kept by a backend, on
disk, while a download is queued; `FileDownloadStore` keeps them in the registry. Use them for something that is public
or expires in minutes, never for a credential you would mind finding in a backup.

**Never a refresh token or a long-lived bearer** in a request or a grant: anything a background backend persists can be
read back from the device, and a download has no way to refresh a token itself.

**Why not the session's own credentials in the background.** A DPoP proof is bound to one method, one URL and a fresh
nonce and timestamp, so it would have to be signed for each send, by a key the operating system's native callbacks cannot
reach. Authenticating every send is therefore possible only where your Dart code makes the send.

**The foreground backend can do exactly that.** `HttpDownloadBackend(credentials: credentials)` takes any
`HttpCredentials` from `fespalier_http` (`fespalier_auth`'s `Authorizer` is one). For each request it sends it asks
`credentials.authorize('GET', url)` and adds the headers it returns (nothing for an origin the credentials do not cover),
and after a 4xx answer it asks `credentials.retry(attempt, statusCode:, headers:)` and, if told to, sends again with
`authorize(..., previous: attempt)`, at most three sends, the way `SessionClient` does. The credentials live in memory for
the send. A credentials object that throws ends the download `Failed(unauthorized)`. When the refusal stands, the engine's
grant renewal above still applies, so the two compose. Choose by where the transfer runs: `credentials` for a foreground
download to your own API, a grant for anything a background backend sends or a CDN that does not know your session.

**Replay.** A transfer sends one `GET`, which is safe to send again, so the re-send above is allowed. A request that is
not replay-safe (a `POST`, which uploads will be) must be sent once: no retry, no re-send after a 401, and no pause that
would cycle it. Nothing in this release sends one.

## In a widget

Three pieces connect the engine to the widget tree. **`FileDownloadStore`** is the durable registry: one JSON file,
`fespalier_downloads.json`, in the folder your `DownloadBases` names for `DownloadBase.support`. Every change writes
`fespalier_downloads.json.tmp` and renames it over the file, so a crash between the two leaves the previous file whole, and
writes are queued in order. It is never a `BoundedDataStorage` (that evicts the oldest entries; a download the person asked
for must not vanish). A missing, unreadable or corrupt file is an empty registry and never throws; an entry that is not
valid is skipped and the rest kept. A write that fails (a full disk) is dropped and the list in memory stays right for the
run, so a download never fails because its registry could not be saved. `clear()`, which sign-out calls, deletes the file.
It needs no `path_provider` of its own: the base folder comes from the same `DownloadBases` function the backend uses. On
the web, where there are no files, the registry is in memory only (every start ends `Failed(unsupported)` there anyway).
**A request's headers are written to this file in plaintext**: never a long-lived credential in a header.

**`downloadsEngine`** is the provider of the `Downloads` engine, and it has **no default**: reading it without an override
throws a `StateError` that names the override to add. Build the engine once and override the provider with it:

```dart
// lib/app/startup.dart
Future<String> bases(DownloadBase base) async => switch (base) {
  DownloadBase.support => (await getApplicationSupportDirectory()).path,
  DownloadBase.cache => (await getTemporaryDirectory()).path,
  DownloadBase.documents => (await getApplicationDocumentsDirectory()).path,
};

Future<List<Override>> startup() async => [
  downloadsEngine.overrideWithValue(
    Downloads(
      backend: HttpDownloadBackend(client: http.Client(), bases: bases),
      store: FileDownloadStore(bases: bases),
      files: TransferDownloadFiles(bases: bases),
    ),
  ),
];
```

**`downloads`** is a `NotifierProvider` holding the status of every download by id, and **`downloadStatus(id)`** is an
auto-dispose family that rebuilds a widget only when that one download changes (`Absent` when none is known). Watching
`downloads` opens the engine (so the restart settling of [After a restart](#after-a-restart) happens) and fills the
engine's one `observe` slot; when the provider is disposed the observer is cleared and the engine is closed (the transfers
the platform owns go on). An engine that cannot open (a store that threw) leaves `downloads` empty. The providers hold no
timer and no listener of their own, and the engine itself still imports no Riverpod. Because the slot is the provider's,
do not call `observe` on an engine that `downloads` watches.

```dart
class ManualTile extends ConsumerWidget {
  const ManualTile({super.key});

  static final request = DownloadRequest(
    id: 'manual-42',
    url: Uri.parse('https://files.example.com/manual-42.pdf'),
    file: const DownloadLocation(DownloadBase.support, 'manuals/manual-42.pdf'),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(downloads); // opens the engine; the page is the owner
    final status = ref.watch(downloadStatus('manual-42'));
    final engine = ref.read(downloadsEngine);
    return switch (status) {
      Running(:final received, :final total) => LinearProgressIndicator(
        value: total == null ? null : received / total,
      ),
      Complete() => const Text('Downloaded'),
      Failed() => TextButton(
        onPressed: () => engine.retry('manual-42'),
        child: const Text('Try again'),
      ),
      _ => FilledButton(
        onPressed: () => engine.start(request),
        child: const Text('Download'),
      ),
    };
  }
}
```

Acting goes through the engine (`ref.read(downloadsEngine).start(...)`); the state comes back through `downloads`. Call
`clearAccount()` where the app signs out, as [Sign-out](#sign-out) says.

## Testing

`package:fespalier_download/testing.dart` has the fakes, which need no network, platform or disk:

- `FakeDownloadBackend`: records what is asked (`enqueued`, `paused`, `resumed`, `cancelled`, `authorizations`), answers
  as `accepts` and `capabilities` say, and plays the platform through `emit(id, status, httpStatus:)` and
  `tap(id)` once a listener has called `open`. `replay: {id: status}` is what the platform reports at `open`, to test a restart.
- `MemoryDownloadStore`: a registry in memory (`entries`, `clearCalls`).
- `FakeDownloadFiles`: files as a map of sizes (`put`, `deleted`).
- `downloadTestOverrides(backend:, store:, files:)`: the overrides that bind `downloadsEngine` (so `downloads` and
  `downloadStatus`) to an engine over the fakes, for a `ProviderContainer` or `ProviderScope`. The test keeps the backend and
  plays the platform with `emit`; disposing the container closes the engine, as in an app.
- `FakeTransferFiles`: the path-level files of a transfer in memory (`putBytes`, `bytesOf`, `renames`, `failWrites`,
  `failRename`, `failDelete`, `unsupported` for the web), to test `HttpDownloadBackend` with a `MockClient`.

`package:fespalier_download_background/testing.dart` has `FakeBackgroundTransport`, which plays `background_downloader`
for one group so that `BackgroundDownloaderBackend` runs without a plugin or a device: the test plays the operating system
with `emitStatus`, `emitProgress` and `tap`, seeds the plugin's `records`, `active` ids and `undelivered` updates, and
reads `calls` (the order: callbacks registered before `resumeFromBackground`), `enqueued`, `paused`, `resumed`, `cancelled`,
`plans` and `leaked` (an update for a group with no callbacks, which the plugin would send to the app's `updates`
stream). Build the backend with `transport:`, `platform:` and `files:` (a `FakeTransferFiles`). The mapping functions
(`downloadTaskOf`, `downloadStatusOf`, `failureOf`, `progressOf`) are pure and public. None of this runs the plugin.

The model needs no widget: `DownloadRequest`, `DownloadLocation` and `DownloadStatus` are plain values, so a unit test
builds them and checks `isValid` and equality directly. The package's own tests do exactly that, including every refusal
of `isValid` and a check that no `toString` leaks a field.
