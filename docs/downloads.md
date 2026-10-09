# Downloads: fespalier_download

`fespalier_download` (since 0.15.0) is the vocabulary of a file download that outlives a screen: a **request** (an id, a
URL, a file and what the file must be), a **status** that says where the download stands, and the **ports** a transfer
engine is built from. It is pure Dart over `package:http` with no platform plugin, so it resolves on Flutter 3.32,
fespalier's floor, and an app that lists it links nothing native.

fespalier itself has no download feature: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart` is the
same bytes. The package is a companion, installed like `fespalier_flags`.

**What is in this release, and what is not.** This release is the model, the telemetry names and the fakes. It has **no
engine** (nothing starts, pauses or resumes a transfer yet), no HTTP backend, no providers and no background backend over
the operating system's download service. Those come in later releases of the same line, and this page grows with them. A
download you need today is `fespalier_maps`' file packs ([Maps](maps.md#file-packs)), which will move onto this package.

Contents: [Install](#install), [Requests and files](#requests-and-files), [Status](#status), [Testing](#testing).

## Install

Add the package next to fespalier with the **same `url` and the same `ref`**: pub resolves the two to one package only
then. The tag must be a release that contains the package (0.15.0 or later). The install block, with the version
release-please keeps current, is in [the package's README](../packages/fespalier_download/README.md#install).

The package depends on `http` (`>=1.5.0 <2.0.0`, the first release with abortable requests), a pure Dart package, and on
fespalier. It resolves on Flutter 3.32 with the lowest versions it allows (CI's `floor` job runs `flutter pub downgrade`,
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

The ports are the seams a later engine is built on, and an app does not call them: `DownloadBackend` (the transfer
machinery, with `DownloadCapabilities` saying what it can do and `DownloadEvents` as the way back), `DownloadStore` (the
durable list of what the app asked for: it is a registry, not a cache, so nothing is evicted) and `DownloadFiles`.

**Telemetry** (the names are the contract, add never rename): `fespalier.download.transfer` for one transfer with
`result` (`complete`, `failed`, `cancelled`), `failure`, `resumed`, `background`, `network` and `priority`;
`fespalier.download.reconciled`; and `fespalier.download.open` with `routed`. Their values are constants, booleans and enum
names: **never a URL, an id, a path, a display name, a header or an error's text**. `FespalierDownloadConventions` has
them, and `test/telemetry_test.dart` pins each one.

## Testing

`package:fespalier_download/testing.dart` has the fakes, which need no network, platform or disk:

- `FakeDownloadBackend`: records what is asked (`enqueued`, `paused`, `resumed`, `cancelled`, `authorizations`), answers
  as `accepts` and `capabilities` say, and plays the platform through `emit(id, status, httpStatus:)` and
  `tap(id)` once a listener has called `open`.
- `MemoryDownloadStore`: a registry in memory (`entries`, `clearCalls`).
- `FakeDownloadFiles`: files as a map of sizes (`put`, `deleted`).

The model needs no widget: `DownloadRequest`, `DownloadLocation` and `DownloadStatus` are plain values, so a unit test
builds them and checks `isValid` and equality directly. The package's own tests do exactly that, including every refusal
of `isValid` and a check that no `toString` leaks a field.
