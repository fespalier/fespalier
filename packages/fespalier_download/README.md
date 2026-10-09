# fespalier_download

Downloads for [fespalier](https://github.com/fespalier/fespalier) (since 0.15.0): the model and the ports of a file transfer
that outlives a screen. A download is a `DownloadRequest` (an id, a URL, a file as a base folder and a relative path, and
optionally its size and SHA-256), it is in one `DownloadStatus` at a time (`Queued`, `Waiting`, `Running`, `Paused`,
`Verifying`, `Complete`, `Failed`, `Cancelled`), and a `DownloadBackend` does the transfer. The package has the
vocabulary, the telemetry names, the fakes and the engine, `Downloads`, that drives a backend (start, pause, resume, retry,
cancel, remove, the registry after a restart, sign-out) and the foreground `HttpDownloadBackend`, a durable registry (`FileDownloadStore`) and the Riverpod
providers `downloads` and `downloadStatus`; a background backend comes in a release after it.

It is pure Dart over `package:http`: no platform plugin, so it resolves on Flutter 3.32, fespalier's floor, and an app that
lists it links nothing native.

fespalier itself has no download feature: no file kind, no `fespalier:` key, no `fsp` command, and the generated code is the
same bytes. The full guide is [docs/downloads.md](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md). This
page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are the
same repository dependency.

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
```

<!-- x-release-please-end -->

It depends on `fespalier_http` (at the same tag, which pub resolves for you) for `HttpCredentials`. List
`fespalier_http` yourself, with the same `url` and `ref`, only when your code imports it.

## Requests and files

```dart
import 'package:fespalier_download/fespalier_download.dart';

final request = DownloadRequest(
  id: 'manual-42',
  url: Uri.parse('https://files.example.com/manual-42.pdf'),
  file: const DownloadLocation(DownloadBase.support, 'manuals/manual-42.pdf'),
  bytes: 1048576,
  sha256: '…64 hex digits…',
);
assert(request.isValid);
```

- **A file is a base and a relative path**, never an absolute path: an iOS app's container path changes between launches.
  `DownloadLocation.isValid` refuses an empty path, a leading `/`, an empty segment, a `..` segment, a `\` and a NUL.
- **`DownloadRequest.isValid`** also wants an absolute http or https URL with a host and no credentials in it, a
  non-negative size and a 64-digit SHA-256.
- **`toString()` prints no field**: the URL can be a capability, the headers a credential.
- **Headers may be kept on disk in plaintext** by a backend while a download is queued. Never put a refresh token or a
  long-lived bearer in one; a short-lived URL is the better capability.

## The foreground backend

`HttpDownloadBackend(client:, bases:)` downloads over your `http.Client` while the app runs: `Range` and `If-Range` from a
`<file>.part` and its `.part.etag` validator, the size and SHA-256 checked before an atomic move, the request aborted on
pause and cancel. It can pause and nothing else (no background, no notifications, no `unmetered`, which it refuses). `bases`
names the base folders (`path_provider` is yours); give the engine `TransferDownloadFiles(bases:)` to delete files. On the
web every start ends `Failed(unsupported)`. See [the guide](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#the-foreground-backend).

## In a widget

`FileDownloadStore(bases: bases)` is the durable registry: a JSON file in the `support` folder your `DownloadBases` names,
written by atomic rename (temp file, then rename), never evicting, empty (not an error) when missing or corrupt, wiped by
`clearAccount()`; its request headers are in plaintext. Override `downloadsEngine` (no default: a `StateError` names the
override) with a `Downloads` over it, and watch `downloads` (every status by id) or `downloadStatus(id)` in a widget;
watching opens the engine, and disposing closes it. Act through `ref.read(downloadsEngine)`.

```dart
Future<List<Override>> startup() async => [
  downloadsEngine.overrideWithValue(
    Downloads(
      backend: HttpDownloadBackend(client: http.Client(), bases: bases),
      store: FileDownloadStore(bases: bases),
      files: TransferDownloadFiles(bases: bases),
    ),
  ),
];
// in a ConsumerWidget: ref.watch(downloadStatus('manual-42'))
```

See [the guide](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#in-a-widget).

## Credentials

The documented path is a **short-lived capability grant**: before the download starts, in the foreground, the app makes its
normal signed request and the server answers with a single-file URL and/or headers that expire in minutes. Give the engine
a `grantor` that returns a `DownloadGrant(url:, headers:)` (its `toString()` prints no field; the registry never stores it):

```dart
final engine = Downloads(
  backend: backend,
  store: store,
  files: files,
  grantor: (request, {required renewal}) async => DownloadGrant(url: await signedUrlFor(request.id)),
);
```

It is asked before each start, retry and resume, and **once more after a 401 or 403**: the engine cancels the failed
attempt (the bytes the backend kept stay) and enqueues again with the new grant. A second 401 or 403, or a grantor that
throws, ends `Failed(unauthorized)`; a cancel, remove, restart or sign-out meanwhile wins. `HttpDownloadBackend(credentials:)`
takes any `HttpCredentials` (`fespalier_auth`'s `Authorizer`): each send of the foreground transfer is authorized, and a
4xx asks `retry` for one re-send, at most three sends. Plain `headers` are stored in plaintext; never put a refresh
token or a long-lived bearer in a request or a grant, and a DPoP proof cannot be signed per send by a background backend.
The telemetry span's end has `fespalier.download.regranted: true` when a renewal was asked. See
[the guide](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#credentials).

## Notification taps

An [adapter](https://github.com/fespalier/fespalier/blob/main/docs/adapters.md) (`fespalier: adapters: [fespalier_download]`)
opens a typed route from a tap on a download's notification: a tap that cold-starts the app is the initial location, one
while the app runs is a `go` (or `push`), both marked `source=notification`. The engine is built by one call in `main()`
before `AppMain.run()`, and the adapter binds it to `downloadsEngine`:

```dart
FespalierDownload.configure(
  backend: BackgroundDownloaderBackend(),
  store: FileDownloadStore(bases: bases),
  notifications: const DownloadNotifications(running: 'Downloading'),
  route: (tap) => switch (tap.request?.id) {
    final id? when id.startsWith('manual-') => DownloadTarget.to(ManualRoute(id: id)),
    _ => null,
  },
);
```

Unconfigured, it reports one `FlutterError` and does nothing. The tap slot of the engine (`observeTaps`) is the adapter's.
Which comes first on a cold start, the tap or the backend's replay, is UNCHECKED on a device
([#158](https://github.com/fespalier/fespalier/issues/158)). See
[the guide](https://github.com/fespalier/fespalier/blob/main/docs/downloads.md#notification-taps).

## Test it

`package:fespalier_download/testing.dart` has `FakeDownloadBackend` (the test plays the platform with `emit` and `tap`),
`MemoryDownloadStore`, `FakeDownloadFiles` and `FakeTransferFiles`, and `downloadTestOverrides(backend:)` for the
providers. A test builds `Downloads(backend:, store:, files:)` over them, calls `open()`,
and plays the platform with `emit`; `replay:` is what the backend reports at open, to test a restart, and `replayTaps:` the notification taps it delivers then.

## Rules

- **The engine imports no Riverpod** (`test/engine_test.dart` greps it) and keeps one observer slot and one tap slot (the adapter's) that `close()` clears.
- **The registry is never a `BoundedDataStorage`** and is written by atomic rename; the providers add no timer and no listener.
- **No timer, no polling, no microtask, no listener of its own**, and nothing that opens a dialog, a menu, a sheet or a
  snack bar: `test/no_timers_test.dart` greps `lib/`, with no exception.
- **Telemetry carries kinds and results, never a transfer's identity**: `fespalier.download.transfer`,
  `fespalier.download.reconciled` and `fespalier.download.open` are constants, booleans and enum names, never a URL, an id,
  a path, a display name, a header or an error's text. `test/telemetry_test.dart` pins every name.
