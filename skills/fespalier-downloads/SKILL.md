---
name: fespalier-downloads
description: "Files downloaded in a fespalier app with fespalier_download (since 0.15.0) — the model, ports, the Downloads engine and the foreground HttpDownloadBackend: Downloads (open, start, pause, resume, retry, cancel, remove, pathOf, statusOf, observe, clearAccount, reconciliation after a restart), DownloadRequest (id, URL, a DownloadLocation of a DownloadBase and a relative path, headers, size, sha256, DownloadNetwork, DownloadPriority) and its isValid, DownloadLocation.isValid refusing an absolute path, .., a backslash and NUL, the sealed DownloadStatus family (Absent, Queued, Waiting, Running, Paused, Verifying, Complete, Failed, Cancelled) with WaitReason and DownloadFailure, the DownloadBackend, DownloadStore and DownloadFiles ports, the fespalier.download telemetry that never carries a URL, an id or a path, HttpDownloadBackend (Range and If-Range resume from a .part file, size and sha256 checks, pause only, the web ends unsupported), TransferDownloadFiles, the FileDownloadStore registry (one JSON file written by atomic rename, never evicted, wiped at sign-out), the downloadsEngine, downloads and downloadStatus providers for a widget, the background backend of fespalier_download_background (BackgroundDownloaderBackend over background_downloader on Flutter 3.47: the operating system keeps the transfer going, only its own plugin group, notifications off unless configured, userInitiated refused without them, headers in plaintext in the OS queue, the Android and iOS setup, what no device has checked), the notification-tap adapter (`fespalier: adapters: [fespalier_download]`, `FespalierDownload.configure(backend:, store:, notifications:, route:)` in `main()`, `DownloadTap`, `DownloadTarget`, `DownloadRoute`, `Downloads.observeTaps`, the `fespalier.download.open` telemetry), and FakeDownloadBackend, MemoryDownloadStore, FakeDownloadFiles, FakeTransferFiles, FakeBackgroundTransport and downloadTestOverrides in tests. Load before adding a file download, an offline file, a progress screen or a resumable transfer, or when a request is not valid, a path is refused, or a test needs a download with no network."
---

# fespalier-downloads

> **Verified against fespalier `ca214107` (2026-10-09), release v0.14.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

**Since 0.15.0.** `package:fespalier_download` is the vocabulary of a download that outlives a screen: a request, a status
and the ports of a transfer engine. It adds no file kind, no `fespalier:` key and no `fsp` command, and `app.g.dart` is the
same bytes. It is pure Dart over `package:http`, with no platform plugin, and resolves on Flutter 3.32. A release that
predates 0.15.0 has no such package.

**Not built yet in this release: uploads.** The engine, `Downloads`, the foreground
`HttpDownloadBackend`, the `FileDownloadStore` registry, the providers and the background backend
(`fespalier_download_background`, Flutter 3.47, [`references/background.md`](references/background.md)) exist (since 0.15.0);
do not write an upload: it does not exist. Notification taps as routes are an adapter (below). A download that must go on while the app is closed uses the
background backend. What no device has answered about it (issue #158) is listed there as UNCHECKED: never state those as fact.

## The foreground backend

`HttpDownloadBackend(client: client, bases: bases)` (since 0.15.0) downloads with the app's `http.Client` while the app runs.
`bases` is a `Future<String> Function(DownloadBase)` the app writes (usually `path_provider`); give the engine
`TransferDownloadFiles(bases: bases)` so `remove`, `cancel` and sign-out delete the file and its `.part` and `.part.etag`.

- **Capabilities are `pause` only.** No background, no notifications, no user-initiated priority. A request with
  `DownloadNetwork.unmetered` is refused (`Failed(other)`), because the foreground cannot tell a metered network.
- **Resume is by bytes on disk**: the next attempt sends `Range` and `If-Range` from the `.part` and its validator; a
  server that ignores them restarts from byte 0; a part with no validator and no `sha256` restarts. After an app restart
  the engine reports `Failed(killed)`, and `retry` continues from the part.
- **A file at the destination is whole and checked** (size, then SHA-256 in another isolate, then an atomic move). A
  mismatch deletes the part. `cancel` deletes the part of a transfer in progress; an ended one keeps it for `retry`.
- **Failures**: `network`, `rejected` (other HTTP errors), `unauthorized` (401, 403), `sizeMismatch`, `hashMismatch`,
  `storage`, `unsupported`. On the web every start is `Failed(unsupported)` before a request: hand the browser the URL.
- **The client must honour `http.Abortable`** (the `package:http` clients do) or a pause cannot free a silent connection.
- `HttpTransfer` and `TransferFiles` are the pieces under it, exported for a backend of your own.

## The background backend

`BackgroundDownloaderBackend` (package `fespalier_download_background`, since 0.15.0, written against `background_downloader`
9.6.4) hands the transfer to the operating system: WorkManager and user-initiated jobs on Android, a background
`URLSession` on iOS. It needs Flutter 3.47, so it is not in the 3.32 floor job; an older app keeps `HttpDownloadBackend`.

- **Configure notifications or `userInitiated` is refused**: `BackgroundDownloaderBackend(notifications: DownloadNotifications(running: …))`.
  A `userInitiated` request without a `running` text is `Failed(notificationsRequired)`, because Android requires a visible
  notification for a user-initiated job. **The package never asks for the notification permission**; the app does.
- **`open()` the engine before the app calls `FileDownloader().start()` itself**, and never call the plugin's global
  `start`, `reset`, `configure` or `rescheduleKilledTasks` for these tasks. The backend registers callbacks for its own
  group `fespalier.download` before `resumeFromBackground` and never listens to the app's `updates` stream. The plugin's
  database is not the registry: a task the system lost is `Failed(killed)` and `retry` asks for a fresh grant.
- **A short-lived grant, not a header credential**: headers are in plaintext in the OS task queue until the task ends, and a
  retry sends the same ones (`BackgroundOptions(retries: 0)` where that matters). No refresh token, no DPoP.
- **Setup is the plugin's and the app's** (Kotlin 2.1, `POST_NOTIFICATIONS`, `RUN_USER_INITIATED_JOBS` and the job service,
  iOS 14 and the notification delegate): "Android and iOS setup" in `docs/downloads.md`.
- **Test with `FakeBackgroundTransport`**; no test runs the plugin.

## Credentials

(Since 0.15.0.) Authenticate a download with a **short-lived capability grant**, not a stored credential: the app makes its
normal signed request in the foreground and the server answers with a single-file URL and/or headers that expire in minutes.
`Downloads(grantor: (request, {required renewal}) async => DownloadGrant(url: ..., headers: ...))` asks it before each start,
retry and resume (`renewal: false`; null sends the request as it is) and **once more after a 401 or 403** (`renewal: true`):
the engine cancels the failed attempt, keeps the bytes the backend can continue from, and enqueues again with the new grant.
A second 401 or 403, a grantor that throws, or a grant URL that is not a valid http(s) URL ends `Failed(unauthorized)`. A
cancel, remove, restart or `clearAccount()` while the grant request is in flight wins. The registry stores the request, never
the grant; `DownloadGrant.toString()` prints no field; the span end carries `fespalier.download.regranted: true` after a renewal.

- **`HttpDownloadBackend(credentials: HttpCredentials)`** (from `fespalier_http`; `fespalier_auth`'s `Authorizer` is one)
  authorizes each send of the foreground transfer with `authorize('GET', url)` and asks `retry` after a 4xx for one re-send, at
  most three sends, as `SessionClient` does; a credentials object that throws ends `Failed(unauthorized)`. It is foreground
  only. For anything an operating-system backend sends, use a grant.
- **Plain `DownloadRequest.headers` are persisted in plaintext** (the registry, and a background backend's queue). Never a
  refresh token or a long-lived bearer. DPoP per send cannot work in the background: the native callbacks cannot sign.
- A request that is not replay-safe (a `POST`) is sent once: no re-send after a 401, no pause cycling. Nothing sends one in
  this release (uploads come later).

## In a widget

(Since 0.15.0.) Build one `Downloads(backend:, store: FileDownloadStore(bases: bases), files: TransferDownloadFiles(bases: bases))`
and override `downloadsEngine` with it in `startup.dart` (`downloadsEngine.overrideWithValue(engine)`). The provider has no
default: without the override it throws a `StateError` naming it. In a `ConsumerWidget`, `ref.watch(downloads)` (a
`Map<String, DownloadStatus>`; it opens the engine) and `ref.watch(downloadStatus(id))` (rebuilds only for that id; `Absent`
when unknown); act with `ref.read(downloadsEngine).start/pause/resume/retry/cancel/remove`. Disposing `downloads` clears the
engine's observer and closes it. Do not call `observe` yourself on an engine `downloads` watches: the slot is the provider's.

- **`FileDownloadStore` is the registry** (since 0.15.0): a JSON file `fespalier_downloads.json` in the `support` folder of
  your `DownloadBases`, written by atomic rename, never evicting (do not swap in a `BoundedDataStorage` or the `fespalier_storage`
  storages), empty when missing or corrupt, deleted by `clearAccount()`. In memory only on the web. Request **headers are in it
  in plaintext**, so a short-lived URL, not a header credential.
- **Test**: `downloadTestOverrides(backend: FakeDownloadBackend())` in a `ProviderContainer`; `backend.emit(id, status)` moves
  `downloads` and `downloadStatus`. Read a provider after an `emit` before asserting: Riverpod batches listener calls.

## Install

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_download:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_download
      ref: <the same tag>
```

(A fragment: pub resolves the pair only at a release tag that contains the package, 0.15.0 or later. Write `ref: v…` with
a real tag in an app, but never in these pages, where `cli/tests/versions.rs` would read it as fespalier's own version.)

## The shape of it

| You import                                           | For                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_download/fespalier_download.dart` | `DownloadRequest`, `DownloadLocation`, `DownloadBase`, `DownloadNetwork`, `DownloadPriority`, `DownloadStatus` and its cases, `WaitReason`, `DownloadFailure`, the ports `DownloadBackend`, `DownloadEvents`, `DownloadCapabilities`, `DownloadStore`, `DownloadFiles`, `Downloads`, `DownloadObserver`, `HttpDownloadBackend`, `DownloadBases`, `TransferDownloadFiles`, `HttpTransfer`, `TransferFiles`, `DownloadGrant`, `DownloadGrantor`, `FespalierDownloadConventions` |
| `package:fespalier_download/testing.dart`            | `FakeDownloadBackend` (with `replay:`), `MemoryDownloadStore`, `FakeDownloadFiles`, `FakeTransferFiles`                                                                                                                                                                                                                                                                                                                                                                       |

`package:fespalier_download/fespalier_download.dart` also exports `FileDownloadStore`, `downloadsEngine`, `downloads`,
`DownloadsNotifier` and `downloadStatus`, and `DownloadGrant` and `DownloadGrantor` (since 0.15.0, see Credentials); `testing.dart` has `downloadTestOverrides`.

The background backend in detail, with its setup and what is unchecked, is [`references/background.md`](references/background.md).
The engine in detail, with the restart and sign-out rules, is [`references/engine.md`](references/engine.md). The model in detail, with the exact refusals of `isValid`, is [`references/model.md`](references/model.md). The fakes and a
test that plays a platform are [`references/fakes.md`](references/fakes.md).

## Golden rules

- **A file is a `DownloadBase` and a relative path, never an absolute path.** An iOS app's container path changes between
  launches, so a stored absolute path goes stale. The default base is `support`. A path that came from outside the app
  (a server's file name) goes through `DownloadLocation.isValid` first.
- **Check `isValid` before you start anything.** A request with a `file://` URL, credentials in the URL, a short digest or
  a `..` in its path is `invalidRequest`, not a download.
- **A request's `toString()` prints no field.** Do not add a `toString` of your own that does, and do not log
  `request.url`: the URL can be a capability.
- **No long-lived credential in `headers`.** A backend may keep them on disk in plaintext while a download is queued. The
  documented path is a short-lived capability: make the normal signed request in the foreground, get a short-lived URL back,
  and return it from the engine's `grantor` (see Credentials). Never a refresh token, never a long-lived bearer.
- **The registry is never a cache.** A `DownloadStore` keeps what the app asked for until `remove` or `clear` (sign-out);
  it must not be a `BoundedDataStorage`, which evicts.
- **Telemetry names are the contract**, `fespalier.download.transfer`, `.reconciled` and `.open`: add, never rename. Their
  values are constants, booleans and enum names, never a URL, an id, a path, a display name, a header or an error's text.
  If you add a span of your own, keep those out of it too.

- **`Downloads` imports no Riverpod and is yours to own** (since 0.15.0): `open()` it before `start`, give `observe` one
  owner, `close()` it when that owner goes, and call `clearAccount()` at sign-out.
- **`start` never throws for a bad request**: an invalid request or location is `Failed(invalidRequest)`, a
  `userInitiated` request with no notifications on the backend is `Failed(notificationsRequired)`. Neither is registered,
  so `retry` does nothing for them: fix the request and `start` again.

## Traps

- **`Failed(DownloadFailure)` carries a value, not a message.** There is no error text to show; map each failure to your
  own copy. `unauthorized` (401 or 403) is what remains after the engine's one renewed grant (or with no grantor).
- **A restart settles the registry once, at `open()`.** Give the engine a `DownloadFiles` unless the backend replays
  finished downloads: an entry nobody mentions is `Failed(killed)` without one.
- **`Running.total` is null when the server did not say**: do not divide by it without a check.
- **A switch over `DownloadStatus` is exhaustive** (it is sealed): a new case in a later release is a compile error in your
  `switch`, which is the point.
- **The web cannot download this way**: the foreground backend ends every start there as `Failed(DownloadFailure.unsupported)`;
  hand the browser the URL instead.
- **The package never asks for notification permission**, now or later. The app does.

## Notification taps

`fespalier_download` (since 0.15.0) is an adapter: `fespalier: adapters: [fespalier_download]` makes `fsp gen` import
`package:fespalier_download/fespalier_adapter.dart`, with no `fsp` change. It is the `fespalier_push` shape, for the tap on a
download's notification.

- **One call in `main()`, before `AppMain.run()`**: `FespalierDownload.configure(backend:, store:, notifications:, route:)`
  (also `files:`, `grantor:`, `clock:` as `Downloads` takes them). It **builds the engine** and the adapter binds it to
  `downloadsEngine`, so `startup()` does not override that provider. Calling it twice replaces. Unconfigured, the adapter
  reports one `FlutterError` and does nothing; it never throws. A test calls it with the fakes
  (`FakeDownloadBackend(replayTaps: [(id, DownloadTapKind.body)])` is a tap that started the app, `backend.tap(id)` one while
  running) and `FespalierDownload.debugReset()` after.
- **`route: DownloadTarget? Function(DownloadTap)`.** A `DownloadTap` has `id`, `kind`, `status` and `request` (null for an
  id the engine does not know); `DownloadTarget.to(TypedRoute(...), open: DownloadOpen.go | push)`. Null, no `route:` or a
  throw means the tap opens the app and goes nowhere. `toString()` prints no field.
- **Cold start**: `launch()` opens the engine and answers the first replayed tap as the initial location, marked
  `NavigationSource.notification`. **Warm**: `attach` takes the engine's one tap slot (`Downloads.observeTaps`, the
  adapter's: never call it on that engine) and `go`es or `push`es inside `navigateFrom`. The cold tap seen again is dropped
  once. Taps between `launch()` and `attach` are replayed in order.
- **UNCHECKED on a device** ([#158](https://github.com/fespalier/fespalier/issues/158)): whether the plugin delivers a
  cold-start tap before or after `resumeFromBackground`. Do not state either as fact; the adapter works both ways (initial
  location, or a `go` from the first page).
- **Telemetry**: `fespalier.download.open` with `fespalier.download.routed`, never an id, path, URL or name. The package asks
  for no notification permission; the app does.
- It adds no listener: the slot is a callback, and `no_timers_test.dart` has no exception.

## The example

`examples/downloads` (since 0.15.0, in the fespalier repository) is the wiring end to end on the foreground backend:
`configureDownloads()` in `lib/setup.dart` (`HttpDownloadBackend`, `FileDownloadStore`, `TransferDownloadFiles`, a grantor and
`tapTarget`) called from `main()` before `AppMain.run()`, with `adapters: [fespalier_download]` in the pubspec and **no
`startup.dart`** (the adapter binds `downloadsEngine`). `/` has a card per case with the buttons that match
`downloadStatus`, `/files/:id` is the page a tap opens, and `--dart-define=LARGE_URL`, `LARGE_SHA256`, `LARGE_BYTES` (and
`SMALL_*`) point it at another file. Its README is the run steps for the device test of issue #157, written for someone who
does not know fespalier. Its tests boot `AppMain.root()` over `FakeDownloadBackend` after `configureDownloads(backend:, store:,
files:)`, and call `FespalierDownload.debugReset()` in `setUp` and `tearDown`.
