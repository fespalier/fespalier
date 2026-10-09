# fespalier_download

Downloads for [fespalier](https://github.com/fespalier/fespalier) (since 0.15.0): the model and the ports of a file transfer
that outlives a screen. A download is a `DownloadRequest` (an id, a URL, a file as a base folder and a relative path, and
optionally its size and SHA-256), it is in one `DownloadStatus` at a time (`Queued`, `Waiting`, `Running`, `Paused`,
`Verifying`, `Complete`, `Failed`, `Cancelled`), and a `DownloadBackend` does the transfer. The package has the
vocabulary, the telemetry names, the fakes and the engine, `Downloads`, that drives a backend (start, pause, resume, retry,
cancel, remove, the registry after a restart, sign-out) and the foreground `HttpDownloadBackend`; the providers and a background
backend come in the releases after it.

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

## Test it

`package:fespalier_download/testing.dart` has `FakeDownloadBackend` (the test plays the platform with `emit` and `tap`),
`MemoryDownloadStore`, `FakeDownloadFiles` and `FakeTransferFiles`. A test builds `Downloads(backend:, store:, files:)` over them, calls `open()`,
and plays the platform with `emit`; `replay:` is what the backend reports at open, to test a restart.

## Rules

- **The engine imports no Riverpod** (`test/engine_test.dart` greps it) and keeps one observer slot that `close()` clears.
- **No timer, no polling, no microtask, no listener of its own**, and nothing that opens a dialog, a menu, a sheet or a
  snack bar: `test/no_timers_test.dart` greps `lib/`, with no exception.
- **Telemetry carries kinds and results, never a transfer's identity**: `fespalier.download.transfer`,
  `fespalier.download.reconciled` and `fespalier.download.open` are constants, booleans and enum names, never a URL, an id,
  a path, a display name, a header or an error's text. `test/telemetry_test.dart` pins every name.
